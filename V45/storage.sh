#!/bin/bash
# V45: Skapar lagring och databas som kod:
#   1. slumpade lösenord i SSM Parameter Store (krypterade)
#   2. privat backup-bucket i S3 med livscykelregel (14 dagar)
#   3. EFS för WordPress-filerna, med mount targets i de privata subnäten
#   4. RDS MariaDB (Multi-AZ) i de privata subnäten
# Förutsätter att network.sh har körts. Körs av en administratör (albin-admin).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # hindrar Git Bash från att tolka /novatrix/... som sökvägar
cd "$(dirname "$0")"
source ./config.sh

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
[ "$(vpc_id)" != "None" ] || { echo "Nätverket $VPC_NAME saknas. Kör ./network.sh först."; exit 1; }

PRIVATE_A_ID=$(subnet_id "$DB_SUBNET_A")
PRIVATE_B_ID=$(subnet_id "$DB_SUBNET_B")
DB_SG_ID=$(sg_id "$DB_SG")
EFS_SG_ID=$(sg_id "$EFS_SG")

# ------------------------------------------------------------------
echo "== 1. Lösenord i SSM Parameter Store =="
create_secret() {  # <namn> <beskrivning>
  if aws ssm get-parameter --region "$REGION" --name "$1" > /dev/null 2>&1; then
    echo "Parametern $1 finns redan"
  else
    aws ssm put-parameter --region "$REGION" --name "$1" --type SecureString \
      --value "$(openssl rand -hex 16)" --description "$2" \
      --tags Key=Project,Value=novatrix > /dev/null
    echo "Skapade $1 (slumpat lösenord, krypterat)"
  fi
}
create_secret "$SSM_DB_MASTER" "Novatrix RDS huvudanvandare"
create_secret "$SSM_DB_WP"     "Novatrix WordPress databasanvandare"
create_secret "$SSM_WP_ADMIN"  "Novatrix WordPress administrator"

# ------------------------------------------------------------------
echo ""
echo "== 2. Backup-bucket i S3 =="
if aws s3api head-bucket --bucket "$BACKUP_BUCKET" 2> /dev/null; then
  echo "Bucket $BACKUP_BUCKET finns redan"
else
  aws s3api create-bucket --bucket "$BACKUP_BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
  echo "Skapade bucket $BACKUP_BUCKET"
fi
aws s3api put-public-access-block --bucket "$BACKUP_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
echo "Blockerar all publik åtkomst till bucketen"

aws s3api put-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" \
  --lifecycle-configuration "{\"Rules\":[{
    \"ID\":\"radera-databasbackuper-efter-${BACKUP_DAYS}-dagar\",
    \"Status\":\"Enabled\",
    \"Filter\":{\"Prefix\":\"$BACKUP_PREFIX\"},
    \"Expiration\":{\"Days\":$BACKUP_DAYS},
    \"AbortIncompleteMultipartUpload\":{\"DaysAfterInitiation\":1}}]}"
echo "Livscykelregel: objekt under $BACKUP_PREFIX raderas efter $BACKUP_DAYS dagar"

# ------------------------------------------------------------------
echo ""
echo "== 3. EFS för WordPress-filerna =="
EFS_ID=$(efs_id)
if [ "$EFS_ID" = "None" ]; then
  EFS_ID=$(aws efs create-file-system --region "$REGION" --creation-token "$EFS_NAME" \
    --performance-mode generalPurpose --throughput-mode bursting --encrypted \
    --tags "Key=Name,Value=$EFS_NAME" Key=Project,Value=novatrix \
    --query FileSystemId --output text)
  echo "Skapade EFS $EFS_NAME $EFS_ID (krypterad, General Purpose, Bursting)"
else
  echo "EFS $EFS_NAME finns redan ($EFS_ID)"
fi

until [ "$(aws efs describe-file-systems --region "$REGION" --file-system-id "$EFS_ID" \
  --query 'FileSystems[0].LifeCycleState' --output text)" = "available" ]; do sleep 5; done

aws efs put-lifecycle-configuration --region "$REGION" --file-system-id "$EFS_ID" \
  --lifecycle-policies '[{"TransitionToIA":"AFTER_30_DAYS"},{"TransitionToPrimaryStorageClass":"AFTER_1_ACCESS"}]' > /dev/null
echo "Livscykel: filer som inte använts på 30 dagar flyttas till Infrequent Access"

EFS_ARN="arn:aws:elasticfilesystem:$REGION:$ACCOUNT_ID:file-system/$EFS_ID"
aws efs put-file-system-policy --region "$REGION" --file-system-id "$EFS_ID" \
  --policy "$(sed "s|__EFS_ARN__|$EFS_ARN|g" policies/efs-policy.json)" > /dev/null
echo "Filsystemspolicy: endast montering via mount target och med krypterad trafik (TLS)"

for subnet in "$PRIVATE_A_ID" "$PRIVATE_B_ID"; do
  existing=$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$EFS_ID" \
    --query "MountTargets[?SubnetId=='$subnet'].MountTargetId | [0]" --output text)
  if [ "$existing" = "None" ]; then
    aws efs create-mount-target --region "$REGION" --file-system-id "$EFS_ID" \
      --subnet-id "$subnet" --security-groups "$EFS_SG_ID" > /dev/null
  fi
done
echo "Skapar mount targets i $DB_SUBNET_A och $DB_SUBNET_B med $EFS_SG ..."
until [ "$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$EFS_ID" \
  --query "length(MountTargets[?LifeCycleState=='available'])" --output text)" = "2" ]; do sleep 10; done
echo "Mount targets är klara"

# ------------------------------------------------------------------
echo ""
echo "== 4. RDS MariaDB =="
if aws rds describe-db-subnet-groups --region "$REGION" \
     --db-subnet-group-name "$DB_SUBNET_GROUP" > /dev/null 2>&1; then
  echo "DB subnet group $DB_SUBNET_GROUP finns redan"
else
  aws rds create-db-subnet-group --region "$REGION" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Novatrix databas: privata subnat i tva AZ" \
    --subnet-ids "$PRIVATE_A_ID" "$PRIVATE_B_ID" \
    --tags "Key=Name,Value=$DB_SUBNET_GROUP" Key=Project,Value=novatrix > /dev/null
  echo "Skapade DB subnet group $DB_SUBNET_GROUP ($DB_SUBNET_A, $DB_SUBNET_B)"
fi

if [ "$(db_field DBInstanceStatus)" = "None" ]; then
  MASTER_PW=$(aws ssm get-parameter --region "$REGION" --name "$SSM_DB_MASTER" \
    --with-decryption --query Parameter.Value --output text)
  MULTI_AZ_FLAG=--no-multi-az
  [ "$DB_MULTI_AZ" = "true" ] && MULTI_AZ_FLAG=--multi-az

  if ! aws rds create-db-instance --region "$REGION" \
      --db-instance-identifier "$DB_ID" \
      --engine "$DB_ENGINE" \
      --db-instance-class "$DB_CLASS" \
      --allocated-storage "$DB_STORAGE_GB" \
      --storage-type "$DB_STORAGE_TYPE" \
      --storage-encrypted \
      --master-username "$DB_MASTER_USER" \
      --master-user-password "$MASTER_PW" \
      --db-name "$DB_NAME" \
      --db-subnet-group-name "$DB_SUBNET_GROUP" \
      --vpc-security-group-ids "$DB_SG_ID" \
      --no-publicly-accessible \
      $MULTI_AZ_FLAG \
      --backup-retention-period "$DB_BACKUP_DAYS" \
      --preferred-backup-window 01:00-01:30 \
      --preferred-maintenance-window sun:02:00-sun:02:30 \
      --copy-tags-to-snapshot \
      --auto-minor-version-upgrade \
      --tags "Key=Name,Value=$DB_ID" Key=Project,Value=novatrix > /dev/null; then
    echo ""
    echo "Kunde inte skapa databasen. Om felet gäller Free plan och Multi-AZ:"
    echo "sätt DB_MULTI_AZ=false i config.sh och kör ./storage.sh igen."
    exit 1
  fi
  echo "Skapar $DB_ID ($DB_ENGINE, $DB_CLASS, $DB_STORAGE_GB GB $DB_STORAGE_TYPE, Multi-AZ: $DB_MULTI_AZ)"
else
  echo "Databasen $DB_ID finns redan"
fi

echo "Väntar på att databasen ska bli tillgänglig (Multi-AZ tar ofta 15-25 minuter) ..."
aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$DB_ID" \
  || aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$DB_ID"

echo ""
echo "Klart!"
echo "Databas:   $(db_field Endpoint.Address)"
echo "           primär i $(db_field AvailabilityZone), standby i $(db_field SecondaryAvailabilityZone)"
echo "           publikt åtkomlig: $(db_field PubliclyAccessible), backup: $(db_field BackupRetentionPeriod) dag(ar)"
echo "EFS:       $EFS_ID"
echo "Backup:    s3://$BACKUP_BUCKET/$BACKUP_PREFIX (raderas efter $BACKUP_DAYS dagar)"
echo ""
echo "Kör ./provision.sh för att starta webbservern."
