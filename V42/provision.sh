#!/bin/bash
# Skapar Novatrix webbmiljö: security group + EC2-instans med Apache och webbsida.
# Förutsätter: AWS CLI inloggat (aws login) och nyckelparet novatrix-key skapat i konsolen.
set -euo pipefail
cd "$(dirname "$0")"

REGION=eu-north-1
INSTANCE_TYPE=t3.micro
KEY_NAME=novatrix-key
KEY_PATH="$HOME/.ssh/$KEY_NAME.pem"
SG_NAME=novatrix-web-sg
TAG_NAME=novatrix-web
AMI=resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"

# 1. Kontrollera nyckelparet (i AWS och lokalt)
aws ec2 describe-key-pairs --region $REGION --key-names $KEY_NAME > /dev/null \
  || { echo "Nyckelparet $KEY_NAME saknas i $REGION"; exit 1; }
[ -f "$KEY_PATH" ] || { echo "Hittar inte den privata nyckeln $KEY_PATH"; exit 1; }

# 2. Avbryt om instansen redan körs
EXISTING=$(aws ec2 describe-instances --region $REGION \
  --filters Name=tag:Name,Values=$TAG_NAME Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$EXISTING" ]; then
  echo "Instansen $TAG_NAME körs redan ($EXISTING). Kör ./teardown.sh först."
  exit 1
fi

# 3. Security group: återanvänd om den finns, annars skapa
SG_ID=$(aws ec2 describe-security-groups --region $REGION \
  --filters Name=group-name,Values=$SG_NAME \
  --query 'SecurityGroups[0].GroupId' --output text)

if [ "$SG_ID" = "None" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
  SG_ID=$(aws ec2 create-security-group --region $REGION --group-name $SG_NAME \
    --description "Novatrix web: SSH fran min IP, HTTP fran alla" \
    --vpc-id $VPC_ID --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID \
    --protocol tcp --port 22 --cidr $MY_IP > /dev/null
  aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null
  echo "Skapade security group $SG_ID (SSH från $MY_IP, HTTP från alla)"
else
  echo "Återanvänder security group $SG_ID"
fi

# 4. Starta instansen med user data
INSTANCE_ID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --security-group-ids $SG_ID \
  --user-data file://user-data.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
  --query 'Instances[0].InstanceId' --output text)

echo "Startar $INSTANCE_ID ..."
aws ec2 wait instance-running --region $REGION --instance-ids $INSTANCE_ID

# 5. Skriv ut publik IP
IP=$(aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo ""
echo "Klart! Vänta 1-2 min medan user data installerar Apache."
echo "Webb: http://$IP"
echo "SSH:  ssh -i \"$KEY_PATH\" ec2-user@$IP"