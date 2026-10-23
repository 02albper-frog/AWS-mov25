#!/bin/bash
# V43: Startar Novatrix webbserver med IAM-rollen novatrix-web-ec2-role.
# Förutsätter: setup-iam.sh har körts och nyckelparet novatrix-key finns.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

KEY_PATH="$HOME/.ssh/$KEY_NAME.pem"
INSTANCE_TYPE=t3.micro
AMI=resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"

# 1. Kontrollera nyckelparet (i AWS och lokalt)
aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" > /dev/null \
  || { echo "Nyckelparet $KEY_NAME saknas i $REGION"; exit 1; }
[ -f "$KEY_PATH" ] || { echo "Hittar inte den privata nyckeln $KEY_PATH"; exit 1; }

# 2. Kontrollera att instansprofilen finns
aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" > /dev/null \
  || { echo "Instansprofilen $PROFILE_NAME saknas. Kör ./setup-iam.sh först."; exit 1; }

# 3. Avbryt om instansen redan körs
EXISTING=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$TAG_NAME" Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$EXISTING" ]; then
  echo "Instansen $TAG_NAME körs redan ($EXISTING). Kör ./teardown.sh först."
  exit 1
fi

# 4. Security group: återanvänd om den finns, annars skapa
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)

if [ "$SG_ID" = "None" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
  SG_ID=$(aws ec2 create-security-group --region "$REGION" --group-name "$SG_NAME" \
    --description "Novatrix web: SSH fran min IP, HTTP fran alla" \
    --vpc-id "$VPC_ID" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "$MY_IP" > /dev/null
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null
  echo "Skapade security group $SG_ID (SSH från din IP, HTTP från alla)"
else
  echo "Återanvänder security group $SG_ID"
fi

# 5. Fyll i bucket och region i user data
USER_DATA=$(sed -e "s/__BUCKET__/$BUCKET/g" -e "s/__REGION__/$REGION/g" user-data.sh)

# 6. Starta instansen med IAM-rollen
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
  --query 'Instances[0].InstanceId' --output text)

echo "Startar $INSTANCE_ID med rollen $ROLE_NAME ..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo ""
echo "Klart! Vänta 1-2 min medan user data installerar Apache och hämtar sidan från S3."
echo "Webb:    http://$IP"
echo "SSH:     ssh -i \"$KEY_PATH\" ec2-user@$IP"
echo "Loggar:  aws s3 ls s3://$BUCKET/logs/"