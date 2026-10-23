#!/bin/bash
# Verifierar behörigheterna med IAM Policy Simulator.
# Varje rad testar en identitet + åtgärd och jämför med förväntat resultat.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ANNA="arn:aws:iam::$ACCOUNT_ID:user/$DEV_USER"
ERIK="arn:aws:iam::$ACCOUNT_ID:user/$OPS_USER"
ROLE="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
OTHER_ROLE="arn:aws:iam::$ACCOUNT_ID:role/NagonAnnanRoll"

BUCKET_ARN="arn:aws:s3:::$BUCKET"
WEB="$BUCKET_ARN/web/index.html"
LOGS="$BUCKET_ARN/logs/test.log"
INSTANCE="arn:aws:ec2:$REGION:$ACCOUNT_ID:instance/i-0123456789abcdef0"

PASS=0
FAIL=0

# check <vem> <arn> <åtgärd> <resurs> <etikett> <tillåten|nekad> [nyckel=värde ...]
check() {
  local who="$1" arn="$2" action="$3" resource="$4" label="$5" expected="$6"
  shift 6
  local args=(--policy-source-arn "$arn" --action-names "$action" --resource-arns "$resource")
  if [ $# -gt 0 ]; then
    local ctx=() c
    for c in "$@"; do
      ctx+=("ContextKeyName=${c%%=*},ContextKeyValues=${c#*=},ContextKeyType=string")
    done
    args+=(--context-entries "${ctx[@]}")
  fi

  local decision actual status
  decision=$(aws iam simulate-principal-policy "${args[@]}" \
    --query 'EvaluationResults[0].EvalDecision' --output text)
  if [ "$decision" = "allowed" ]; then actual="tillåten"; else actual="nekad"; fi

  if [ "$actual" = "$expected" ]; then
    status="OK "; PASS=$((PASS + 1))
  else
    status="FEL"; FAIL=$((FAIL + 1))
  fi
  printf "[%s] %-11s %-26s %-24s förväntat: %-9s resultat: %s\n" \
    "$status" "$who" "$action" "$label" "$expected" "$actual"
}

echo "== Utveckling ($DEV_USER) =="
check "$DEV_USER" "$ANNA" s3:PutObject     "$WEB"        "web/index.html"     tillåten
check "$DEV_USER" "$ANNA" s3:GetObject     "$WEB"        "web/index.html"     tillåten
check "$DEV_USER" "$ANNA" s3:ListBucket    "$BUCKET_ARN" "prefix web/"        tillåten s3:prefix=web/
check "$DEV_USER" "$ANNA" s3:ListBucket    "$BUCKET_ARN" "prefix logs/"       nekad    s3:prefix=logs/
check "$DEV_USER" "$ANNA" s3:GetObject     "$LOGS"       "logs/test.log"      nekad
check "$DEV_USER" "$ANNA" s3:DeleteBucket  "$BUCKET_ARN" "bucketen"           nekad
check "$DEV_USER" "$ANNA" ec2:RunInstances "*"           "eu-north-1"         nekad    aws:RequestedRegion=$REGION
check "$DEV_USER" "$ANNA" iam:PassRole     "$ROLE"       "webbrollen"         nekad    iam:PassedToService=ec2.amazonaws.com

echo ""
echo "== Drift ($OPS_USER) =="
check "$OPS_USER" "$ERIK" ec2:RunInstances     "*"          "eu-north-1"         tillåten aws:RequestedRegion=$REGION
check "$OPS_USER" "$ERIK" ec2:RunInstances     "*"          "us-east-1"          nekad    aws:RequestedRegion=us-east-1
check "$OPS_USER" "$ERIK" ec2:TerminateInstances "$INSTANCE" "Name=novatrix-web" tillåten ec2:ResourceTag/Name=novatrix-web
check "$OPS_USER" "$ERIK" ec2:TerminateInstances "$INSTANCE" "Name=annan-server" nekad    ec2:ResourceTag/Name=annan-server
check "$OPS_USER" "$ERIK" iam:PassRole         "$ROLE"       "webbrollen till EC2" tillåten iam:PassedToService=ec2.amazonaws.com
check "$OPS_USER" "$ERIK" iam:PassRole         "$OTHER_ROLE" "annan roll"         nekad    iam:PassedToService=ec2.amazonaws.com
check "$OPS_USER" "$ERIK" s3:GetObject         "$LOGS"       "logs/test.log"      tillåten
check "$OPS_USER" "$ERIK" s3:PutObject         "$WEB"        "web/index.html"     nekad

echo ""
echo "== EC2-rollen ($ROLE_NAME) =="
check "ec2-roll" "$ROLE" s3:GetObject         "$WEB"        "web/index.html" tillåten
check "ec2-roll" "$ROLE" s3:PutObject         "$LOGS"       "logs/test.log"  tillåten
check "ec2-roll" "$ROLE" s3:PutObject         "$WEB"        "web/index.html" nekad
check "ec2-roll" "$ROLE" s3:DeleteObject      "$WEB"        "web/index.html" nekad
check "ec2-roll" "$ROLE" s3:GetObject         "$LOGS"       "logs/test.log"  nekad
check "ec2-roll" "$ROLE" s3:ListBucket        "$BUCKET_ARN" "bucketen"       nekad
check "ec2-roll" "$ROLE" s3:ListAllMyBuckets  "*"           "alla buckets"   nekad

echo ""
echo "Resultat: $PASS OK, $FAIL fel av $((PASS + FAIL)) tester"
[ "$FAIL" -eq 0 ]