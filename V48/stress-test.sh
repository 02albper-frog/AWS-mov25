#!/bin/bash
# V48: Testar larmen och larmkedjan (larm -> SNS -> e-post).
#
# Användning: ./stress-test.sh larmtest [larm] [miljö]    sätter ett larm i ALARM för att testa
#                                                         kedjan, t.ex. larmtest cpu-hog (standard)
#             ./stress-test.sh minne [minuter] [miljö]   fyller minnet tills ca 8 % är tillgängligt
#             ./stress-test.sh disk [minuter] [miljö]    fyller disken / på en server (ca 90 %)
#             ./stress-test.sh unhealthy [minuter] [miljö]  en server svarar 404 på hälsokontrollen
#             ./stress-test.sh stopp [miljö]             avbryter alla tester och återställer
#             ./stress-test.sh status [miljö]            visar alla larm och deras läge
#             ./stress-test.sh watch [miljö]             följer larmen (avsluta med Ctrl+C)
#
# CPU testas med ./load-test.sh start från v47.
# Testerna slutar av sig själva efter angivet antal minuter (standard 12), utom att
# unhealthy-testet pausar gruppens hälsokontroll, som bara slås på igen med "stopp".
set -uo pipefail
cd "$(dirname "$0")"
ACTION="${1:-status}"
shift || true
ARG=""
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  ARG="$1"; shift
elif [ "$ACTION" = "larmtest" ] && [ -n "${1:-}" ] && [ ! -f "parameters/${1}.env" ]; then
  ARG="$1"; shift
fi
source ./lib.sh "${1:-prod}"
ASG="$EnvName-web-asg"
MINUTES="${ARG:-12}"
ALARMS=("$EnvName-cpu-hog" "$EnvName-minne" "$EnvName-disk" "$EnvName-unhealthy" "$EnvName-5xx" \
        "$EnvName-db-cpu" "$EnvName-db-lagring" "$EnvName-sajtkoll")

first_web() {
  read -r ID IP _ < <(web_instances | head -n 1)
  [ -n "${IP:-}" ] || { echo "Inga webbservrar i drift"; exit 1; }
}

show_alarms() {
  aws cloudwatch describe-alarms --region "$Region" --alarm-names "${ALARMS[@]}" \
    --query 'MetricAlarms[].[AlarmName,StateValue,StateUpdatedTimestamp]' --output text \
    | awk '{printf "  %-24s %-18s %s\n", $1, $2, substr($3, 12, 8)}'
}

case "$ACTION" in
  larmtest)
    NAME="$EnvName-${ARG:-cpu-hog}"
    aws cloudwatch set-alarm-state --region "$Region" --alarm-name "$NAME" \
      --state-value ALARM --state-reason "Test av larmkedjan" || exit 1
    echo "$NAME är satt till ALARM. Ett mail med ämnet \"ALARM: ...\" kommer inom någon minut."
    echo "Vid nästa utvärdering går larmet tillbaka till OK, och då kommer ett mail till."
    ;;

  minne)
    first_web
    echo "Fyller minnet på $ID ($IP) i $MINUTES minuter ..."
    on_host "$IP" "sudo bash -s" <<SKRIPT
# Fyller minnet 16 MB i taget tills bara 8 % är tillgängligt (MemAvailable), och håller det.
# Larmet novatrix-minne går när mem_available_percent är under 10 %.
setsid nohup timeout ${MINUTES}m python3 -c '
import time
def available_percent():
    m = {k: int(v.split()[0]) for k, v in (l.split(":", 1) for l in open("/proc/meminfo"))}
    return m["MemAvailable"] * 100 / m["MemTotal"]
chunks = []
while available_percent() > 8 and len(chunks) < 400:
    chunks.append(b"\x01" * 16 * 1024 * 1024)
time.sleep(100000)
' < /dev/null > /dev/null 2>&1 &
sleep 20
free -m | awk 'NR==2{printf "Tillgängligt minne: %d av %d MB (%.0f %%)\n", \$7, \$2, \$7*100/\$2}'
SKRIPT
    echo "Larmet $EnvName-minne går när tillgängligt minne har legat under 10 % i en 5-minutersperiod (5-10 min)."
    ;;

  disk)
    first_web
    echo "Fyller disken / på $ID ($IP) i $MINUTES minuter ..."
    on_host "$IP" "sudo bash -s" <<SKRIPT
read -r SIZE USED < <(df -B1 --output=size,used / | tail -n 1)
NEED=\$(( SIZE * 90 / 100 - USED ))
if [ "\$NEED" -gt 0 ]; then fallocate -l "\$NEED" /var/tmp/novatrix-disktest; fi
setsid nohup bash -c "sleep ${MINUTES}m; rm -f /var/tmp/novatrix-disktest" < /dev/null > /dev/null 2>&1 &
df -h / | tail -n 1 | awk '{print "Disk /: " \$3 " av " \$2 " använt (" \$5 ")"}'
SKRIPT
    echo "Larmet $EnvName-disk går inom 5-10 minuter. Filen tas bort automatiskt efter $MINUTES minuter."
    ;;

  unhealthy)
    first_web
    # Gruppens hälsokontroll pausas, annars byter Auto Scaling ut servern inom någon minut
    # och larmet hinner inte se tre sjuka minuter i rad.
    aws autoscaling suspend-processes --region "$Region" --auto-scaling-group-name "$ASG" \
      --scaling-processes HealthCheck ReplaceUnhealthy
    on_host "$IP" "sudo mv /var/www/html/health.html /var/www/html/health.html.av && echo 'Hälsokontrollsidan är borttagen'"
    on_host "$IP" "sudo setsid nohup bash -c 'sleep ${MINUTES}m; mv -n /var/www/html/health.html.av /var/www/html/health.html' < /dev/null > /dev/null 2>&1 &"
    echo "$ID ($IP) svarar nu 404 på /health.html. Lastbalanseraren skickar all trafik till"
    echo "de andra servrarna, och $EnvName-unhealthy går efter cirka 4 minuter."
    echo "Sidan återställs efter $MINUTES minuter. Kör ./stress-test.sh stopp efteråt, så att"
    echo "gruppens hälsokontroll slås på igen."
    ;;

  stopp)
    while read -r ID IP _; do
      on_host "$IP" "sudo pkill -f 'time.sleep.100000'; sudo rm -f /var/tmp/novatrix-disktest; \
        [ -f /var/www/html/health.html.av ] && sudo mv -n /var/www/html/health.html.av /var/www/html/health.html; true" \
        < /dev/null > /dev/null 2>&1
      echo "Återställde $ID"
    done < <(web_instances)
    aws autoscaling resume-processes --region "$Region" --auto-scaling-group-name "$ASG" \
      --scaling-processes HealthCheck ReplaceUnhealthy
    echo "Gruppens hälsokontroll är på igen. Larmen går tillbaka till OK inom 5-10 minuter."
    ;;

  status)
    show_alarms
    ;;

  watch)
    while true; do
      echo "== $(date +%H:%M:%S) =="
      show_alarms
      sleep 30
    done
    ;;

  *)
    echo "Användning: ./stress-test.sh larmtest [larm] | minne [min] | disk [min] | unhealthy [min] | stopp | status | watch"
    exit 1
    ;;
esac
