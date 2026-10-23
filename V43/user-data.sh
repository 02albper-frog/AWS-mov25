#!/bin/bash
# User data för V43: installerar Apache och hämtar webbsidan från S3 med instansens IAM-roll.
# Platshållarna för bucket och region fylls i av provision.sh innan instansen startas.
# Logg: /var/log/cloud-init-output.log

BUCKET=__BUCKET__
export AWS_DEFAULT_REGION=__REGION__

dnf update -y
dnf install -y httpd
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