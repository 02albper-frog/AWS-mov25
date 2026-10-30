#!/bin/bash
# Tar bort allt som network.sh skapade, i rätt ordning:
# security groups -> subnät -> route tables -> NACL:er -> internet gateway -> VPC.
# Kör ./teardown.sh först, eftersom nätverket inte kan tas bort medan instanser använder det.
set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

EC2="aws ec2 --region $REGION"
quiet() { "$@" > /dev/null 2>&1; }

VPC_ID=$(vpc_id)
if [ "$VPC_ID" = "None" ]; then
  echo "Inget nätverk att ta bort"
  exit 0
fi

RUNNING=$($EC2 describe-instances \
  --filters "Name=vpc-id,Values=$VPC_ID" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$RUNNING" ]; then
  echo "Instanser körs fortfarande i VPC:t ($RUNNING). Kör ./teardown.sh först."
  exit 1
fi

echo "== Security groups =="
# Grupperna refererar till varandra, så alla regler tas bort innan grupperna raderas
for name in "$BASTION_SG" "$WEB_SG" "$DB_SG"; do
  id=$(sg_id "$name")
  [ "$id" = "None" ] && continue
  rules_in=$($EC2 describe-security-group-rules --filters "Name=group-id,Values=$id" \
    --query 'SecurityGroupRules[?IsEgress==`false`].SecurityGroupRuleId' --output text)
  rules_out=$($EC2 describe-security-group-rules --filters "Name=group-id,Values=$id" \
    --query 'SecurityGroupRules[?IsEgress==`true`].SecurityGroupRuleId' --output text)
  [ -n "$rules_in" ]  && quiet $EC2 revoke-security-group-ingress --group-id "$id" --security-group-rule-ids $rules_in
  [ -n "$rules_out" ] && quiet $EC2 revoke-security-group-egress  --group-id "$id" --security-group-rule-ids $rules_out
done
for name in "$BASTION_SG" "$WEB_SG" "$DB_SG"; do
  id=$(sg_id "$name")
  [ "$id" != "None" ] && quiet $EC2 delete-security-group --group-id "$id" && echo "Tog bort $name"
done

echo "== Subnät =="
for name in "$MGMT_SUBNET" "$WEB_SUBNET_A" "$DB_SUBNET_A" "$DB_SUBNET_B"; do
  id=$(subnet_id "$name")
  [ "$id" != "None" ] && quiet $EC2 delete-subnet --subnet-id "$id" && echo "Tog bort $name"
done

echo "== Route tables =="
for name in "$PUBLIC_RT" "$PRIVATE_RT"; do
  id=$(rt_id "$name")
  [ "$id" != "None" ] && quiet $EC2 delete-route-table --route-table-id "$id" && echo "Tog bort $name"
done

echo "== NACL:er =="
for name in "$MGMT_NACL" "$WEB_NACL" "$DB_NACL"; do
  id=$(nacl_id "$name")
  [ "$id" != "None" ] && quiet $EC2 delete-network-acl --network-acl-id "$id" && echo "Tog bort $name"
done

echo "== Internet gateway =="
IGW_ID=$(igw_id)
if [ "$IGW_ID" != "None" ]; then
  quiet $EC2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  quiet $EC2 delete-internet-gateway --internet-gateway-id "$IGW_ID" && echo "Tog bort $IGW_NAME"
fi

echo "== VPC =="
quiet $EC2 delete-vpc --vpc-id "$VPC_ID" && echo "Tog bort $VPC_NAME"

echo ""
echo "Klart! Kontrollera i VPC-konsolen att $VPC_NAME är borta."