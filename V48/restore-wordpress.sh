#!/bin/bash
# V48: Återställer WordPress från backup-bucketen: databasen från db/ och
# uppladdade filer från uploads/. Databasen och EFS delas av alla webbservrar, så
# återställningen görs en gång och gäller hela gruppen. Kör efter ./deploy.sh och ./install-wordpress.sh.
#
# Webbservern har aldrig behörighet att läsa backuperna. I stället skapar det här
# skriptet, med administratörens behörighet, tillfälliga nedladdningslänkar som
# gäller i 10 minuter, och webbservern hämtar filerna via dem.
#
# Användning: ./restore-wordpress.sh [miljö] [tidsstämpel]
#   tidsstämpel, t.ex. 2026-11-16T120000Z, väljer en viss backup. Standard: den senaste.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh "${1:-prod}"
STAMP="${2:-}"

WEB_URL=$(stack_output app WebUrl)
[ -n "$WEB_URL" ] && [ "$WEB_URL" != "None" ] || { echo "Stacken $(stack_name app) saknas. Kör ./deploy.sh först."; exit 1; }

latest() {  # <prefix>
  aws s3 ls "s3://$BackupBucketName/$1/" --region "$Region" | awk '{print $4}' \
    | grep -F "${STAMP}" | sort | tail -n 1
}
DB_FILE=$(latest db)
UP_FILE=$(latest uploads)
[ -n "$DB_FILE" ] || { echo "Hittar ingen databasbackup i s3://$BackupBucketName/db/"; exit 1; }

echo "== Återställer från backup =="
echo "Databas: db/$DB_FILE"
echo "Filer:   ${UP_FILE:+uploads/}${UP_FILE:-(ingen filbackup hittades)}"

DB_URL=$(aws s3 presign "s3://$BackupBucketName/db/$DB_FILE" --region "$Region" --expires-in 600)
UP_URL=""
[ -n "$UP_FILE" ] && UP_URL=$(aws s3 presign "s3://$BackupBucketName/uploads/$UP_FILE" --region "$Region" --expires-in 600)
NEW_URL="$WEB_URL"
# Den återställda databasen har kvar administratörens lösenord från den gamla miljön.
# Det sätts om till lösenordet i den nya miljöns hemlighet.
WP_ADMIN_USER=$(secret_field "$EnvName/wp/admin" username)
WP_ADMIN_PW=$(secret_field "$EnvName/wp/admin" password)

on_web "sudo bash -s" <<EOF_REMOTE
set -euo pipefail
export HOME=/root
source /etc/novatrix-backup.conf
WP="/usr/local/bin/wp --allow-root --path=/var/www/html"
SECRET=\$(aws secretsmanager get-secret-value --secret-id "\$WP_SECRET" --query SecretString --output text)
DB_USER=\$(echo "\$SECRET" | jq -r .username)
export MYSQL_PWD=\$(echo "\$SECRET" | jq -r .password)

echo ""
echo "== 1. Databasen =="
curl -fsSL '$DB_URL' | gunzip \
  | mysql --ssl-ca="\$RDS_CA" --ssl-verify-server-cert -h "\$DB_HOST" -u "\$DB_USER" "\$DB_NAME"
echo "Databasen är återställd"

echo ""
echo "== 2. Uppladdade filer =="
if [ -n '$UP_URL' ]; then
  curl -fsSL '$UP_URL' | tar -xzf - -C /var/www/html/wp-content
  chown -R apache:apache /var/www/html/wp-content
  echo "\$(find /var/www/html/wp-content/uploads -type f | wc -l) filer är återställda"
else
  echo "Ingen filbackup, hoppar över"
fi

echo ""
echo "== 3. Ny adress =="
OLD_URL=\$(\$WP option get siteurl)
if [ "\$OLD_URL" != '$NEW_URL' ]; then
  \$WP search-replace "\$OLD_URL" '$NEW_URL' --all-tables --skip-columns=guid --report-changed-only
  echo "Bytte adress från \$OLD_URL till $NEW_URL"
else
  echo "Adressen är oförändrad"
fi

echo ""
echo "== 4. Administratörens lösenord =="
if \$WP user get '$WP_ADMIN_USER' > /dev/null 2>&1; then
  \$WP user update '$WP_ADMIN_USER' --user_pass='$WP_ADMIN_PW' --skip-email > /dev/null
  echo "Lösenordet för $WP_ADMIN_USER är satt till den nya miljöns hemlighet"
fi
\$WP cache flush > /dev/null 2>&1 || true
EOF_REMOTE

echo ""
echo "Klart! Öppna $NEW_URL"
