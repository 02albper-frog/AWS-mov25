#!/bin/bash
# V46: Förhandsgranskar en ändring i en template med ett change set, utan att genomföra den.
# Visar vilka resurser som läggs till, ändras eller byts ut.
# Användning: ./preview-change.sh <stack> [miljö]     t.ex. ./preview-change.sh data
# Genomför sedan ändringen med ./deploy.sh (eller execute-change-set, se utskriften).
set -euo pipefail
cd "$(dirname "$0")"
STACK="${1:?Ange stack: backup, iam, network, data eller app}"
source ./lib.sh "${2:-prod}"

case "$STACK" in
  backup)  TEMPLATE=templates/01-backup.yaml ;;
  iam)     TEMPLATE=templates/02-iam.yaml ;;
  network) TEMPLATE=templates/03-network.yaml ;;
  data)    TEMPLATE=templates/04-data.yaml ;;
  app)     TEMPLATE=templates/05-app.yaml ;;
  *) echo "Okänd stack: $STACK"; exit 1 ;;
esac

NAME=$(stack_name "$STACK")
CHANGESET="forhandsgranskning-$(date +%Y%m%d%H%M%S)"
AdminCidr="${AdminCidr:-$(curl -s https://checkip.amazonaws.com)/32}"

# Samma parametrar som deploy.sh, men bara de som templaten faktiskt har
PARAMS=()
for key in $(aws cloudformation validate-template --region "$Region" --template-body "file://$TEMPLATE" \
               --query 'Parameters[].ParameterKey' --output text); do
  if [ -n "${!key:-}" ]; then
    PARAMS+=("ParameterKey=$key,ParameterValue=${!key}")
  else
    PARAMS+=("ParameterKey=$key,UsePreviousValue=true")
  fi
done

aws cloudformation create-change-set --region "$Region" \
  --stack-name "$NAME" --change-set-name "$CHANGESET" \
  --template-body "file://$TEMPLATE" --parameters "${PARAMS[@]}" \
  --capabilities CAPABILITY_NAMED_IAM > /dev/null
aws cloudformation wait change-set-create-complete --region "$Region" \
  --stack-name "$NAME" --change-set-name "$CHANGESET" 2> /dev/null || true

STATUS=$(aws cloudformation describe-change-set --region "$Region" --stack-name "$NAME" \
  --change-set-name "$CHANGESET" --query StatusReason --output text)
if [[ "$STATUS" == *"didn't contain changes"* ]]; then
  echo "Inga ändringar i $NAME jämfört med det som körs."
  aws cloudformation delete-change-set --region "$Region" --stack-name "$NAME" --change-set-name "$CHANGESET"
  exit 0
fi

echo "== Ändringar i $NAME =="
aws cloudformation describe-change-set --region "$Region" --stack-name "$NAME" \
  --change-set-name "$CHANGESET" \
  --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' \
  --output table

echo ""
echo "Replacement=True betyder att resursen byts ut (tas bort och skapas på nytt)."
echo "Genomför:  aws cloudformation execute-change-set --region $Region --stack-name $NAME --change-set-name $CHANGESET"
echo "Avbryt:    aws cloudformation delete-change-set --region $Region --stack-name $NAME --change-set-name $CHANGESET"
