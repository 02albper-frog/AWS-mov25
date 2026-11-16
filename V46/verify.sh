#!/bin/bash
# V46: Verifierar att stacken blev som avsett: CloudFormation, backup, nätverk,
# databas, lagring, WordPress och säkerheten mellan komponenterna.
# Användning: ./verify.sh [miljö]
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh "${1:-prod}"

PASS=0
FAIL=0
expect() {  # <beskrivning> <förväntat> <resultat>
  local status
  if [ "$2" = "$3" ]; then status="OK "; PASS=$((PASS + 1)); else status="FEL"; FAIL=$((FAIL + 1)); fi
  printf "[%s] %-56s förväntat: %-4s resultat: %s\n" "$status" "$1" "$2" "$3"
}
yes_if() { if "$@" > /dev/null 2>&1; then echo "ja"; else echo "nej"; fi; }
remote() {  # <on_web|on_bastion> <kommando>: ja om sista raden är "ok"
  local result
  result=$("$1" "$2" 2> /dev/null | tail -n 1)
  if [ "$result" = "ok" ]; then echo "ja"; else echo "nej"; fi
}
port_open() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2> /dev/null; }
equals() { [ "$1" = "$2" ]; }

# Driftkontroll: har någon ändrat stacken utanför CloudFormation?
in_sync() {
  local id status
  id=$(aws cloudformation detect-stack-drift --region "$Region" --stack-name "$(stack_name "$1")" \
    --query StackDriftDetectionId --output text) || return 1
  while true; do
    status=$(aws cloudformation describe-stack-drift-detection-status --region "$Region" \
      --stack-drift-detection-id "$id" --query '[DetectionStatus,StackDriftStatus]' --output text)
    case "$status" in
      DETECTION_IN_PROGRESS*) sleep 3 ;;
      *) [ "$(echo "$status" | awk '{print $2}')" = "IN_SYNC" ]; return ;;
    esac
  done
}

WEB_IP=$(stack_output app WebPublicIp)
BASTION_IP=$(stack_output app BastionPublicIp)
DB_HOST=$(stack_output data DbEndpoint)
EFS_ID=$(stack_output data EfsId)
B="$BackupBucketName"
db() { aws rds describe-db-instances --region "$Region" --db-instance-identifier "$EnvName-db" \
  --query "DBInstances[0].$1" --output text; }

echo "== CloudFormation =="
for s in "${STACKS[@]}"; do
  expect "Stacken $(stack_name "$s") är klar" ja \
    "$(yes_if bash -c "[[ '$(stack_status "$s")' =~ ^(CREATE|UPDATE)_COMPLETE$ ]]")"
done
expect "Nätverket är oförändrat sedan deploy (ingen drift)" ja "$(yes_if in_sync network)"

echo ""
echo "== Backup-bucketen =="
expect "Bucketen har DeletionPolicy Retain"                    ja "$(yes_if bash -c "aws cloudformation get-template --region $Region --stack-name $(stack_name backup) --query TemplateBody --output text | grep -q 'DeletionPolicy: Retain'")"
expect "All publik åtkomst är blockerad"                       ja "$(yes_if bash -c "! aws s3api get-public-access-block --bucket $B --output text | grep -q False")"
expect "Versionshantering av objekt är påslagen"               ja "$(yes_if equals "$(aws s3api get-bucket-versioning --bucket "$B" --query Status --output text)" Enabled)"
expect "Okrypterad trafik nekas av bucket policyn"             ja "$(yes_if bash -c "aws s3api get-bucket-policy --bucket $B --query Policy --output text | grep -q SecureTransport")"
expect "db/ raderas efter $BackupRetentionDays dagar"          ja "$(yes_if equals "$(aws s3api get-bucket-lifecycle-configuration --bucket "$B" --query "Rules[?Prefix=='db/' || Filter.Prefix=='db/'].Expiration.Days | [0]" --output text)" "$BackupRetentionDays")"
expect "uploads/ raderas efter $BackupRetentionDays dagar"     ja "$(yes_if equals "$(aws s3api get-bucket-lifecycle-configuration --bucket "$B" --query "Rules[?Prefix=='uploads/' || Filter.Prefix=='uploads/'].Expiration.Days | [0]" --output text)" "$BackupRetentionDays")"
expect "Det finns en databasbackup"                            ja "$(yes_if bash -c "aws s3 ls s3://$B/db/ | grep -q '\.sql\.gz'")"
expect "Det finns en backup av uppladdade filer"               ja "$(yes_if bash -c "aws s3 ls s3://$B/uploads/ | grep -q '\.tar\.gz'")"

echo ""
echo "== Nätverk =="
expect "HTTP 80 till webbservern"                              ja  "$(yes_if port_open "$WEB_IP" 80)"
expect "HTTPS 443 till webbservern"                            ja  "$(yes_if port_open "$WEB_IP" 443)"
expect "SSH 22 direkt till webbservern"                        nej "$(yes_if port_open "$WEB_IP" 22)"
expect "SSH 22 till bastion från min IP"                       ja  "$(yes_if port_open "$BASTION_IP" 22)"
expect "Väg från de privata subnäten till internet"            nej "$(yes_if bash -c "aws ec2 describe-route-tables --region $Region --route-table-ids $(stack_output network PrivateRouteTableId) --output text | grep -q 0.0.0.0/0")"

echo ""
echo "== Databas och lagring =="
expect "Databasen är publikt åtkomlig"                         nej "$(yes_if equals "$(db PubliclyAccessible)" True)"
expect "Multi-AZ"                                              "$([ "$DbMultiAZ" = true ] && echo ja || echo nej)" "$(yes_if equals "$(db MultiAZ)" True)"
expect "Databasens lagring är krypterad"                       ja  "$(yes_if equals "$(db StorageEncrypted)" True)"
expect "RDS automatisk backup $DbBackupRetentionDays dag(ar)"  ja  "$(yes_if equals "$(db BackupRetentionPeriod)" "$DbBackupRetentionDays")"
expect "EFS är krypterad"                                      ja  "$(yes_if equals "$(aws efs describe-file-systems --region "$Region" --file-system-id "$EFS_ID" --query 'FileSystems[0].Encrypted' --output text)" True)"
expect "EFS är monterad på wp-content med TLS"                 ja  "$(remote on_web "findmnt -n -o FSTYPE /var/www/html/wp-content | grep -q nfs4 && grep -q 'wp-content efs _netdev,tls' /etc/fstab && echo ok")"

echo ""
echo "== WordPress =="
expect "Startsidan visar Novatrix"                             ja  "$(yes_if bash -c "curl -s -m 10 http://$WEB_IP/ | grep Novatrix > /dev/null")"
expect "WordPress är installerat och når databasen"            ja  "$(remote on_web "sudo /usr/local/bin/wp --allow-root --path=/var/www/html core is-installed && echo ok")"
expect "Webbservern kräver IMDSv2"                             ja  "$(yes_if equals "$(aws ec2 describe-instances --region "$Region" --filters "Name=tag:Name,Values=$EnvName-web" Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text)" required)"

echo ""
echo "== Säkerhet mellan komponenterna =="
expect "Bastion når databasen (MySQL 3306)"                    nej "$(remote on_bastion "timeout 5 bash -c 'exec 3<>/dev/tcp/$DB_HOST/3306' && echo ok")"
expect "Webbservern kan läsa WordPress-lösenordet"             ja  "$(remote on_web "aws secretsmanager get-secret-value --region $Region --secret-id $EnvName/db/wordpress > /dev/null && echo ok")"
expect "Webbservern kan läsa databasens huvudlösenord"         nej "$(remote on_web "aws secretsmanager get-secret-value --region $Region --secret-id $EnvName/db/master > /dev/null && echo ok")"
expect "Webbservern kan läsa backuperna"                       nej "$(remote on_web "aws s3 ls s3://$B/db/ --region $Region > /dev/null && echo ok")"

echo ""
echo "Resultat: $PASS OK, $FAIL fel av $((PASS + FAIL)) tester"
[ "$FAIL" -eq 0 ]
