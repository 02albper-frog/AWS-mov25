#!/bin/bash
# Gemensamma funktioner för V46-skripten. Läses in med: source ./lib.sh [miljö]
# Miljön är namnet på en fil i parameters/, t.ex. "prod" (standard) eller "test".

export MSYS_NO_PATHCONV=1   # hindrar Git Bash från att tolka /... och novatrix/... som sökvägar
ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/parameters/${1:-prod}.env"
[ -f "$ENV_FILE" ] || { echo "Hittar inte parameterfilen $ENV_FILE"; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

KEY_PATH="$HOME/.ssh/$KeyName.pem"
KNOWN_HOSTS="$HOME/.ssh/known_hosts_novatrix"
STACKS=(backup iam network data app)   # i den ordning de byggs

stack_name() { echo "$EnvName-$1"; }

# stack_output <stack> <nyckel>, t.ex. stack_output app WebUrl
stack_output() {
  aws cloudformation describe-stacks --region "$Region" --stack-name "$(stack_name "$1")" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2> /dev/null
}

stack_status() {
  aws cloudformation describe-stacks --region "$Region" --stack-name "$(stack_name "$1")" \
    --query "Stacks[0].StackStatus" --output text 2> /dev/null || echo "FINNS_INTE"
}

# secret_field <namn> <fält>: läser ett fält ur en hemlighet i Secrets Manager.
# Lösenorden innehåller bara bokstäver och siffror, så sed räcker (jq finns inte i Git Bash).
secret_field() {
  aws secretsmanager get-secret-value --region "$Region" --secret-id "$1" \
    --query SecretString --output text | sed -E "s/.*\"$2\" *: *\"([^\"]*)\".*/\1/"
}

ssh_opts() {
  echo "-i $KEY_PATH -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"
}

on_bastion() {
  # shellcheck disable=SC2046
  ssh $(ssh_opts) "ec2-user@$(stack_output app BastionPublicIp)" "$@"
}

# Webbservrarna i Auto Scaling-gruppen som är i drift: "instans-ID privat-IP zon" per rad
web_instances() {
  local ids
  ids=$(aws autoscaling describe-auto-scaling-groups --region "$Region" \
    --auto-scaling-group-names "$EnvName-web-asg" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" --output text)
  [ -n "$ids" ] && [ "$ids" != "None" ] || return 0
  # shellcheck disable=SC2086
  aws ec2 describe-instances --region "$Region" --instance-ids $ids \
    --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,Placement.AvailabilityZone]' \
    --output text | sort
}

# on_host <privat-IP> <kommando>: kör på en viss webbserver via bastion
on_host() {
  local bastion host="$1"
  bastion=$(stack_output app BastionPublicIp)
  shift
  # shellcheck disable=SC2046
  ssh $(ssh_opts) -o "ProxyCommand=ssh $(ssh_opts) -W %h:%p ec2-user@$bastion" "ec2-user@$host" "$@"
}

# on_web <kommando>: kör på den första webbservern i gruppen
on_web() {
  local ip
  ip=$(web_instances | head -n 1 | awk '{print $2}')
  [ -n "$ip" ] || { echo "Inga webbservrar i drift" >&2; return 1; }
  on_host "$ip" "$@"
}
