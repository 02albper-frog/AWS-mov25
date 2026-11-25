#!/bin/bash
# V48: Visar att webbplatsen förblir tillgänglig när en webbserver faller bort.
# Skriptet frågar webbplatsen varannan sekund och visar vilken server som svarar.
# Efter 20 sekunder tas en server bort, och skriptet följer hur gruppen ersätter den.
#
# Användning: ./test-availability.sh [krasch|avsluta] [minuter] [miljö]
#   krasch   stoppar Apache på en server: ett oplanerat fel som lastbalanserarens
#            hälsokontroll måste upptäcka (standard)
#   avsluta  tar bort en server via Auto Scaling: ett planerat byte där servern först
#            tas ur trafiken
#   minuter  hur länge testet pågår (standard 10)
set -uo pipefail
cd "$(dirname "$0")"
MODE="${1:-krasch}"
MINUTES="${2:-10}"
source ./lib.sh "${3:-prod}"

WEB_URL=$(stack_output app WebUrl)
ASG="$EnvName-web-asg"
TARGET=$(web_instances | head -n 1)
TARGET_ID=$(echo "$TARGET" | awk '{print $1}')
TARGET_IP=$(echo "$TARGET" | awk '{print $2}')
[ -n "$TARGET_ID" ] || { echo "Inga webbservrar i drift"; exit 1; }

group_status() {
  aws autoscaling describe-auto-scaling-groups --region "$Region" --auto-scaling-group-names "$ASG" \
    --query "AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]" \
    --output text | sort | awk '{printf "           %-21s %-12s %-12s %s\n", $1, $2, $3, $4}'
}

echo "Webbplats: $WEB_URL"
echo "Test:      $MODE av $TARGET_ID om 20 sekunder, totalt $MINUTES minuter"
echo ""
echo "Gruppen före testet:"
group_status
echo ""
echo "Tid       Svar  Server"

TOTAL=0
OK=0
END=$(( $(date +%s) + MINUTES * 60 ))
START=$(date +%s)
DONE_FAILURE=false
LAST_STATUS=$START
while [ "$(date +%s)" -lt "$END" ]; do
  RESP=$(curl -s -o /dev/null -D - -m 5 -w 'HTTPCODE:%{http_code}' "$WEB_URL/" 2> /dev/null)
  CODE=$(echo "$RESP" | sed -n 's/.*HTTPCODE:\([0-9]*\).*/\1/p')
  SERVER=$(echo "$RESP" | grep -i '^x-novatrix-instance' | awk '{print $2}' | tr -d '\r')
  TOTAL=$((TOTAL + 1))
  [ "$CODE" = "200" ] && OK=$((OK + 1))
  printf "%s  %-4s  %s\n" "$(date +%H:%M:%S)" "${CODE:-000}" "${SERVER:--}"

  if [ "$DONE_FAILURE" = false ] && [ $(( $(date +%s) - START )) -ge 20 ]; then
    DONE_FAILURE=true
    echo ""
    if [ "$MODE" = "avsluta" ]; then
      echo ">>> Tar bort $TARGET_ID via Auto Scaling (gruppen startar en ersättare)"
      aws autoscaling terminate-instance-in-auto-scaling-group --region "$Region" \
        --instance-id "$TARGET_ID" --no-should-decrement-desired-capacity > /dev/null
    else
      echo ">>> Stoppar Apache på $TARGET_ID (simulerat fel)"
      on_host "$TARGET_IP" "sudo systemctl stop httpd" > /dev/null 2>&1
    fi
    echo ""
  fi

  if [ $(( $(date +%s) - LAST_STATUS )) -ge 60 ]; then
    LAST_STATUS=$(date +%s)
    echo "--- $(date +%H:%M:%S) Gruppen:"
    group_status
  fi
  sleep 2
done

echo ""
echo "Gruppen efter testet:"
group_status
echo ""
echo "Resultat: $OK av $TOTAL förfrågningar fick svar 200 ($(( OK * 100 / TOTAL )) %)"
