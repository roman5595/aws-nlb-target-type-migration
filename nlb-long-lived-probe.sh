#!/usr/bin/env sh

set -u

if [ "$#" -lt 5 ]; then
  echo "usage: $0 CONNECTION_ID CONNECT_IP SNI_HOST DURATION_SECONDS INTERVAL_SECONDS" >&2
  exit 2
fi

connection_id=$1
connect_ip=$2
sni_host=$3
duration_seconds=$4
interval_seconds=$5
start_epoch=$(date +%s)
end_epoch=$((start_epoch + duration_seconds))

emit_requests() {
  sequence=0

  while [ "$(date +%s)" -lt "$end_epoch" ]; do
    sequence=$((sequence + 1))
    wall_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    monotonic_uptime=$(cut -d ' ' -f 1 /proc/uptime)

    echo "SEND connection=${connection_id} sequence=${sequence} utc=${wall_utc} uptime=${monotonic_uptime}" >&2
    printf 'GET /long-lived/%s/%s HTTP/1.1\r\nHost: %s\r\nConnection: keep-alive\r\nUser-Agent: nlb-long-lived-probe/%s\r\n\r\n' \
      "$connection_id" "$sequence" "$sni_host" "$connection_id"
    sleep "$interval_seconds"
  done
}

echo "OPEN connection=${connection_id} connect=${connect_ip}:443 sni=${sni_host} utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) uptime=$(cut -d ' ' -f 1 /proc/uptime)"

emit_requests |
  openssl s_client \
    -connect "${connect_ip}:443" \
    -servername "$sni_host" \
    -quiet 2>&1 |
  while IFS= read -r line; do
    case "$line" in
      HTTP/*)
        echo "RESPONSE connection=${connection_id} utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) uptime=$(cut -d ' ' -f 1 /proc/uptime) status=${line}"
        ;;
      *error*|*Error*|*reset*|*Reset*|*unexpected*eof*|*closed*)
        echo "STREAM_EVENT connection=${connection_id} utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) detail=${line}"
        ;;
    esac
  done

echo "CLOSED connection=${connection_id} utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) uptime=$(cut -d ' ' -f 1 /proc/uptime)"
