#!/bin/bash
# V48: Belastar webbservrarnas CPU och visar hur Auto Scaling-gruppen skalar ut och in.
#
# Användning: ./load-test.sh start [minuter] [miljö]   belasta alla servrar och följ gruppen
#             ./load-test.sh watch [miljö]             följ gruppen (avsluta med Ctrl+C)
#             ./load-test.sh stop [miljö]              stoppa belastningen
#
# Belastningen är processer som håller alla processorkärnor på 100 %. Gruppen skalar ut
# när snittet ligger över målvärdet (CpuTargetPercent) i några minuter, och skalar in
# igen ungefär 15 minuter efter att belastningen har upphört.
set -uo pipefail
cd "$(dirname "$0")"
ACTION="${1:-watch}"
MINUTES=15
if [ "$ACTION" = "start" ] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then MINUTES="$2"; shift; fi
source ./lib.sh "${2:-prod}"
ASG="$EnvName-web-asg"

cpu_now() {
  aws cloudwatch get-metric-statistics --region "$Region" --namespace AWS/EC2 \
    --metric-name CPUUtilization --dimensions "Name=AutoScalingGroupName,Value=$ASG" \
    --start-time "$(date -u -d '-6 min' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 60 --statistics Average --query 'sort_by(Datapoints,&Timestamp)[-1].Average' --output text
}

watch_group() {
  echo "Tid       CPU snitt  Önskat  I drift  Mål: $CpuTargetPercent % CPU, $AsgMinSize-$AsgMaxSize servrar"
  while true; do
    read -r DESIRED INSERVICE < <(aws autoscaling describe-auto-scaling-groups --region "$Region" \
      --auto-scaling-group-names "$ASG" \
      --query "AutoScalingGroups[0].[DesiredCapacity,length(Instances[?LifecycleState=='InService'])]" \
      --output text)
    CPU=$(cpu_now)
    [ "$CPU" = "None" ] && CPU="-" || CPU=$(printf "%.0f %%" "$CPU")
    printf "%s  %-9s  %-6s  %s\n" "$(date +%H:%M:%S)" "$CPU" "$DESIRED" "$INSERVICE"
    sleep 30
  done
}

case "$ACTION" in
  start)
    echo "Belastar alla webbservrar i $MINUTES minuter:"
    while read -r ID IP _; do
      on_host "$IP" "sudo nohup timeout ${MINUTES}m bash -c 'for i in \$(seq \$(nproc)); do yes > /dev/null & done; wait' > /dev/null 2>&1 &" < /dev/null
      echo "  $ID ($IP)"
    done < <(web_instances)
    echo ""
    echo "Servrar som startas av skalningen belastas inte, så snittet sjunker när gruppen växer."
    echo "Avsluta uppföljningen med Ctrl+C. Belastningen upphör av sig själv efter $MINUTES minuter."
    echo ""
    watch_group
    ;;
  watch)
    watch_group
    ;;
  stop)
    while read -r ID IP _; do
      on_host "$IP" "sudo pkill -x yes; sudo pkill -f 'timeout .*yes'" < /dev/null > /dev/null 2>&1
      echo "Stoppade belastningen på $ID"
    done < <(web_instances)
    ;;
  *)
    echo "Användning: ./load-test.sh start [minuter] | watch | stop"
    exit 1
    ;;
esac

echo ""
echo "Senaste skalningshändelser:"
aws autoscaling describe-scaling-activities --region "$Region" --auto-scaling-group-name "$ASG" \
  --max-items 5 --query 'Activities[].[StartTime,Description]' --output text 2> /dev/null | cut -c1-120