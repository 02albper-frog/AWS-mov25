#!/bin/bash
# Tar bort allt som storage.sh skapade: RDS, DB subnet group, EFS, backup-bucket och lösenord.
# Kör ./teardown.sh först, eftersom webbservern använder databasen och EFS.
set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

quiet() { "$@" > /dev/null 2>&1; }

RUNNING=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$TAG_NAME,$BASTION_NAME" \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$RUNNING" ]; then
  echo "Instanser körs fortfarande ($RUNNING). Kör ./teardown.sh först."
  exit 1
fi

echo "== RDS =="
if [ "$(db_field DBInstanceStatus)" != "None" ]; then
  # Ingen slutlig snapshot i labbmiljön. I drift: --final-db-snapshot-identifier
  aws rds delete-db-instance --region "$REGION" --db-instance-identifier "$DB_ID" \
    --skip-final-snapshot --delete-automated-backups > /dev/null
  echo "Tar bort $DB_ID (tar ofta 5-15 minuter) ..."
  aws rds wait db-instance-deleted --region "$REGION" --db-instance-identifier "$DB_ID" \
    || aws rds wait db-instance-deleted --region "$REGION" --db-instance-identifier "$DB_ID"
  echo "Tog bort $DB_ID"
fi
quiet aws rds delete-db-subnet-group --region "$REGION" --db-subnet-group-name "$DB_SUBNET_GROUP" \
  && echo "Tog bort $DB_SUBNET_GROUP"

echo "== EFS =="
EFS_ID=$(efs_id)
if [ "$EFS_ID" != "None" ]; then
  for mt in $(aws efs describe-mount-targets --region "$REGION" --file-system-id "$EFS_ID" \
      --query 'MountTargets[].MountTargetId' --output text); do
    quiet aws efs delete-mount-target --region "$REGION" --mount-target-id "$mt"
  done
  while [ "$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$EFS_ID" \
      --query 'length(MountTargets)' --output text)" != "0" ]; do sleep 5; done
  echo "Tog bort mount targets"
  for i in 1 2 3 4 5 6; do
    quiet aws efs delete-file-system --region "$REGION" --file-system-id "$EFS_ID" && break
    sleep 10
  done
  echo "Tog bort $EFS_NAME"
fi

echo "== Backup-bucket =="
quiet aws s3 rm "s3://$BACKUP_BUCKET" --recursive
quiet aws s3api delete-bucket --bucket "$BACKUP_BUCKET" --region "$REGION" \
  && echo "Tog bort $BACKUP_BUCKET"

echo "== Lösenord i SSM =="
quiet aws ssm delete-parameters --region "$REGION" \
  --names "$SSM_DB_MASTER" "$SSM_DB_WP" "$SSM_WP_ADMIN" \
  && echo "Tog bort lösenorden"

echo ""
echo "Klart! Kontrollera i RDS-, EFS- och S3-konsolen att allt är borta."
