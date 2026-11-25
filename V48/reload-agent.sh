#!/bin/bash
# V48: Läser in agentens konfiguration från Parameter Store på nytt på alla webbservrar.
# Behövs efter en ändring i CloudWatchAgentConfig (05-app.yaml), eftersom servrarna bara
# hämtar konfigurationen när de startar. Alternativet är en instance refresh av gruppen,
# som byter ut alla servrar mot nya.
# Användning: ./reload-agent.sh [miljö]
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh "${1:-prod}"

while read -r ID IP _; do
  if on_host "$IP" "sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
       -a fetch-config -m ec2 -s -c ssm:AmazonCloudWatch-$EnvName > /dev/null && \
       systemctl is-active amazon-cloudwatch-agent" < /dev/null; then
    echo "  $ID: ny konfiguration inläst"
  else
    echo "  $ID: misslyckades"
  fi
done < <(web_instances)
