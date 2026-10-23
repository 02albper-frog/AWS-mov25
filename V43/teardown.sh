#!/bin/bash
# Tar bort Novatrix-instansen och security group. IAM och bucket behålls.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$TAG_NAME" \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --region "$REGION" --instance-ids $IDS > /dev/null
  echo "Terminerar $IDS ..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IDS
  echo "Instans borttagen"
else
  echo "Ingen instans att ta bort"
fi

aws ec2 delete-security-group --region "$REGION" --group-name "$SG_NAME" 2> /dev/null \
  && echo "Security group borttagen" \
  || echo "Ingen security group att ta bort"