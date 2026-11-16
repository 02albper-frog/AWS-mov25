#!/bin/bash
# V46: Skapar WordPress egen databasanvändare och installerar WordPress.
# Körs från administratörens dator; kommandona körs på webbservern via bastion.
# Huvudlösenordet skickas krypterat över SSH och sparas aldrig på webbservern.
# Användning: ./install-wordpress.sh [miljö]
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh "${1:-prod}"

WEB_IP=$(stack_output app WebPublicIp)
[ -n "$WEB_IP" ] && [ "$WEB_IP" != "None" ] || { echo "Stacken $(stack_name app) saknas. Kör ./deploy.sh först."; exit 1; }
DB_HOST=$(stack_output data DbEndpoint)
DB_NAME=$(stack_output data DbName)

MASTER_USER=$(secret_field "$EnvName/db/master" username)
MASTER_PW=$(secret_field "$EnvName/db/master" password)
WP_DB_USER=$(secret_field "$EnvName/db/wordpress" username)
WP_DB_PW=$(secret_field "$EnvName/db/wordpress" password)
WP_ADMIN_USER=$(secret_field "$EnvName/wp/admin" username)
WP_ADMIN_PW=$(secret_field "$EnvName/wp/admin" password)

# WordPress-användaren får bara ansluta från webbsubnätet, t.ex. 10.0.1.%
WEB_HOST_PATTERN="${PublicCidr%.*}.%"

on_web "sudo bash -s" <<EOF_REMOTE
set -euo pipefail
export HOME=/root
WP="/usr/local/bin/wp --allow-root --path=/var/www/html"

echo "== 1. Databasanvändare för WordPress =="
MYSQL_PWD='$MASTER_PW' mysql --ssl-ca=/etc/pki/tls/certs/rds-global-bundle.pem --ssl-verify-server-cert \
  -h '$DB_HOST' -u '$MASTER_USER' <<SQL
CREATE USER IF NOT EXISTS '$WP_DB_USER'@'$WEB_HOST_PATTERN' IDENTIFIED BY '$WP_DB_PW';
ALTER USER '$WP_DB_USER'@'$WEB_HOST_PATTERN' IDENTIFIED BY '$WP_DB_PW';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$WP_DB_USER'@'$WEB_HOST_PATTERN';
FLUSH PRIVILEGES;
SQL
echo "Användaren $WP_DB_USER@$WEB_HOST_PATTERN har rättigheter endast till databasen $DB_NAME"

echo ""
echo "== 2. WordPress =="
if \$WP core is-installed 2> /dev/null; then
  echo "WordPress är redan installerat"
else
  \$WP core install --url='http://$WEB_IP' --title='Novatrix AB' \
    --admin_user='$WP_ADMIN_USER' --admin_password='$WP_ADMIN_PW' \
    --admin_email='admin@novatrix.example' --skip-email
  \$WP option update blogdescription 'Molnlösningar byggda på AWS'
  \$WP post delete 1 2 --force > /dev/null 2>&1 || true
  PAGE=\$(\$WP post create --post_type=page --post_status=publish --post_name=om-novatrix \
    --post_title='Om Novatrix' --porcelain \
    --post_content='Novatrix hjälper företag att bygga smarta digitala lösningar. Hela miljön byggs med AWS CloudFormation: webbservern på Amazon EC2, databasen i Amazon RDS och filerna i Amazon EFS.')
  \$WP option update show_on_front page
  \$WP option update page_on_front "\$PAGE"
  echo "WordPress installerat med startsidan Om Novatrix"
fi
EOF_REMOTE

echo ""
echo "Klart!"
echo "Webbplats:  http://$WEB_IP"
echo "Admin:      http://$WEB_IP/wp-admin  (användare: $WP_ADMIN_USER)"
echo "Lösenord:   ./show-password.sh"
