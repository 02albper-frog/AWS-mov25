#!/bin/bash
# Tar bort bastion och webbserver. Nätverk, IAM och bucket behålls.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$TAG_NAME,$BASTION_NAME" \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --region "$REGION" --instance-ids $IDS > /dev/null
  echo "Terminerar $IDS ..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IDS
  echo "Instanserna är borttagna"
else
  echo "Inga instanser att ta bort"
fi