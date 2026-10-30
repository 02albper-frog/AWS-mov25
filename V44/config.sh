#!/bin/bash
# Gemensamma inställningar och hjälpfunktioner för V44-skripten.
# BUCKET måste vara globalt unikt i hela AWS (små bokstäver, siffror, bindestreck).

REGION=eu-north-1
BUCKET=novatrix-web-02albper

# EC2
KEY_NAME=novatrix-key
KEY_PATH="$HOME/.ssh/$KEY_NAME.pem"
INSTANCE_TYPE=t3.micro
TAG_NAME=novatrix-web
BASTION_NAME=novatrix-bastion

# Nätverk
VPC_NAME=novatrix-vpc
VPC_CIDR=10.0.0.0/16
AZ_A=${REGION}a
AZ_B=${REGION}b

MGMT_SUBNET=novatrix-mgmt-a;   MGMT_CIDR=10.0.0.0/24    # bastion (publikt)
WEB_SUBNET_A=novatrix-web-a;   WEB_CIDR_A=10.0.1.0/24   # webbserver (publikt)
DB_SUBNET_A=novatrix-db-a;     DB_CIDR_A=10.0.11.0/24   # databas (privat)
DB_SUBNET_B=novatrix-db-b;     DB_CIDR_B=10.0.12.0/24   # databas (privat, andra AZ)

IGW_NAME=novatrix-igw
PUBLIC_RT=novatrix-public-rt
PRIVATE_RT=novatrix-private-rt
MGMT_NACL=novatrix-mgmt-nacl
WEB_NACL=novatrix-web-nacl
DB_NACL=novatrix-db-nacl
BASTION_SG=novatrix-bastion-sg
WEB_SG=novatrix-web-sg
DB_SG=novatrix-db-sg

# IAM (från v43)
ROLE_NAME=novatrix-web-ec2-role
PROFILE_NAME=novatrix-web-ec2-profile
DEV_GROUP=novatrix-utveckling
OPS_GROUP=novatrix-drift
DEV_USER=anna-dev
OPS_USER=erik-drift
DEV_POLICY=novatrix-utveckling-policy
OPS_POLICY=novatrix-drift-policy
ROLE_POLICY=novatrix-web-ec2-policy

# ---- Hjälpfunktioner: slår upp resurs-ID via Name-taggen ("None" om den saknas) ----

vpc_id() {
  aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query 'Vpcs[0].VpcId' --output text
}

subnet_id() {
  aws ec2 describe-subnets --region "$REGION" --filters "Name=tag:Name,Values=$1" \
    --query 'Subnets[0].SubnetId' --output text
}

sg_id() {
  aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag:Name,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text
}

rt_id() {
  aws ec2 describe-route-tables --region "$REGION" --filters "Name=tag:Name,Values=$1" \
    --query 'RouteTables[0].RouteTableId' --output text
}

nacl_id() {
  aws ec2 describe-network-acls --region "$REGION" --filters "Name=tag:Name,Values=$1" \
    --query 'NetworkAcls[0].NetworkAclId' --output text
}

igw_id() {
  aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=tag:Name,Values=$IGW_NAME" \
    --query 'InternetGateways[0].InternetGatewayId' --output text
}

# instance_field <namn> <fält>, t.ex. instance_field novatrix-web PublicIpAddress
instance_field() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=pending,running \
    --query "Reservations[0].Instances[0].$2" --output text
}