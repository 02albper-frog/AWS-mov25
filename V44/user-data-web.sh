#!/bin/bash
# User data för webbservern (V44): installerar Apache med HTTP och HTTPS och hämtar
# webbsidan från S3 med instansens IAM-roll. Platshållarna fylls i av provision.sh.
# Logg: /var/log/cloud-init-output.log

BUCKET=__BUCKET__
export AWS_DEFAULT_REGION=__REGION__

dnf update -y
dnf install -y httpd mod_ssl

# Självsignerat certifikat för HTTPS, om paketet inte redan skapat ett
if [ ! -f /etc/pki/tls/certs/localhost.crt ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 -subj "/CN=novatrix-web" \
    -keyout /etc/pki/tls/private/localhost.key -out /etc/pki/tls/certs/localhost.crt
fi

systemctl enable --now httpd

# Läs webbsidan från S3 (rollen tillåter s3:GetObject på web/*)
for i in 1 2 3 4 5; do
  aws s3 cp "s3://$BUCKET/web/index.html" /var/www/html/index.html && break
  echo "Försök $i misslyckades, väntar 5 sekunder ..."
  sleep 5
done

# Skriv installationsloggen till S3 (rollen tillåter s3:PutObject på logs/*)
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d' ' -f2)
aws s3 cp /var/log/cloud-init-output.log "s3://$BUCKET/logs/$INSTANCE_ID-cloud-init.log"