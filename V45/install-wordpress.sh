#!/bin/bash
# V45: Skapar WordPress-databasanvändaren och installerar WordPress.
# Körs från administratörens dator. Kommandona körs på webbservern via bastion.
# Huvudlösenordet till databasen skickas krypterat över SSH och sparas aldrig på webbservern.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
source ./config.sh

WEB_IP=$(instance_field "$TAG_NAME" PublicIpAddress)
[ "$WEB_IP" != "None" ] || { echo "Webbservern körs inte. Kör ./provision.sh först."; exit 1; }
DB_HOST=$(db_field Endpoint.Address)

ssm_value() {
  aws ssm get-parameter --region "$REGION" --name "$1" --with-decryption \
    --query Parameter.Value --output text
}
MASTER_PW=$(ssm_value "$SSM_DB_MASTER")
WP_DB_PW=$(ssm_value "$SSM_DB_WP")
WP_ADMIN_PW=$(ssm_value "$SSM_WP_ADMIN")

# WordPress-användaren får bara ansluta från webbsubnätet, t.ex. 10.0.1.%
WEB_HOST_PATTERN="${WEB_CIDR_A%.*}.%"

echo "Väntar på att webbservern ska bli klar med installationen (kan ta några minuter) ..."

on_web "sudo bash -s" <<EOF_REMOTE
set -euo pipefail
export HOME=/root
cloud-init status --wait > /dev/null || true
WP="/usr/local/bin/wp --allow-root --path=/var/www/html"

echo ""
echo "== 1. Databasanvändare för WordPress =="
MYSQL_PWD='$MASTER_PW' mysql --ssl-ca=/etc/pki/tls/certs/rds-global-bundle.pem --ssl-verify-server-cert \
  -h '$DB_HOST' -u '$DB_MASTER_USER' <<SQL
CREATE USER IF NOT EXISTS '$DB_WP_USER'@'$WEB_HOST_PATTERN' IDENTIFIED BY '$WP_DB_PW';
ALTER USER '$DB_WP_USER'@'$WEB_HOST_PATTERN' IDENTIFIED BY '$WP_DB_PW';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_WP_USER'@'$WEB_HOST_PATTERN';
FLUSH PRIVILEGES;
SQL
echo "Användaren $DB_WP_USER@$WEB_HOST_PATTERN har rättigheter endast till databasen $DB_NAME"

echo ""
echo "== 2. WordPress =="
if \$WP core is-installed 2> /dev/null; then
  echo "WordPress är redan installerat"
else
  \$WP core install --url='http://$WEB_IP' --title='$WP_TITLE' \
    --admin_user='$WP_ADMIN_USER' --admin_password='$WP_ADMIN_PW' \
    --admin_email='$WP_ADMIN_EMAIL' --skip-email
  \$WP option update blogdescription 'Molnlösningar byggda på AWS'
  \$WP post create --post_type=page --post_status=publish --post_name=om-novatrix \
    --post_title='Om Novatrix' \
    --post_content='Novatrix hjälper företag att bygga smarta digitala lösningar. Webbplatsen körs på Amazon EC2, databasen i Amazon RDS och filerna i Amazon EFS.'
  echo "WordPress installerat med sidan Om Novatrix"
fi

echo ""
echo "== 3. Första databasbackupen till S3 =="
/usr/local/bin/novatrix-backup.sh
EOF_REMOTE

echo ""
echo "Klart! WordPress är installerat."
echo ""
echo "Webbplats:  http://$WEB_IP"
echo "Admin:      http://$WEB_IP/wp-admin  (användare: $WP_ADMIN_USER)"
echo "Lösenord:   aws ssm get-parameter --region $REGION --name $SSM_WP_ADMIN --with-decryption --query Parameter.Value --output text"
echo ""
echo "Logga in, ladda upp en bild under Media och kör sedan ./verify-wordpress.sh."
