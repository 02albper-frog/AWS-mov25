#!/bin/bash
# V44: Bygger Novatrix nätverk som kod.
# VPC, internet gateway, fyra subnät i två AZ, route tables, NACL:er och security groups.
# Körs av en administratör (albin-admin).
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
EC2="aws ec2 --region $REGION"

# Taggar som sätts på alla resurser: Name + Project
tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=novatrix}]"; }

if [ "$(vpc_id)" != "None" ]; then
  echo "VPC:t $VPC_NAME finns redan. Kör ./teardown-network.sh först om du vill bygga om det."
  exit 1
fi

# ------------------------------------------------------------------
echo "== 1. VPC och internet gateway =="
VPC_ID=$($EC2 create-vpc --cidr-block "$VPC_CIDR" \
  --tag-specifications "$(tags vpc "$VPC_NAME")" --query Vpc.VpcId --output text)
$EC2 wait vpc-available --vpc-ids "$VPC_ID"
$EC2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames Value=true
echo "Skapade VPC $VPC_ID ($VPC_CIDR)"

IGW_ID=$($EC2 create-internet-gateway \
  --tag-specifications "$(tags internet-gateway "$IGW_NAME")" \
  --query InternetGateway.InternetGatewayId --output text)
$EC2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
echo "Skapade internet gateway $IGW_ID och kopplade den till VPC:t"

# ------------------------------------------------------------------
echo ""
echo "== 2. Subnät =="
create_subnet() {  # <namn> <cidr> <az>
  local id
  id=$($EC2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$2" --availability-zone "$3" \
    --tag-specifications "$(tags subnet "$1")" --query Subnet.SubnetId --output text)
  echo "Skapade subnät $1 ($2, $3)" >&2
  echo "$id"
}
MGMT_ID=$(create_subnet  "$MGMT_SUBNET"  "$MGMT_CIDR"  "$AZ_A")
WEB_A_ID=$(create_subnet "$WEB_SUBNET_A" "$WEB_CIDR_A" "$AZ_A")
DB_A_ID=$(create_subnet  "$DB_SUBNET_A"  "$DB_CIDR_A"  "$AZ_A")
DB_B_ID=$(create_subnet  "$DB_SUBNET_B"  "$DB_CIDR_B"  "$AZ_B")

# ------------------------------------------------------------------
echo ""
echo "== 3. Route tables =="
PUBLIC_RT_ID=$($EC2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "$(tags route-table "$PUBLIC_RT")" \
  --query RouteTable.RouteTableId --output text)
$EC2 create-route --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" > /dev/null
for subnet in "$MGMT_ID" "$WEB_A_ID"; do
  $EC2 associate-route-table --route-table-id "$PUBLIC_RT_ID" --subnet-id "$subnet" > /dev/null
done
echo "Publik route table $PUBLIC_RT_ID: 0.0.0.0/0 -> internet gateway (mgmt-a, web-a)"

PRIVATE_RT_ID=$($EC2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "$(tags route-table "$PRIVATE_RT")" \
  --query RouteTable.RouteTableId --output text)
for subnet in "$DB_A_ID" "$DB_B_ID"; do
  $EC2 associate-route-table --route-table-id "$PRIVATE_RT_ID" --subnet-id "$subnet" > /dev/null
done
echo "Privat route table $PRIVATE_RT_ID: endast lokal trafik inom VPC:t (db-a, db-b)"

# ------------------------------------------------------------------
echo ""
echo "== 4. NACL:er (subnätsnivå, stateless) =="
create_nacl() {  # <namn>
  $EC2 create-network-acl --vpc-id "$VPC_ID" \
    --tag-specifications "$(tags network-acl "$1")" \
    --query NetworkAcl.NetworkAclId --output text
}

# nacl_rule <acl> <in|out> <regelnummer> <cidr> <från-port> <till-port>  (protokoll 6 = TCP)
nacl_rule() {
  local direction=--ingress
  [ "$2" = out ] && direction=--egress
  $EC2 create-network-acl-entry --network-acl-id "$1" $direction --rule-number "$3" \
    --protocol 6 --port-range "From=$5,To=$6" --cidr-block "$4" --rule-action allow
}

# Kopplar ett subnät till en NACL (ersätter VPC:ts standard-NACL)
attach_nacl() {  # <acl> <subnät>
  local assoc
  assoc=$($EC2 describe-network-acls --filters "Name=association.subnet-id,Values=$2" \
    --query "NetworkAcls[0].Associations[?SubnetId=='$2'].NetworkAclAssociationId" --output text)
  $EC2 replace-network-acl-association --association-id "$assoc" --network-acl-id "$1" > /dev/null
}

# Management-subnätet (bastion): SSH in endast från admin-IP, SSH ut endast till webbsubnätet
MGMT_NACL_ID=$(create_nacl "$MGMT_NACL")
nacl_rule "$MGMT_NACL_ID" in  100 "$MY_IP"      22   22      # SSH från admin
nacl_rule "$MGMT_NACL_ID" in  110 "$WEB_CIDR_A" 1024 65535   # svar från webbservern
nacl_rule "$MGMT_NACL_ID" out 100 "$MY_IP"      1024 65535   # svar till admin
nacl_rule "$MGMT_NACL_ID" out 110 "$WEB_CIDR_A" 22   22      # SSH till webbservern
attach_nacl "$MGMT_NACL_ID" "$MGMT_ID"
echo "NACL $MGMT_NACL: SSH från din IP in, SSH till webbsubnätet ut, allt annat nekas"

# Webbsubnätet: HTTP/HTTPS från alla, SSH endast från management-subnätet
WEB_NACL_ID=$(create_nacl "$WEB_NACL")
nacl_rule "$WEB_NACL_ID" in  100 0.0.0.0/0    80   80        # HTTP
nacl_rule "$WEB_NACL_ID" in  110 0.0.0.0/0    443  443       # HTTPS
nacl_rule "$WEB_NACL_ID" in  120 "$MGMT_CIDR" 22   22        # SSH endast från bastion-subnätet
nacl_rule "$WEB_NACL_ID" in  130 0.0.0.0/0    1024 65535     # svar på serverns egna anrop
nacl_rule "$WEB_NACL_ID" out 100 0.0.0.0/0    1024 65535     # svar till besökare och bastion
nacl_rule "$WEB_NACL_ID" out 110 0.0.0.0/0    443  443       # HTTPS ut (S3, paketförråd)
nacl_rule "$WEB_NACL_ID" out 120 "$DB_CIDR_A" 3306 3306      # MySQL till databasen (v45)
nacl_rule "$WEB_NACL_ID" out 130 "$DB_CIDR_B" 3306 3306
attach_nacl "$WEB_NACL_ID" "$WEB_A_ID"
echo "NACL $WEB_NACL: HTTP/HTTPS från alla, SSH från bastion-subnätet, allt annat nekas"

# Databassubnäten: MySQL endast från webbsubnätet
DB_NACL_ID=$(create_nacl "$DB_NACL")
nacl_rule "$DB_NACL_ID" in  100 "$WEB_CIDR_A" 3306 3306      # MySQL från webbsubnätet
nacl_rule "$DB_NACL_ID" out 100 "$WEB_CIDR_A" 1024 65535     # svar till webbsubnätet
attach_nacl "$DB_NACL_ID" "$DB_A_ID"
attach_nacl "$DB_NACL_ID" "$DB_B_ID"
echo "NACL $DB_NACL: MySQL från webbsubnätet, allt annat nekas"

# ------------------------------------------------------------------
echo ""
echo "== 5. Security groups (instansnivå, stateful) =="
create_sg() {  # <namn> <beskrivning>
  local id
  id=$($EC2 create-security-group --vpc-id "$VPC_ID" --group-name "$1" --description "$2" \
    --tag-specifications "$(tags security-group "$1")" --query GroupId --output text)
  # Ta bort standardregeln som tillåter all utgående trafik
  $EC2 revoke-security-group-egress --group-id "$id" \
    --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' > /dev/null
  echo "$id"
}

# sg_rule <ingress|egress> <sg> <port> <cidr eller sg-id> <beskrivning>
sg_rule() {
  local peer
  if [[ "$4" == sg-* ]]; then
    peer="\"UserIdGroupPairs\":[{\"GroupId\":\"$4\",\"Description\":\"$5\"}]"
  else
    peer="\"IpRanges\":[{\"CidrIp\":\"$4\",\"Description\":\"$5\"}]"
  fi
  $EC2 authorize-security-group-"$1" --group-id "$2" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":$3,\"ToPort\":$3,$peer}]" > /dev/null
}

BASTION_SG_ID=$(create_sg "$BASTION_SG" "Bastion: SSH fran admin-IP")
WEB_SG_ID=$(create_sg "$WEB_SG" "Webbserver: HTTP/HTTPS fran alla, SSH fran bastion")
DB_SG_ID=$(create_sg "$DB_SG" "Databas: MySQL fran webbservern")

sg_rule ingress "$BASTION_SG_ID" 22   "$MY_IP"         "SSH fran admin-IP"
sg_rule egress  "$BASTION_SG_ID" 22   "$WEB_SG_ID"     "SSH till webbservern"
echo "$BASTION_SG: in SSH från din IP, ut SSH endast till webbservern"

sg_rule ingress "$WEB_SG_ID"     80   0.0.0.0/0        "HTTP fran alla"
sg_rule ingress "$WEB_SG_ID"     443  0.0.0.0/0        "HTTPS fran alla"
sg_rule ingress "$WEB_SG_ID"     22   "$BASTION_SG_ID" "SSH endast fran bastion"
sg_rule egress  "$WEB_SG_ID"     443  0.0.0.0/0        "HTTPS till S3 och paketforrad"
sg_rule egress  "$WEB_SG_ID"     3306 "$DB_SG_ID"      "MySQL till databasen"
echo "$WEB_SG: in HTTP/HTTPS från alla och SSH från bastion, ut HTTPS och MySQL"

sg_rule ingress "$DB_SG_ID"      3306 "$WEB_SG_ID"     "MySQL endast fran webbservern"
echo "$DB_SG: in MySQL endast från webbservern, ingen utgående trafik"

echo ""
echo "Klart! Nätverket $VPC_NAME är byggt. Kör ./provision.sh för att starta servrarna."