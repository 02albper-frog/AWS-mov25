#!/bin/bash
# V45: Verifierar databas, delad lagring, backup, WordPress och säkerheten mellan komponenterna.
set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

WEB_IP=$(instance_field "$TAG_NAME" PublicIpAddress)
if [ "$WEB_IP" = "None" ]; then
  echo "Webbservern körs inte. Kör ./provision.sh först."
  exit 1
fi
EFS_ID=$(efs_id)
DB_HOST=$(db_field Endpoint.Address)
EFS_MT_IP=$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$EFS_ID" \
  --query 'MountTargets[0].IpAddress' --output text)
PRIVATE_SUBNETS="$(subnet_id "$DB_SUBNET_A") $(subnet_id "$DB_SUBNET_B")"
WP="sudo /usr/local/bin/wp --allow-root --path=/var/www/html"

PASS=0
FAIL=0
expect() {  # <beskrivning> <förväntat> <resultat>
  local status
  if [ "$2" = "$3" ]; then status="OK "; PASS=$((PASS + 1)); else status="FEL"; FAIL=$((FAIL + 1)); fi
  printf "[%s] %-52s förväntat: %-4s resultat: %s\n" "$status" "$1" "$2" "$3"
}

# ja om villkoret stämmer, annars nej
yes_if() { if "$@" > /dev/null 2>&1; then echo "ja"; else echo "nej"; fi; }

# ja om fjärrkommandot skriver ut "ok" på sista raden
remote() {
  local result
  result=$("$1" "$2" 2> /dev/null | tail -n 1)
  if [ "$result" = "ok" ]; then echo "ja"; else echo "nej"; fi
}

# samma mängd ID:n, oavsett ordning
same_set() {
  [ "$(echo "$1" | tr ' \t' '\n\n' | grep . | sort)" = "$(echo "$2" | tr ' \t' '\n\n' | grep . | sort)" ]
}

echo "== Databas (RDS) =="
MULTI_AZ_EXPECTED=$([ "$DB_MULTI_AZ" = "true" ] && echo ja || echo nej)
expect "Databasen är publikt åtkomlig"                      nej "$(yes_if [ "$(db_field PubliclyAccessible)" = "True" ])"
expect "Multi-AZ med standby i en annan AZ"                 "$MULTI_AZ_EXPECTED" "$(yes_if [ "$(db_field MultiAZ)" = "True" ])"
expect "Lagringen är krypterad"                             ja  "$(yes_if [ "$(db_field StorageEncrypted)" = "True" ])"
expect "Automatisk backup ($DB_BACKUP_DAYS dag)"            ja  "$(yes_if [ "$(db_field BackupRetentionPeriod)" = "$DB_BACKUP_DAYS" ])"
expect "Databasen ligger bara i de privata subnäten"        ja  "$(yes_if same_set "$(db_field 'DBSubnetGroup.Subnets[].SubnetIdentifier')" "$PRIVATE_SUBNETS")"
expect "Databasens adress pekar på en privat IP"            ja  "$(remote on_web "getent hosts $DB_HOST | grep -Eq '^10\.0\.1[12]\.' && echo ok")"

echo ""
echo "== Delad lagring (EFS) =="
expect "EFS är krypterad"                                   ja  "$(yes_if [ "$(aws efs describe-file-systems --region "$REGION" --file-system-id "$EFS_ID" --query 'FileSystems[0].Encrypted' --output text)" = "True" ])"
expect "Mount targets bara i de privata subnäten"           ja  "$(yes_if same_set "$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$EFS_ID" --query 'MountTargets[].SubnetId' --output text)" "$PRIVATE_SUBNETS")"
expect "Filsystemspolicyn kräver krypterad trafik (TLS)"    ja  "$(yes_if bash -c "aws efs describe-file-system-policy --region $REGION --file-system-id $EFS_ID --query Policy --output text | grep -q SecureTransport")"
expect "EFS är monterad på wp-content"                      ja  "$(remote on_web "findmnt -n -o FSTYPE /var/www/html/wp-content | grep -q nfs4 && echo ok")"
expect "Uppladdade filer ligger på EFS"                     ja  "$(remote on_web "[ \$(sudo find /var/www/html/wp-content/uploads -type f | wc -l) -gt 0 ] && echo ok")"

echo ""
echo "== Backup (S3) =="
expect "Backup-bucketen blockerar all publik åtkomst"       ja  "$(yes_if bash -c "aws s3api get-public-access-block --bucket $BACKUP_BUCKET --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text | grep -qv False")"
expect "Livscykelregel raderar $BACKUP_PREFIX efter $BACKUP_DAYS dagar" ja "$(yes_if [ "$(aws s3api get-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" --query "Rules[?Filter.Prefix=='$BACKUP_PREFIX' && Status=='Enabled'].Expiration.Days | [0]" --output text)" = "$BACKUP_DAYS" ])"
expect "Minst en databasbackup finns i S3"                  ja  "$(yes_if bash -c "aws s3 ls s3://$BACKUP_BUCKET/$BACKUP_PREFIX | grep -q '\.sql\.gz'")"

echo ""
echo "== WordPress =="
expect "Startsidan visar Novatrix (HTTP)"                   ja  "$(yes_if bash -c "curl -s -m 10 http://$WEB_IP/ | grep -q Novatrix")"
expect "Inloggningssidan wp-login.php svarar"               ja  "$(yes_if [ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$WEB_IP/wp-login.php")" = "200" ])"
expect "WordPress är installerat och når databasen"         ja  "$(remote on_web "$WP core is-installed && echo ok")"
expect "WordPress ansluter till databasen med TLS"          ja  "$(remote on_web "$WP eval-file /usr/local/share/novatrix/db-tls.php | grep -qv ingen && echo ok")"
expect "Sidan Om Novatrix finns i databasen"                ja  "$(remote on_web "[ \$($WP post list --post_type=page --name=om-novatrix --format=count) -gt 0 ] && echo ok")"

echo ""
echo "== Säkerhet mellan komponenterna =="
expect "Bastion når databasen (MySQL 3306)"                 nej "$(remote on_bastion "timeout 5 bash -c 'exec 3<>/dev/tcp/$DB_HOST/3306' && echo ok")"
expect "Bastion når EFS (NFS 2049)"                         nej "$(remote on_bastion "timeout 5 bash -c 'exec 3<>/dev/tcp/$EFS_MT_IP/2049' && echo ok")"
expect "Webbservern kan läsa WordPress-lösenordet"          ja  "$(remote on_web "aws ssm get-parameter --region $REGION --name $SSM_DB_WP --with-decryption > /dev/null && echo ok")"
expect "Webbservern kan läsa huvudlösenordet"               nej "$(remote on_web "aws ssm get-parameter --region $REGION --name $SSM_DB_MASTER --with-decryption > /dev/null && echo ok")"
expect "Webbservern kan läsa backuper"                      nej "$(remote on_web "aws s3 ls s3://$BACKUP_BUCKET/$BACKUP_PREFIX --region $REGION > /dev/null && echo ok")"
expect "Webbservern kan radera backuper"                    nej "$(remote on_web "aws s3 rm s3://$BACKUP_BUCKET/${BACKUP_PREFIX}finns-inte.sql.gz --region $REGION > /dev/null && echo ok")"

echo ""
echo "Resultat: $PASS OK, $FAIL fel av $((PASS + FAIL)) tester"
[ "$FAIL" -eq 0 ]
