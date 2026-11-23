#!/bin/bash
# V47: Verifierar att stacken blev som avsett: CloudFormation, lastbalanserare, Auto
# Scaling, nätverk, databas, lagring, WordPress, backup och säkerhet.
# Användning: ./verify.sh [miljö]
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh "${1:-prod}"

PASS=0
FAIL=0
expect() {  # <beskrivning> <förväntat> <resultat>
  local status
  if [ "$2" = "$3" ]; then status="OK "; PASS=$((PASS + 1)); else status="FEL"; FAIL=$((FAIL + 1)); fi
  printf "[%s] %-58s förväntat: %-4s resultat: %s\n" "$status" "$1" "$2" "$3"
}
yes_if() { if "$@" > /dev/null 2>&1; then echo "ja"; else echo "nej"; fi; }
remote() {  # <on_web|on_bastion> <kommando>: ja om sista raden är "ok"
  local result
  result=$("$1" "$2" 2> /dev/null | tail -n 1)
  if [ "$result" = "ok" ]; then echo "ja"; else echo "nej"; fi
}
port_open() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2> /dev/null; }
equals() { [ "$1" = "$2" ]; }
at_least() { [ "$1" -ge "$2" ] 2> /dev/null; }

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

WEB_URL=$(stack_output app WebUrl)
ALB_DNS=$(stack_output app AlbDnsName)
BASTION_IP=$(stack_output app BastionPublicIp)
TG_ARN=$(stack_output app TargetGroupArn)
ASG="$EnvName-web-asg"
DB_HOST=$(stack_output data DbEndpoint)
EFS_ID=$(stack_output data EfsId)
B="$BackupBucketName"
INSTANCES=$(web_instances)
FIRST_ID=$(echo "$INSTANCES" | head -n 1 | awk '{print $1}')
FIRST_PUBLIC=$(aws ec2 describe-instances --region "$Region" --instance-ids "$FIRST_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
asg() { aws autoscaling describe-auto-scaling-groups --region "$Region" --auto-scaling-group-names "$ASG" \
  --query "AutoScalingGroups[0].$1" --output text; }
db() { aws rds describe-db-instances --region "$Region" --db-instance-identifier "$EnvName-db" \
  --query "DBInstances[0].$1" --output text; }
healthy_count() { aws elbv2 describe-target-health --region "$Region" --target-group-arn "$TG_ARN" \
  --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text; }
same_salts() {
  local ip sums=""
  for ip in $(echo "$INSTANCES" | awk '{print $2}'); do
    sums+="$(on_host "$ip" "sudo grep -E \"'(AUTH_KEY|NONCE_SALT)'\" /var/www/html/wp-config.php | md5sum" 2> /dev/null)"$'\n'
  done
  [ "$(echo "$sums" | grep -c .)" -ge 2 ] && [ "$(echo "$sums" | grep . | sort -u | wc -l)" -eq 1 ]
}
served_by_several() {
  local servers
  servers=$(for _ in $(seq 1 12); do
    curl -s -o /dev/null -D - -m 5 "$WEB_URL/health.html" | grep -i '^x-novatrix-instance' | tr -d '\r'
  done | sort -u | wc -l)
  [ "$servers" -ge 2 ]
}

echo "== CloudFormation =="
for s in "${STACKS[@]}"; do
  expect "Stacken $(stack_name "$s") är klar" ja \
    "$(yes_if bash -c "[[ '$(stack_status "$s")' =~ ^(CREATE|UPDATE)_COMPLETE$ ]]")"
done
expect "Nätverket är oförändrat sedan deploy (ingen drift)"   ja "$(yes_if in_sync network)"

echo ""
echo "== Lastbalanserare =="
expect "Webbplatsen svarar via lastbalanseraren"               ja  "$(yes_if bash -c "curl -s -m 10 $WEB_URL/ | grep Novatrix > /dev/null")"
expect "Lastbalanseraren ligger i två zoner"                   ja  "$(yes_if equals "$(aws elbv2 describe-load-balancers --region "$Region" --names "$EnvName-alb" --query 'length(LoadBalancers[0].AvailabilityZones)' --output text)" 2)"
expect "Hälsokontroll på /health.html"                         ja  "$(yes_if equals "$(aws elbv2 describe-target-groups --region "$Region" --target-group-arns "$TG_ARN" --query 'TargetGroups[0].HealthCheckPath' --output text)" /health.html)"
expect "Minst $AsgMinSize friska servrar bakom lastbalanseraren" ja  "$(yes_if at_least "$(healthy_count)" "$AsgMinSize")"
expect "Trafiken fördelas på flera servrar"                    ja  "$(yes_if served_by_several)"
expect "Installationssidan install.php är stängd"              ja  "$(yes_if equals "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$WEB_URL/wp-admin/install.php")" 403)"

echo ""
echo "== Auto Scaling =="
expect "Gruppen har min $AsgMinSize och max $AsgMaxSize servrar"  ja "$(yes_if equals "$(asg '[MinSize,MaxSize]' | tr '\t' ' ')" "$AsgMinSize $AsgMaxSize")"
expect "Servrarna ligger i två zoner"                          ja  "$(yes_if equals "$(echo "$INSTANCES" | awk '{print $3}' | sort -u | wc -l)" 2)"
expect "Hälsokontrollen kommer från lastbalanseraren (ELB)"    ja  "$(yes_if equals "$(asg HealthCheckType)" ELB)"
expect "Skalning efter CPU med target tracking ($CpuTargetPercent %)" ja "$(yes_if equals "$(aws autoscaling describe-policies --region "$Region" --auto-scaling-group-name "$ASG" --query 'ScalingPolicies[0].[PolicyType,TargetTrackingConfiguration.TargetValue]' --output text | tr '\t' ' ')" "TargetTrackingScaling $CpuTargetPercent.0")"
expect "Alla servrar har samma WordPress-nycklar"              ja  "$(yes_if same_salts)"

echo ""
echo "== Nätverk =="
expect "HTTP 80 direkt till en webbserver"                     nej "$(yes_if port_open "$FIRST_PUBLIC" 80)"
expect "SSH 22 direkt till en webbserver"                      nej "$(yes_if port_open "$FIRST_PUBLIC" 22)"
expect "SSH 22 till bastion från min IP"                       ja  "$(yes_if port_open "$BASTION_IP" 22)"
expect "Väg från de privata subnäten till internet"            nej "$(yes_if bash -c "aws ec2 describe-route-tables --region $Region --route-table-ids $(stack_output network PrivateRouteTableId) --output text | grep -q 0.0.0.0/0")"

echo ""
echo "== Databas, lagring och backup =="
expect "Databasen är publikt åtkomlig"                         nej "$(yes_if equals "$(db PubliclyAccessible)" True)"
expect "Multi-AZ"                                              "$([ "$DbMultiAZ" = true ] && echo ja || echo nej)" "$(yes_if equals "$(db MultiAZ)" True)"
expect "Databasens lagring är krypterad"                       ja  "$(yes_if equals "$(db StorageEncrypted)" True)"
expect "EFS är krypterad"                                      ja  "$(yes_if equals "$(aws efs describe-file-systems --region "$Region" --file-system-id "$EFS_ID" --query 'FileSystems[0].Encrypted' --output text)" True)"
expect "EFS är monterad på wp-content med TLS"                 ja  "$(remote on_web "findmnt -n -o FSTYPE /var/www/html/wp-content | grep -q nfs4 && grep -q 'wp-content efs _netdev,tls' /etc/fstab && echo ok")"
expect "Backup-bucketen finns kvar om stacken tas bort"        ja  "$(yes_if bash -c "aws cloudformation get-template --region $Region --stack-name $(stack_name backup) --query TemplateBody --output text | grep -q 'DeletionPolicy: Retain'")"
expect "Det finns en databasbackup"                            ja  "$(yes_if bash -c "aws s3 ls s3://$B/db/ | grep -q '\.sql\.gz'")"

echo ""
echo "== WordPress och säkerhet =="
expect "WordPress är installerat och når databasen"            ja  "$(remote on_web "sudo /usr/local/bin/wp --allow-root --path=/var/www/html core is-installed && echo ok")"
expect "Alla webbservrar kräver IMDSv2"                        ja  "$(yes_if equals "$(aws ec2 describe-instances --region "$Region" --filters "Name=tag:Name,Values=$EnvName-web" Name=instance-state-name,Values=running --query "length(Reservations[].Instances[?MetadataOptions.HttpTokens!='required'][])" --output text | tr -d '\r')" 0)"
expect "Bastion når databasen (MySQL 3306)"                    nej "$(remote on_bastion "timeout 5 bash -c 'exec 3<>/dev/tcp/$DB_HOST/3306' && echo ok")"
expect "Webbservern kan läsa databasens huvudlösenord"         nej "$(remote on_web "aws secretsmanager get-secret-value --region $Region --secret-id $EnvName/db/master > /dev/null && echo ok")"
expect "Webbservern kan läsa backuperna"                       nej "$(remote on_web "aws s3 ls s3://$B/db/ --region $Region > /dev/null && echo ok")"

echo ""
echo "Lastbalanserare: $ALB_DNS"
echo "Webbservrar:"
echo "$INSTANCES" | awk '{printf "  %-21s %-14s %s\n", $1, $2, $3}'
echo ""
echo "Resultat: $PASS OK, $FAIL fel av $((PASS + FAIL)) tester"
[ "$FAIL" -eq 0 ]
