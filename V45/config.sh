#!/bin/bash
# Gemensamma inställningar och hjälpfunktioner för V45-skripten.
# BUCKET och BACKUP_BUCKET måste vara globalt unika i hela AWS (små bokstäver, siffror, bindestreck).

REGION=eu-north-1
BUCKET=novatrix-web-02albper

# EC2
KEY_NAME=novatrix-key
KEY_PATH="$HOME/.ssh/$KEY_NAME.pem"
KNOWN_HOSTS="$HOME/.ssh/known_hosts_novatrix"
INSTANCE_TYPE=t3.micro
TAG_NAME=novatrix-web
BASTION_NAME=novatrix-bastion

# Nätverk (från v44)
VPC_NAME=novatrix-vpc
VPC_CIDR=10.0.0.0/16
AZ_A=${REGION}a
AZ_B=${REGION}b

MGMT_SUBNET=novatrix-mgmt;        MGMT_CIDR=10.0.0.0/24    # bastion (publikt)
WEB_SUBNET_A=novatrix-public;     WEB_CIDR_A=10.0.1.0/24   # webbserver (publikt)
DB_SUBNET_A=novatrix-private-a;   DB_CIDR_A=10.0.11.0/24   # databas och EFS (privat)
DB_SUBNET_B=novatrix-private-b;   DB_CIDR_B=10.0.12.0/24   # databas och EFS (privat, andra AZ)

IGW_NAME=novatrix-igw
PUBLIC_RT=novatrix-public-rt
PRIVATE_RT=novatrix-private-rt
MGMT_NACL=novatrix-mgmt-nacl
WEB_NACL=novatrix-public-nacl
DB_NACL=novatrix-private-nacl
BASTION_SG=novatrix-bastion-sg
WEB_SG=novatrix-web-sg
DB_SG=novatrix-db-sg
EFS_SG=novatrix-efs-sg

# Databas (RDS)
DB_ID=novatrix-db
DB_SUBNET_GROUP=novatrix-db-subnet-group
DB_ENGINE=mariadb
DB_CLASS=db.t4g.micro
DB_STORAGE_GB=20
DB_STORAGE_TYPE=gp3
DB_MULTI_AZ=true          # sätt till false om Free plan inte tillåter Multi-AZ
DB_BACKUP_DAYS=1          # högsta tillåtna på Free plan (i drift: 7-14 dagar)
DB_NAME=wordpress
DB_MASTER_USER=novatrixadmin
DB_WP_USER=wordpress

# Delad lagring (EFS)
EFS_NAME=novatrix-efs

# Backup (S3)
BACKUP_BUCKET=novatrix-backup-02albper
BACKUP_PREFIX=db/
BACKUP_DAYS=14

# Lösenord i SSM Parameter Store (krypterade, slumpas av storage.sh)
SSM_DB_MASTER=/novatrix/db/master-password
SSM_DB_WP=/novatrix/db/wp-password
SSM_WP_ADMIN=/novatrix/wp/admin-password

# WordPress
WP_TITLE="Novatrix AB"
WP_ADMIN_USER=novatrix-admin
WP_ADMIN_EMAIL=admin@novatrix.example

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

# ---- Hjälpfunktioner: slår upp resurs-ID via namn ("None" om resursen saknas) ----

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

efs_id() {
  aws efs describe-file-systems --region "$REGION" \
    --query "FileSystems[?Name=='$EFS_NAME'].FileSystemId | [0]" --output text
}

# db_field <fält>, t.ex. db_field Endpoint.Address
db_field() {
  aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_ID" \
    --query "DBInstances[0].$1" --output text 2> /dev/null || echo "None"
}

# ---- SSH: till bastion, och till webbservern via bastion (nyckeln stannar lokalt) ----

on_bastion() {
  local bastion
  bastion=$(instance_field "$BASTION_NAME" PublicIpAddress)
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KNOWN_HOSTS" \
    -o ConnectTimeout=10 -o BatchMode=yes "ec2-user@$bastion" "$@"
}

on_web() {
  local bastion web
  bastion=$(instance_field "$BASTION_NAME" PublicIpAddress)
  web=$(instance_field "$TAG_NAME" PrivateIpAddress)
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KNOWN_HOSTS" \
    -o ConnectTimeout=10 -o BatchMode=yes \
    -o "ProxyCommand=ssh -i $KEY_PATH -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o BatchMode=yes -W %h:%p ec2-user@$bastion" \
    "ec2-user@$web" "$@"
}
