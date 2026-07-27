#!/usr/bin/env sh

set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 AWS_REGION START_TIME_UTC END_TIME_UTC" >&2
  echo "example: $0 us-east-1 2026-07-27T08:30:00Z 2026-07-27T09:15:00Z" >&2
  exit 2
fi

region=$1
start_time=$2
end_time=$3

aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventSource,AttributeValue=elasticloadbalancing.amazonaws.com \
  --start-time "$start_time" \
  --end-time "$end_time" \
  --region "$region" \
  --query 'sort_by(Events[?EventName==`CreateTargetGroup` || EventName==`ModifyTargetGroupAttributes` || EventName==`ModifyListener` || EventName==`RegisterTargets` || EventName==`DeregisterTargets` || EventName==`DeleteTargetGroup`], &EventTime)[].[EventTime,EventName,EventId,Resources]' \
  --output json
