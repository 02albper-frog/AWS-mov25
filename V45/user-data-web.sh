#!/bin/bash
# User data för webbservern (V45): installerar Apache, PHP och WordPress, monterar EFS på
# wp-content, skriver wp-config.php och schemalägger en nattlig databasbackup till S3.
# Databasanvändaren och själva WordPress-installationen görs av install-wordpress.sh.
# Platshållarna fylls i av provision.sh. Logg: /var/log/cloud-init-output.log

BUCKET=__BUCKET__
BACKUP_BUCKET=__BACKUP_BUCKET__
EFS_ID=__EFS_ID__
DB_HOST=__DB_HOST__
DB_NAME=__DB_NAME__
DB_USER=__DB_USER__
SSM_DB_WP=__SSM_DB_WP__
export AWS_DEFAULT_REGION=__REGION__
export HOME=/root
WEBROOT=/var/www/html

# ---- 1. Programvara ----
dnf update -y
dnf install -y httpd mod_ssl php php-fpm php-mysqli php-json mariadb105 amazon-efs-utils cronie
dnf install -y php-gd php-mbstring php-xml php-intl || true

# ---- 2. HTTPS-certifikat (självsignerat) och tjänster ----
if [ ! -f /etc/pki/tls/certs/localhost.crt ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 -subj "/CN=novatrix-web" \
    -keyout /etc/pki/tls/private/localhost.key -out /etc/pki/tls/certs/localhost.crt
fi
systemctl enable --now php-fpm httpd crond

# RDS certifikatkedja, så att trafiken till databasen kan krypteras och verifieras (TLS)
RDS_CA=/etc/pki/tls/certs/rds-global-bundle.pem
curl -fsSL -o "$RDS_CA" https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
cp "$RDS_CA" /etc/pki/ca-trust/source/anchors/rds-global-bundle.pem
update-ca-trust

# ---- 3. WP-CLI och WordPress på svenska ----
curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x /usr/local/bin/wp
WP="/usr/local/bin/wp --allow-root --path=$WEBROOT"
$WP core download --locale=sv_SE

# ---- 4. Montera EFS på wp-content, med krypterad trafik (TLS) ----
mv "$WEBROOT/wp-content" /tmp/wp-content-original
mkdir -p "$WEBROOT/wp-content"
echo "$EFS_ID:/ $WEBROOT/wp-content efs _netdev,tls 0 0" >> /etc/fstab
for i in $(seq 1 12); do
  mount "$WEBROOT/wp-content" && break
  echo "EFS-montering, försök $i misslyckades, väntar 10 sekunder ..."
  sleep 10
done
# Den första servern som monterar EFS fyller den med WordPress standardinnehåll
if [ -z "$(ls -A "$WEBROOT/wp-content")" ]; then
  cp -a /tmp/wp-content-original/. "$WEBROOT/wp-content/"
fi
mkdir -p "$WEBROOT/wp-content/uploads"

# ---- 5. wp-config.php med WordPress-användarens lösenord från SSM ----
DB_PASS=$(aws ssm get-parameter --name "$SSM_DB_WP" --with-decryption \
  --query Parameter.Value --output text)
$WP config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" \
  --dbhost="$DB_HOST" --locale=sv_SE --skip-check
$WP config set FS_METHOD direct
$WP config set DISALLOW_FILE_EDIT true --raw
$WP config set MYSQL_CLIENT_FLAGS MYSQLI_CLIENT_SSL --raw   # krypterad trafik till RDS
unset DB_PASS

# Hjälpfil för verifiering: visar vilken TLS-chiffer WordPress anslutning till databasen använder
mkdir -p /usr/local/share/novatrix
cat > /usr/local/share/novatrix/db-tls.php <<'PHP'
<?php
global $wpdb;
$row = $wpdb->get_row("SHOW SESSION STATUS LIKE 'Ssl_cipher'");
echo ($row && $row->Value !== '') ? $row->Value : 'ingen';
PHP

chown -R apache:apache "$WEBROOT"
chmod 640 "$WEBROOT/wp-config.php"

# ---- 6. Statisk sida från S3 (rollen tillåter s3:GetObject på web/*) ----
aws s3 cp "s3://$BUCKET/web/index.html" "$WEBROOT/novatrix.html" || true

# ---- 7. Nattlig databasbackup till S3 ----
cat > /etc/novatrix-backup.conf <<CONF
DB_HOST=$DB_HOST
DB_NAME=$DB_NAME
DB_USER=$DB_USER
SSM_DB_WP=$SSM_DB_WP
BACKUP_BUCKET=$BACKUP_BUCKET
RDS_CA=$RDS_CA
export AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
CONF
chmod 600 /etc/novatrix-backup.conf

cat > /usr/local/bin/novatrix-backup.sh <<'BACKUP'
#!/bin/bash
# Dumpar WordPress-databasen och laddar upp den till backup-bucketen.
# Rollen tillåter bara s3:PutObject på db/*, så servern kan varken läsa eller radera backuper.
set -euo pipefail
source /etc/novatrix-backup.conf
STAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
TARGET="s3://$BACKUP_BUCKET/db/$DB_NAME-$STAMP.sql.gz"
MYSQL_PWD=$(aws ssm get-parameter --name "$SSM_DB_WP" --with-decryption \
  --query Parameter.Value --output text)
export MYSQL_PWD
DUMP=$(command -v mariadb-dump || command -v mysqldump)
"$DUMP" --ssl-ca="$RDS_CA" --ssl-verify-server-cert \
  -h "$DB_HOST" -u "$DB_USER" --single-transaction --no-tablespaces "$DB_NAME" \
  | gzip | aws s3 cp - "$TARGET"
echo "$(date -u '+%F %T') Backup klar: $TARGET"
BACKUP
chmod 750 /usr/local/bin/novatrix-backup.sh
echo "0 3 * * * root /usr/local/bin/novatrix-backup.sh >> /var/log/novatrix-backup.log 2>&1" \
  > /etc/cron.d/novatrix-backup

# ---- 8. Installationsloggen till S3 (rollen tillåter s3:PutObject på logs/*) ----
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d' ' -f2)
aws s3 cp /var/log/cloud-init-output.log "s3://$BUCKET/logs/$INSTANCE_ID-cloud-init.log"
