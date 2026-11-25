#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DISK_JSON="${DISK_JSON:-/library/www/html/home/disk.json}"
TIMEOUT="${TIMEOUT:-15}"
SAMPLE_CONF="${HAS_HEARTBEAT_SAMPLE_CONF-$REPO/config/heartbeat.conf}"

# shellcheck disable=SC2034
url="" format="params" method="" query="" body=""
# shellcheck disable=SC2034
warnings=1 metrics=0 box_id="" interval="6h"
headers=()
# shellcheck disable=SC1090,SC1091
[ -n "$SAMPLE_CONF" ] && [ -f "$SAMPLE_CONF" ] && . "$SAMPLE_CONF"
# shellcheck disable=SC1090,SC1091
[ -r /etc/has-heartbeat.conf ] && . /etc/has-heartbeat.conf

[ -n "$url" ] || exit 0
case "$format" in params|json) ;; *) format="params" ;; esac

# warnings
warns=()
has_py=0
command -v python3 >/dev/null 2>&1 && has_py=1
if [ -f "$DISK_JSON" ]; then
  py_ok=0
  py_out=""
  if [ "$has_py" = 1 ]; then
    py_out=$(python3 -c 'import base64, json, sys
for w in json.load(open(sys.argv[1])).get("warnings", []):
    print(base64.b64encode(str(w).encode()).decode())' "$DISK_JSON" 2>/dev/null) && py_ok=1
  fi
  if [ "$py_ok" = 1 ]; then
    while IFS= read -r w; do
      [ -n "$w" ] && warns+=("$(printf '%s' "$w" | base64 -d)")
    done <<<"$py_out"
  elif [ "$has_py" = 1 ]; then
    warns+=("disk.json okunamadı, disk sağlığı bilinmiyor / unreadable, disk health unknown")
  elif grep -q '"warnings":\[[^]]' "$DISK_JSON" 2>/dev/null; then
    warns+=("disk.json uyarı içeriyor / disk.json contains warnings")
  fi
else
  warns+=("disk.json yok, disk sağlığı bilinmiyor / missing, disk health unknown")
fi

# durum / status: uyarı varsa down (warnings=0 olsa bile) /
# down whenever warnings exist, even with warnings=0
has_warns=0
[ ${#warns[@]} -gt 0 ] && has_warns=1
status="up"
[ "$has_warns" = 1 ] && status="down"

# warnings=1 ise uyarı metinleri sinyale eklenir
# warning texts are included only when warnings=1
msg=""
[ -n "$box_id" ] && msg+="[$box_id] "
if [ "$has_warns" = 1 ]; then
  msg+="PROBLEM: "
  if [ "$warnings" = 1 ]; then
    for w in "${warns[@]}"; do msg+="$w | "; done
    msg=${msg%" | "}
  else
    msg+="uyarı var, metin gizli / warnings present, text hidden"
  fi
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

esc_cfg(){
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

sent=1
url_out="$url"
body_out=""
if [ -n "$query" ] || [ -n "$body" ]; then
  # customization
  if [ -n "$query" ]; then
    q=$(subst pct_esc "$query")
    case "$url_out" in *"?"*) url_out="$url_out&$q" ;; *) url_out="$url_out?$q" ;; esac
  fi
  [ -n "$body" ] && body_out=$(subst json_esc "$body")
elif [ "$format" = params ]; then
  q="status=$(pct_esc "$status")&msg=$(pct_esc "$msg")"
  [ -n "$box_id" ] && q+="&box=$(pct_esc "$box_id")"
  case "$url_out" in *"?"*) url_out="$url_out&$q" ;; *) url_out="$url_out?$q" ;; esac
else
  if command -v python3 >/dev/null 2>&1; then
    body_out=$(python3 -c 'import json, sys
print(json.dumps({"content": sys.argv[1], "text": sys.argv[1]}))' "$msg")
  else
    esc=${msg//\\/\\\\}
    esc=${esc//\"/\\\"}
    body_out="{\"content\":\"$esc\",\"text\":\"$esc\"}"
  fi
fi

cfg="silent
show-error
fail
globoff
output = \"/dev/null\"
max-time = \"$(esc_cfg "$TIMEOUT")\"
url = \"$(esc_cfg "$url_out")\"
"
ct=1
for h in "${headers[@]}"; do
  [[ "${h,,}" == content-type:* ]] && ct=0
  cfg+="header = \"$(esc_cfg "$h")\""$'\n'
done
if [ -n "$body_out" ]; then
  [ "$ct" = 1 ] && cfg+='header = "Content-Type: application/json"'$'\n'
  cfg+="data-binary = \"$(esc_cfg "$body_out")\""$'\n'
fi
[ -n "$method" ] && cfg+="request = \"$(esc_cfg "$method")\""$'\n'

if printf '%s' "$cfg" | curl -K -; then sent=0; fi

if [ "$sent" -eq 0 ]; then
  echo "heartbeat: sinyal gitti / signal sent ($status)"
else
  echo "heartbeat: gönderilemedi, kutu internetsiz olabilir / not sent, box is probably offline"
fi
exit 0
