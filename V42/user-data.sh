#!/bin/bash
# User data: installerar Apache och hämtar Novatrix webbsida från GitHub.
# Körs som root vid instansens första uppstart.
# Logg: /var/log/cloud-init-output.log

dnf update -y
dnf install -y httpd
systemctl enable --now httpd

curl -fsSL -o /var/www/html/index.html \
  https://raw.githubusercontent.com/02albper-frog/AWS-mov25/main/V42/index.html