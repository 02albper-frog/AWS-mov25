#!/bin/bash
# V44: Verifierar trafikflödena i nätverket.
# Testar vad som släpps igenom och vad som blockeras: från internet, via bastion och från webbservern.
set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

WEB_IP=$(instance_field "$TAG_NAME" PublicIpAddress)
WEB_PRIV=$(instance_field "$TAG_NAME" PrivateIpAddress)
BASTION_IP=$(instance_field "$BASTION_NAME" PublicIpAddress)
BASTION_PRIV=$(instance_field "$BASTION_NAME" PrivateIpAddress)
if [ "$WEB_IP" = "None" ] || [ "$BASTION_IP" = "None" ]; then
  echo "Servrarna körs inte. Kör ./provision.sh först."
  exit 1
fi

# SSH-inställningar: egen known_hosts-fil, så att gamla IP-adresser från tidigare veckor inte krockar
KNOWN_HOSTS="$HOME/.ssh/known_hosts_novatrix"
SSH_OPTS=(-i "$KEY_PATH" -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KNOWN_HOSTS"
          -o ConnectTimeout=10 -o BatchMode=yes)
PROXY="ssh -i $KEY_PATH -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o BatchMode=yes -W %h:%p ec2-user@$BASTION_IP"

on_bastion() { ssh "${SSH_OPTS[@]}" "ec2-user@$BASTION_IP" "$1" 2> /dev/null; }
on_web()     { ssh "${SSH_OPTS[@]}" -o "ProxyCommand=$PROXY" "ec2-user@$WEB_PRIV" "$1" 2> /dev/null; }

# probe <värd> <port>
#   öppen     = anslutningen lyckades
#   stängd    = trafiken nådde servern men ingen tjänst lyssnar
#   blockerad = trafiken släpptes inte igenom (timeout)
probe() {
  local rc=0
  timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2> /dev/null || rc=$?
  case $rc in
    0)   echo "öppen" ;;
    124) echo "blockerad" ;;
    *)   echo "stängd" ;;
  esac
}

# remote <funktion> <kommando>: kör ett test på en server, "ok" blir öppen, annat blir blockerad
remote() {
  local result
  result=$("$1" "$2")
  if [ "$result" = "ok" ]; then echo "öppen"; else echo "blockerad"; fi
}

PASS=0
FAIL=0
expect() {  # <beskrivning> <förväntat> <resultat>
  local status
  if [ "$2" = "$3" ]; then status="OK "; PASS=$((PASS + 1)); else status="FEL"; FAIL=$((FAIL + 1)); fi
  printf "[%s] %-50s förväntat: %-10s resultat: %s\n" "$status" "$1" "$2" "$3"
}

HTTPS_OUT='curl -s -m 5 -o /dev/null https://aws.amazon.com && echo ok || echo fail'
HTTP_OUT='curl -s -m 5 -o /dev/null http://aws.amazon.com && echo ok || echo fail'

echo "== Från internet till webbservern =="
expect "HTTP 80 till webbservern"                 öppen     "$(probe "$WEB_IP" 80)"
expect "HTTPS 443 till webbservern"               öppen     "$(probe "$WEB_IP" 443)"
expect "Novatrix-sidan över HTTP"                 öppen     "$(curl -s -m 10 "http://$WEB_IP" | grep -q Novatrix && echo öppen || echo blockerad)"
expect "Novatrix-sidan över HTTPS"                öppen     "$(curl -sk -m 10 "https://$WEB_IP" | grep -q Novatrix && echo öppen || echo blockerad)"
expect "SSH 22 direkt till webbservern"           blockerad "$(probe "$WEB_IP" 22)"
expect "MySQL 3306 till webbservern"              blockerad "$(probe "$WEB_IP" 3306)"

echo ""
echo "== Från internet till bastion =="
expect "SSH 22 från min IP till bastion"          öppen     "$(probe "$BASTION_IP" 22)"
expect "HTTP 80 till bastion"                     blockerad "$(probe "$BASTION_IP" 80)"
expect "HTTPS 443 till bastion"                   blockerad "$(probe "$BASTION_IP" 443)"

echo ""
echo "== Administrativ åtkomst via bastion =="
expect "SSH via bastion till webbserverns privata IP" öppen "$(remote on_web 'echo ok')"
expect "Bastion når internet (HTTPS ut)"          blockerad "$(remote on_bastion "$HTTPS_OUT")"

echo ""
echo "== Från webbservern =="
expect "HTTPS 443 ut (S3 och paketförråd)"        öppen     "$(remote on_web "$HTTPS_OUT")"
expect "HTTP 80 ut till internet"                 blockerad "$(remote on_web "$HTTP_OUT")"
expect "Läsa webbsidan från S3 med IAM-rollen"    öppen     "$(remote on_web "aws s3 cp s3://$BUCKET/web/index.html - --region $REGION | grep -q Novatrix && echo ok || echo fail")"
expect "SSH från webbservern till bastion"        blockerad "$(remote on_web "timeout 5 bash -c 'exec 3<>/dev/tcp/$BASTION_PRIV/22' && echo ok || echo fail")"

echo ""
echo "== Nätverksstruktur =="
ROUTES=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=tag:Name,Values=$PRIVATE_RT" \
  --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'])" --output text)
expect "Väg från privata subnät till internet"    blockerad "$([ "$ROUTES" = "0" ] && echo blockerad || echo öppen)"
PUBLIC_DB=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=tag:Name,Values=$DB_SUBNET_A,$DB_SUBNET_B" \
  --query "length(Subnets[?MapPublicIpOnLaunch])" --output text)
expect "Publika IP-adresser i privata subnät"     blockerad "$([ "$PUBLIC_DB" = "0" ] && echo blockerad || echo öppen)"

echo ""
echo "Resultat: $PASS OK, $FAIL fel av $((PASS + FAIL)) tester"
[ "$FAIL" -eq 0 ]