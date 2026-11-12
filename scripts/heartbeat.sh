#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DISK_JSON="${DISK_JSON:-/library/www/html/home/disk.json}"
TIMEOUT="${TIMEOUT:-15}"

# shellcheck disable=SC2034
url="" format="params" method="" query="" body=""
# shellcheck disable=SC2034
warnings=1 metrics=0 box_id="" interval="6h"
headers=()
# shellcheck disable=SC1090,SC1091
[ -f "$REPO/config/heartbeat.conf" ] && . "$REPO/config/heartbeat.conf"
# shellcheck disable=SC1090,SC1091
[ -f /etc/has-heartbeat.conf ] && . /etc/has-heartbeat.conf

[ -n "$url" ] || exit 0
case "$format" in params|json) ;; *) format="params" ;; esac

# warnings
warns=()
if [ -f "$DISK_JSON" ]; then
  if command -v python3 >/dev/null 2>&1; then
    while IFS= read -r w; do
      [ -n "$w" ] && warns+=("$w")
    done < <(python3 -c 'import json, sys
for w in json.load(open(sys.argv[1])).get("warnings", []):
    print(w)' "$DISK_JSON" 2>/dev/null)
  elif grep -q '"warnings":\[[^]]' "$DISK_JSON"; then
    warns+=("disk.json uyarı içeriyor / disk.json contains warnings")
  fi
else
  warns+=("disk.json yok, disk sağlığı bilinmiyor / missing, disk health unknown")
fi

status="up"
[ ${#warns[@]} -gt 0 ] && status="down"

# message
msg=""
[ -n "$box_id" ] && msg+="[$box_id] "
if [ ${#warns[@]} -gt 0 ]; then
  msg+="PROBLEM: "
  for w in "${warns[@]}"; do msg+="$w | "; done
  msg=${msg%" | "}
else
  msg+="ok"
fi

# metrics
m_up="" m_pct="" m_cpu=""
need=0
[ "$metrics" = 1 ] && need=1
case "$url $query $body" in *"{uptime}"*|*"{disk}"*|*"{cpu}"*) need=1 ;; esac
if [ "$need" = 1 ]; then
  m_up=$(awk '{printf "%dd%dh", int($1/86400), int(($1%86400)/3600)}' /proc/uptime 2>/dev/null)
  m_pct=$(df --output=pcent /library 2>/dev/null | tail -1 | tr -dc '0-9')
  [ -r /sys/class/thermal/thermal_zone0/temp ] && m_cpu=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
fi
extra=""
if [ "$metrics" = 1 ]; then
  extra=" | uptime ${m_up:-?}, disk %${m_pct:-?}"
  [ -n "$m_cpu" ] && extra+=", CPU ${m_cpu}°C"
fi
msg+="$extra"

# escaping
json_esc(){
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys
sys.stdout.write(json.dumps(sys.argv[1])[1:-1])' "$1"
    return
  fi
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

pct_esc(){
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, urllib.parse
sys.stdout.write(urllib.parse.quote_plus(sys.argv[1]))' "$1"
    return
  fi
  local s="$1" out="" bytes hex i c
  bytes=$(printf '%s' "$s" | od -An -v -tx1 | tr -d ' \n')
  for ((i=0; i<${#bytes}; i+=2)); do
    hex=${bytes:i:2}
    printf -v c '%b' "\\x$hex"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      ' ')             out+="+" ;;
      *)               out+="%$hex" ;;
    esac
  done
  printf '%s' "$out"
}

subst(){
  local esc="$1" t="$2" out="" i=1 c rest k v
  while [ "$i" -le "${#t}" ]; do
    c=${t:i-1:1}
    if [ "$c" = "{" ]; then
      rest=${t:i-1}
      for k in status msg box uptime disk cpu; do
        if [[ "$rest" == "{$k}"* ]]; then
          case "$k" in
            status) v=$("$esc" "$status") ;;
            msg)    v=$("$esc" "$msg") ;;
            box)    v=$("$esc" "$box_id") ;;
            uptime) v=$("$esc" "$m_up") ;;
            disk)   v=$("$esc" "$m_pct") ;;
            cpu)    v=$("$esc" "$m_cpu") ;;
          esac
          out+="$v"
          i=$(( i + ${#k} + 2 ))
          continue 2
        fi
      done
    fi
    out+="$c"
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
}

case "$url" in *"{"*) url=$(subst pct_esc "$url") ;; esac

# send heartbeat
sent=1
if [ -n "$query" ] || [ -n "$body" ]; then
  # customization
  args=(-fsS -m "$TIMEOUT" -o /dev/null)
  for h in "${headers[@]}"; do args+=(-H "$h"); done
  [ -n "$method" ] && args+=(-X "$method")
  if [ -n "$body" ]; then
    ct=1
    for h in "${headers[@]}"; do
      [[ "${h,,}" == content-type:* ]] && ct=0
    done
    [ "$ct" = 1 ] && args+=(-H 'Content-Type: application/json')
    args+=(--data-binary "$(subst json_esc "$body")")
  fi
  u="$url"
  if [ -n "$query" ]; then
    q=$(subst pct_esc "$query")
    case "$u" in *"?"*) u="$u&$q" ;; *) u="$u?$q" ;; esac
  fi
  if curl "${args[@]}" "$u"; then sent=0; fi
elif [ "$format" = params ]; then
  args=(-G -fsS -m "$TIMEOUT" -o /dev/null
        --data-urlencode "status=$status" --data-urlencode "msg=$msg")
  [ -n "$box_id" ] && args+=(--data-urlencode "box=$box_id")
  for h in "${headers[@]}"; do args+=(-H "$h"); done
  if curl "${args[@]}" "$url"; then sent=0; fi
else
  if command -v python3 >/dev/null 2>&1; then
    body_json=$(python3 -c 'import json, sys
print(json.dumps({"content": sys.argv[1], "text": sys.argv[1]}))' "$msg")
  else
    esc=${msg//\\/\\\\}
    esc=${esc//\"/\\\"}
    body_json="{\"content\":\"$esc\",\"text\":\"$esc\"}"
  fi
  args=(-fsS -m "$TIMEOUT" -o /dev/null -H 'Content-Type: application/json'
        --data-binary "$body_json")
  [ -n "$method" ] && args+=(-X "$method")
  for h in "${headers[@]}"; do args+=(-H "$h"); done
  if curl "${args[@]}" "$url"; then sent=0; fi
fi

if [ "$sent" -eq 0 ]; then
  echo "heartbeat: sinyal gitti / signal sent ($status)"
else
  echo "heartbeat: gönderilemedi, kutu internetsiz olabilir / not sent, box is probably offline"
fi
exit 0
