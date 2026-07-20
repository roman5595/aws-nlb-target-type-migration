#!/usr/bin/env sh

set -u

# When preserve_client_ip.enabled=true, do not run this probe from a Pod that
# is itself registered as a target of the NLB under test. NLB NAT loopback is
# not supported in that configuration. Use a different client Pod or host.

if [ "$#" -lt 3 ]; then
  echo "usage: $0 URL HOST_HEADER EXPECTED_STATUS [DURATION_SECONDS] [INTERVAL_SECONDS]" >&2
  exit 2
fi

url=$1
host_header=$2
expected_status=$3
duration_seconds=${4:-180}
interval_seconds=${5:-0.1}

start_epoch=$(date +%s)
end_epoch=$((start_epoch + duration_seconds))
sequence=0

echo "sequence,wall_epoch,wall_utc,monotonic_uptime,curl_rc,http_status,result,remote_ip,time_namelookup,time_connect,time_appconnect,time_starttransfer,time_total"

while [ "$(date +%s)" -lt "$end_epoch" ]; do
  sequence=$((sequence + 1))
  wall_epoch=$(date +%s)
  wall_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  monotonic_uptime=$(cut -d ' ' -f 1 /proc/uptime)

  measurement=$(curl \
    --insecure \
    --silent \
    --show-error \
    --http1.1 \
    --no-keepalive \
    --connect-timeout 1 \
    --max-time 2 \
    --output /dev/null \
    --header "Connection: close" \
    --header "Host: ${host_header}" \
    --write-out '%{http_code},%{remote_ip},%{time_namelookup},%{time_connect},%{time_appconnect},%{time_starttransfer},%{time_total}' \
    "$url" 2>/dev/null)
  curl_rc=$?

  http_status=${measurement%%,*}
  if [ "$curl_rc" -eq 0 ] && [ "$http_status" = "$expected_status" ]; then
    result=success
  else
    result=failure
  fi

  echo "${sequence},${wall_epoch},${wall_utc},${monotonic_uptime},${curl_rc},${measurement%%,*},${result},${measurement#*,}"
  sleep "$interval_seconds"
done
