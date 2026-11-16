#!/bin/bash
# V46: River Novatrix-miljön i omvänd ordning: app -> data -> network -> iam.
# Backup-stacken och bucketen med backuperna lämnas ALLTID kvar.
# Innan servrarna rivs tas en sista backup av databasen och filerna, så att
# miljön kan återställas med ./deploy.sh + ./restore-wordpress.sh.
# Användning: ./destroy.sh [miljö] [--utan-backup]
set -uo pipefail
cd "$(dirname "$0")"
ENV_NAME=prod
SKIP_BACKUP=false
for arg in "$@"; do
  case "$arg" in
    --utan-backup) SKIP_BACKUP=true ;;
    *) ENV_NAME="$arg" ;;
  esac
done
source ./lib.sh "$ENV_NAME"

delete_stack() {  # <stack>
  local name
  name=$(stack_name "$1")
  if [ "$(stack_status "$1")" = "FINNS_INTE" ]; then
    echo "$name finns inte"
    return
  fi
  echo "Tar bort $name ..."
  aws cloudformation delete-stack --region "$Region" --stack-name "$name"
  if aws cloudformation wait stack-delete-complete --region "$Region" --stack-name "$name"; then
    echo "Tog bort $name"
  else
    echo "Kunde inte ta bort $name. Se fliken Events för stacken i CloudFormation-konsolen."
    exit 1
  fi
}

echo "== 1. Sista backup =="
if [ "$SKIP_BACKUP" = true ]; then
  echo "Hoppar över backup (--utan-backup)"
elif [ "$(stack_status app)" = "FINNS_INTE" ]; then
  echo "Ingen webbserver, ingen backup tas"
elif on_web "sudo /usr/local/bin/novatrix-backup.sh"; then
  echo "Backup klar"
else
  echo "Backupen misslyckades. Avbryter, så att inget går förlorat."
  echo "Kör ./destroy.sh --utan-backup om du vill riva ändå."
  exit 1
fi

echo ""
echo "== 2. Stackar =="
delete_stack app
delete_stack data
# CloudFormation schemalägger raderingen av lösenorden med 7-30 dagars väntetid. De raderas
# här direkt efteråt, så att namnen kan användas igen nästa gång miljön byggs. Det måste ske
# EFTER data-stacken, eftersom databasen läser sitt lösenord via en dynamisk referens även
# när den tas bort.
for s in "$EnvName/db/master" "$EnvName/db/wordpress" "$EnvName/wp/admin"; do
  aws secretsmanager delete-secret --region "$Region" --secret-id "$s" \
    --force-delete-without-recovery > /dev/null 2>&1 && echo "Raderade hemligheten $s"
done
delete_stack network
delete_stack iam

echo ""
echo "Kvar finns $(stack_name backup) med bucketen s3://$BackupBucketName:"
aws s3 ls "s3://$BackupBucketName/db/" --region "$Region" | tail -n 3
aws s3 ls "s3://$BackupBucketName/uploads/" --region "$Region" | tail -n 3
echo ""
echo "Återskapa med: ./deploy.sh && ./install-wordpress.sh && ./restore-wordpress.sh"
