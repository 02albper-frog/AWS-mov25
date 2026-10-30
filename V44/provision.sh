#!/bin/bash
# V44: Startar bastion och webbserver i Novatrix VPC.
# Förutsätter: setup-iam.sh och network.sh har körts, och nyckelparet novatrix-key finns.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

AMI=resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
EC2="aws ec2 --region $REGION"

# 1. Kontrollera förutsättningarna
$EC2 describe-key-pairs --key-names "$KEY_NAME" > /dev/null \
  || { echo "Nyckelparet $KEY_NAME saknas i $REGION"; exit 1; }
[ -f "$KEY_PATH" ] || { echo "Hittar inte den privata nyckeln $KEY_PATH"; exit 1; }
aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" > /dev/null \
  || { echo "Instansprofilen $PROFILE_NAME saknas. Kör ./setup-iam.sh först."; exit 1; }
[ "$(vpc_id)" != "None" ] \
  || { echo "Nätverket $VPC_NAME saknas. Kör ./network.sh först."; exit 1; }

# 2. Avbryt om servrarna redan körs
for name in "$BASTION_NAME" "$TAG_NAME"; do
  if [ "$(instance_field "$name" InstanceId)" != "None" ]; then
    echo "$name körs redan. Kör ./teardown.sh först."
    exit 1
  fi
done

# 3. Slå upp nätverket
MGMT_ID=$(subnet_id "$MGMT_SUBNET")
WEB_A_ID=$(subnet_id "$WEB_SUBNET_A")
BASTION_SG_ID=$(sg_id "$BASTION_SG")
WEB_SG_ID=$(sg_id "$WEB_SG")

# launch <namn> <subnät> <security group> [fler argument]
# IMDSv2 krävs (HttpTokens=required) för att skydda rollens nycklar mot SSRF-attacker.
launch() {
  local name="$1" subnet="$2" sg="$3"
  shift 3
  $EC2 run-instances \
    --image-id "$AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --subnet-id "$subnet" \
    --security-group-ids "$sg" \
    --associate-public-ip-address \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=Project,Value=novatrix}]" \
    "$@" \
    --query 'Instances[0].InstanceId' --output text
}

# 4. Bastion: ingen IAM-roll och ingen user data, den ska bara vidarebefordra SSH
BASTION_ID=$(launch "$BASTION_NAME" "$MGMT_ID" "$BASTION_SG_ID")
echo "Startar bastion $BASTION_ID i $MGMT_SUBNET (ingen IAM-roll)"

# 5. Webbserver: IAM-rollen från v43 och user data som hämtar sidan från S3
USER_DATA=$(sed -e "s/__BUCKET__/$BUCKET/g" -e "s/__REGION__/$REGION/g" user-data-web.sh)
WEB_ID=$(launch "$TAG_NAME" "$WEB_A_ID" "$WEB_SG_ID" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --user-data "$USER_DATA")
echo "Startar webbserver $WEB_ID i $WEB_SUBNET_A med rollen $ROLE_NAME"

$EC2 wait instance-running --instance-ids "$BASTION_ID" "$WEB_ID"

BASTION_IP=$(instance_field "$BASTION_NAME" PublicIpAddress)
WEB_IP=$(instance_field "$TAG_NAME" PublicIpAddress)
WEB_PRIV=$(instance_field "$TAG_NAME" PrivateIpAddress)

echo ""
echo "Klart! Vänta 2-3 minuter medan webbservern installerar Apache."
echo ""
echo "Webb:     http://$WEB_IP"
echo "          https://$WEB_IP  (självsignerat certifikat)"
echo "Bastion:  ssh -i \"$KEY_PATH\" ec2-user@$BASTION_IP"
echo "Webb-SSH: ssh -i \"$KEY_PATH\" -o ProxyCommand=\"ssh -i $KEY_PATH -W %h:%p ec2-user@$BASTION_IP\" ec2-user@$WEB_PRIV"
echo ""
echo "Kör sedan ./verify-network.sh för att testa trafikflödena."