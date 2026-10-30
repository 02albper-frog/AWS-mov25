#!/bin/bash
# Sätter upp IAM för Novatrix: S3-bucket, policies, grupper, användare och EC2-roll.
# Körs av en administratör (albin-admin). Kan köras flera gånger.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # hindrar Git Bash från att tolka sökvägar i argument
cd "$(dirname "$0")"
source ./config.sh

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN_BASE="arn:aws:iam::$ACCOUNT_ID:policy"

# Fyller i platshållarna i en policyfil
render() {
  sed -e "s/__BUCKET__/$BUCKET/g" \
      -e "s/__ACCOUNT_ID__/$ACCOUNT_ID/g" \
      -e "s/__REGION__/$REGION/g" "$1"
}

echo "== 1. S3-bucket =="
if aws s3api head-bucket --bucket "$BUCKET" 2> /dev/null; then
  echo "Bucket $BUCKET finns redan"
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
  echo "Skapade bucket $BUCKET"
fi
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
echo "Blockerar all publik åtkomst till bucketen"
aws s3 cp index.html "s3://$BUCKET/web/index.html" --region "$REGION" > /dev/null
echo "Laddade upp index.html till web/"

echo ""
echo "== 2. Policies =="
create_policy() {
  local name="$1" file="$2"
  if aws iam get-policy --policy-arn "$POLICY_ARN_BASE/$name" > /dev/null 2>&1; then
    echo "Policy $name finns redan"
  else
    aws iam create-policy --policy-name "$name" \
      --policy-document "$(render "$file")" > /dev/null
    echo "Skapade policy $name"
  fi
}
create_policy "$DEV_POLICY"  policies/utveckling-policy.json
create_policy "$OPS_POLICY"  policies/drift-policy.json
create_policy "$ROLE_POLICY" policies/ec2-web-role-policy.json

echo ""
echo "== 3. Grupper och användare =="
setup_group() {
  local group="$1" policy="$2" user="$3"
  if ! aws iam get-group --group-name "$group" > /dev/null 2>&1; then
    aws iam create-group --group-name "$group" > /dev/null
    echo "Skapade grupp $group"
  fi
  aws iam attach-group-policy --group-name "$group" \
    --policy-arn "$POLICY_ARN_BASE/$policy"
  if ! aws iam get-user --user-name "$user" > /dev/null 2>&1; then
    aws iam create-user --user-name "$user" > /dev/null
    echo "Skapade användare $user"
  fi
  aws iam add-user-to-group --group-name "$group" --user-name "$user"
  echo "$user är medlem i $group med policyn $policy"
}
setup_group "$DEV_GROUP" "$DEV_POLICY" "$DEV_USER"
setup_group "$OPS_GROUP" "$OPS_POLICY" "$OPS_USER"

echo ""
echo "== 4. EC2-roll och instansprofil =="
if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
  echo "Roll $ROLE_NAME finns redan"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://policies/ec2-trust-policy.json \
    --description "Novatrix webbserver: las web/, skriv logs/" > /dev/null
  echo "Skapade roll $ROLE_NAME"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN_BASE/$ROLE_POLICY"

if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" > /dev/null 2>&1; then
  echo "Instansprofil $PROFILE_NAME finns redan"
else
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" > /dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
  echo "Skapade instansprofil $PROFILE_NAME med rollen $ROLE_NAME"
  echo "Väntar 15 sekunder så att IAM hinner spridas ..."
  sleep 15
fi

echo ""
echo "Klart! Kör ./verify-iam.sh för att testa behörigheterna."