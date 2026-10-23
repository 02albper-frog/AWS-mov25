#!/bin/bash
# Tar bort allt som setup-iam.sh skapade: användare, grupper, roll, policies och bucket.
# Kör ./teardown.sh först, eftersom rollen inte kan tas bort medan en instans använder den.
set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN_BASE="arn:aws:iam::$ACCOUNT_ID:policy"

RUNNING=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$TAG_NAME" \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$RUNNING" ]; then
  echo "Instansen körs fortfarande ($RUNNING). Kör ./teardown.sh först."
  exit 1
fi

quiet() { "$@" > /dev/null 2>&1; }

echo "== Användare och grupper =="
for entry in "$DEV_USER:$DEV_GROUP:$DEV_POLICY" "$OPS_USER:$OPS_GROUP:$OPS_POLICY"; do
  IFS=: read -r user group policy <<< "$entry"
  quiet aws iam remove-user-from-group --group-name "$group" --user-name "$user"
  quiet aws iam delete-user --user-name "$user" && echo "Tog bort användare $user"
  quiet aws iam detach-group-policy --group-name "$group" --policy-arn "$POLICY_ARN_BASE/$policy"
  quiet aws iam delete-group --group-name "$group" && echo "Tog bort grupp $group"
done

echo "== EC2-roll =="
quiet aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
quiet aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" \
  && echo "Tog bort instansprofil $PROFILE_NAME"
quiet aws iam detach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN_BASE/$ROLE_POLICY"
quiet aws iam delete-role --role-name "$ROLE_NAME" && echo "Tog bort roll $ROLE_NAME"

echo "== Policies =="
for policy in "$DEV_POLICY" "$OPS_POLICY" "$ROLE_POLICY"; do
  quiet aws iam delete-policy --policy-arn "$POLICY_ARN_BASE/$policy" \
    && echo "Tog bort policy $policy"
done

echo "== S3 =="
quiet aws s3 rm "s3://$BUCKET" --recursive
quiet aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" \
  && echo "Tog bort bucket $BUCKET"

echo ""
echo "Klart! Kontrollera i IAM- och S3-konsolen att allt är borta."