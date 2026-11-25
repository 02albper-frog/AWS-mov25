#!/bin/bash
# V48: Bygger hela Novatrix-miljön från templates med CloudFormation.
# Användning: ./deploy.sh [miljö]      (miljö = fil i parameters/, standard "prod")
# Stackarna byggs i ordning, eftersom de använder varandras exports:
#   backup -> iam -> network -> data -> app -> monitoring
# Körs igen efter en ändring i en template: då uppdateras bara det som ändrats.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh "${1:-prod}"

# Kontrollera förutsättningarna
aws sts get-caller-identity > /dev/null || { echo "Inte inloggad. Kör aws login först."; exit 1; }
aws ec2 describe-key-pairs --region "$Region" --key-names "$KeyName" > /dev/null \
  || { echo "Nyckelparet $KeyName saknas i $Region."; exit 1; }
[ -f "$KEY_PATH" ] || { echo "Hittar inte den privata nyckeln $KEY_PATH"; exit 1; }
[ -n "${AlarmEmail:-}" ] || {
  echo "AlarmEmail saknas. Skapa $LOCAL_ENV_FILE med raden:"
  echo "  AlarmEmail=din.adress@example.com"
  exit 1
}

# Din nuvarande IP-adress får SSH till bastion (om AdminCidr inte står i parameterfilen)
AdminCidr="${AdminCidr:-$(curl -s https://checkip.amazonaws.com)/32}"

# Alla värden från parameterfilen skickas med. CloudFormation använder bara de
# parametrar som finns i respektive template.
OVERRIDES=()
while IFS='=' read -r key _; do
  OVERRIDES+=("$key=${!key}")
done < <(grep -hE '^[A-Za-z][A-Za-z0-9]*=' "$ENV_FILE" "$LOCAL_ENV_FILE" 2> /dev/null | sort -u -t= -k1,1)
OVERRIDES+=("AdminCidr=$AdminCidr")

echo "== Validerar templates =="
for t in templates/*.yaml; do
  aws cloudformation validate-template --region "$Region" --template-body "file://$t" > /dev/null
  echo "OK: $t"
done

deploy_stack() {  # <stack> <template>
  local name
  name=$(stack_name "$1")
  echo ""
  echo "== $name ($2) =="
  aws cloudformation deploy --region "$Region" \
    --stack-name "$name" \
    --template-file "$2" \
    --parameter-overrides "${OVERRIDES[@]}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags Project=novatrix "Environment=$EnvName" ManagedBy=CloudFormation \
    --no-fail-on-empty-changeset
}

deploy_stack backup  templates/01-backup.yaml
deploy_stack iam     templates/02-iam.yaml
deploy_stack network templates/03-network.yaml
deploy_stack data       templates/04-data.yaml        # RDS tar ofta 10-20 minuter
deploy_stack app        templates/05-app.yaml         # väntar tills alla webbservrar har signalerat
deploy_stack monitoring templates/06-monitoring.yaml  # larm, SNS, dashboard och sajtkoll

echo ""
echo "== Stackar =="
aws cloudformation describe-stacks --region "$Region" \
  --query "Stacks[?starts_with(StackName, '$EnvName-')].[StackName,StackStatus]" --output table

echo ""
echo "== Webbservrar i $EnvName-web-asg =="
web_instances | awk '{printf "%-21s %-14s %s\n", $1, $2, $3}'

echo ""
echo "Klart!"
echo "Webb:     $(stack_output app WebUrl)"
echo "Databas:  $(stack_output data DbEndpoint)"
echo "EFS:      $(stack_output data EfsId)"
echo "Backup:   s3://$(stack_output backup BackupBucketName)/"
echo "Dashboard: $(stack_output monitoring DashboardUrl)"
echo ""
SUB=$(aws sns list-subscriptions-by-topic --region "$Region" --topic-arn "$(stack_output monitoring AlarmTopicArn)" \
  --query 'Subscriptions[0].SubscriptionArn' --output text)
if [ "$SUB" = "PendingConfirmation" ]; then
  echo "OBS: Bekräfta prenumerationen på larmen med länken i mailet 'AWS Notification'"
  echo "     som har skickats till $AlarmEmail. Annars kommer inga larm fram."
fi
echo ""
echo "Nästa steg:"
echo "  ./install-wordpress.sh   ny installation av WordPress (en gång, gäller alla servrar)"
echo "  ./restore-wordpress.sh   eller: återställ från senaste backupen i S3"
echo "  (novatrix-sajtkoll larmar om WordPress inte är installerat inom cirka 10 minuter)"
