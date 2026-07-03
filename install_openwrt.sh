#!/bin/sh
set -eu

DIR="/etc/campus_network"
LOGIN="$DIR/auto_login.sh"
CONF="$DIR/credentials.conf"
HOTPLUG="/etc/hotplug.d/iface/99-campus-auto-login"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$DIR/backup-$TS"

mkdir -p "$DIR" "$BACKUP"

[ -f "$LOGIN" ] && cp -a "$LOGIN" "$BACKUP/auto_login.sh"
[ -f "$CONF" ] && cp -a "$CONF" "$BACKUP/credentials.conf"
[ -f "$HOTPLUG" ] && cp -a "$HOTPLUG" "$BACKUP/99-campus-auto-login"
[ -f /etc/rc.local ] && cp -a /etc/rc.local "$BACKUP/rc.local"
crontab -l > "$BACKUP/crontab-root" 2>/dev/null || true

extract_var() {
    var="$1"
    file="$2"
    [ -f "$file" ] || return 0
    sed -n "s/^${var}=[\"']\\{0,1\\}\\([^\"']*\\)[\"']\\{0,1\\}.*/\\1/p" "$file" | head -n 1
}

USERNAME="${USERNAME:-$(extract_var USERNAME "$CONF")}"
PASSWORD="${PASSWORD:-$(extract_var PASSWORD "$CONF")}"
OPERATOR_SUFFIX="${OPERATOR_SUFFIX:-$(extract_var OPERATOR_SUFFIX "$CONF")}"
CAMPUS_CODE="${CAMPUS_CODE:-$(extract_var CAMPUS_CODE "$CONF")}"

USERNAME="${USERNAME:-$(extract_var USERNAME "$LOGIN")}"
PASSWORD="${PASSWORD:-$(extract_var PASSWORD "$LOGIN")}"
OPERATOR_SUFFIX="${OPERATOR_SUFFIX:-$(extract_var OPERATOR_SUFFIX "$LOGIN")}"
CAMPUS_CODE="${CAMPUS_CODE:-$(extract_var CAMPUS_CODE "$LOGIN")}"

OPERATOR_SUFFIX="${OPERATOR_SUFFIX:-@henuyd}"
CAMPUS_CODE="${CAMPUS_CODE:-07cdfd23373b17c6b337251c22b7ea57}"

if [ -z "${USERNAME:-}" ] || [ -z "${PASSWORD:-}" ]; then
    echo "ERROR: set USERNAME and PASSWORD first, or keep them in $LOGIN/$CONF."
    echo "Example:"
    echo "  USERNAME='2510xxxxxx' PASSWORD='your_password' sh install_openwrt.sh"
    exit 1
fi

quote_sh() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

{
    echo "USERNAME=$(quote_sh "$USERNAME")"
    echo "PASSWORD=$(quote_sh "$PASSWORD")"
    echo "OPERATOR_SUFFIX=$(quote_sh "$OPERATOR_SUFFIX")"
    echo "CAMPUS_CODE=$(quote_sh "$CAMPUS_CODE")"
} > "$CONF"
chmod 600 "$CONF"

cat > "$LOGIN" <<'AUTO_LOGIN'
#!/bin/sh

CONF="/etc/campus_network/credentials.conf"
LOG_FILE="/tmp/campus_network.log"
LOCK_DIR="/tmp/campus_auto_login.lock"

[ -f "$CONF" ] || {
    echo "missing credentials: $CONF" >> "$LOG_FILE"
    exit 1
}

. "$CONF"
OPERATOR_SUFFIX="${OPERATOR_SUFFIX:-@henuyd}"
CAMPUS_CODE="${CAMPUS_CODE:-07cdfd23373b17c6b337251c22b7ea57}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "skip: another auto-login process is running (${1:-manual})"
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

get_wan_ip() {
    ip -4 route get 8.8.8.8 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' |
        head -n 1
}

wait_for_route() {
    i=0
    while [ "$i" -lt 30 ]; do
        WAN_IP="$(get_wan_ip)"
        if [ -n "$WAN_IP" ] && ip route | grep -q '^default '; then
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    return 1
}

http_code() {
    url="$1"
    curl -L -sS --connect-timeout 5 --max-time 10 \
        -o "/tmp/campus_http_check.$$" \
        -w '%{http_code}' "$url" 2>/dev/null || true
    rm -f "/tmp/campus_http_check.$$"
}

check_network() {
    for url in \
        "http://connectivitycheck.gstatic.com/generate_204" \
        "http://www.gstatic.com/generate_204"
    do
        code="$(http_code "$url")"
        [ "$code" = "204" ] && return 0
    done

    code="$(curl -k -L -sS --connect-timeout 5 --max-time 10 \
        -o "/tmp/campus_baidu_check.$$" \
        -w '%{http_code}' https://www.baidu.com/ 2>/dev/null || true)"
    if [ "$code" = "200" ] &&
        grep -qi 'STATUS OK\|baidu\|百度' "/tmp/campus_baidu_check.$$" 2>/dev/null; then
        rm -f "/tmp/campus_baidu_check.$$"
        return 0
    fi
    rm -f "/tmp/campus_baidu_check.$$"
    return 1
}

first_auth() {
    log "first auth"
    RESPONSE1="$(curl -sS -X POST \
        "http://172.29.35.27:8088/aaa-auth/api/v1/auth" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Referer: http://172.29.35.36:6060/" \
        --connect-timeout 8 --max-time 15 \
        --data-urlencode "campusCode=${CAMPUS_CODE}" \
        --data-urlencode "username=${USERNAME}" \
        --data-urlencode "password=${PASSWORD}" \
        --data-urlencode "operatorSuffix=${OPERATOR_SUFFIX}" 2>/dev/null || true)"
    log "first auth response: $RESPONSE1"
    echo "$RESPONSE1" | grep -q '"code":1'
}

second_auth() {
    log "second auth"
    RESPONSE2="$(curl -sS -X POST \
        "http://172.29.35.27:8882/user/check-only" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Referer: http://172.29.35.36:6060/" \
        --connect-timeout 8 --max-time 15 \
        --data-urlencode "username=${USERNAME}" \
        --data-urlencode "password=${PASSWORD}" \
        --data-urlencode "operatorSuffix=${OPERATOR_SUFFIX}" 2>/dev/null || true)"
    log "second auth response: $RESPONSE2"
    echo "$RESPONSE2" | grep -q '"code":1'
}

portal_auth() {
    WAN_IP="$(get_wan_ip)"
    TIMESTAMP="$(($(date +%s) * 1000))"
    UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$TIMESTAMP")"

    log "portal auth: ip=$WAN_IP ts=$TIMESTAMP uuid=$UUID"
    RESPONSE3="$(curl -sS -G \
        "http://172.29.35.36:6060/quickauth.do" \
        -H "Referer: http://172.29.35.36:6060/" \
        -b "macAuth=; ABMS=362ee66b-fa1f-4ef9-a651-bfd9d61d194a" \
        --connect-timeout 8 --max-time 15 \
        --data-urlencode "userid=${USERNAME}${OPERATOR_SUFFIX}" \
        --data-urlencode "passwd=${PASSWORD}" \
        --data-urlencode "wlanuserip=${WAN_IP}" \
        --data-urlencode "wlanacname=HD-SuShe-ME60" \
        --data-urlencode "wlanacIp=172.22.254.253" \
        --data-urlencode "timestamp=${TIMESTAMP}" \
        --data-urlencode "uuid=${UUID}" 2>/dev/null || true)"
    log "portal auth response: $RESPONSE3"
    echo "$RESPONSE3" | grep -Eq '"message":"认证成功"|认证成功|已经认证|已在线'
}

full_auth() {
    log "start full auth"
    first_auth || { log "first auth failed"; return 1; }
    sleep 2
    second_auth || { log "second auth failed"; return 1; }
    sleep 2
    portal_auth || { log "portal auth failed"; return 1; }
    log "full auth succeeded"
    return 0
}

main() {
    trigger="${1:-manual}"
    log "=== campus auto-login start trigger=$trigger ==="

    if ! wait_for_route; then
        log "default route not ready"
        exit 1
    fi

    if check_network; then
        log "http check passed; skip auth"
        exit 0
    fi

    log "http check failed; run auth"
    if full_auth; then
        sleep 5
        if check_network; then
            log "auth succeeded; http check passed"
            exit 0
        fi
        log "auth finished but http check still failed"
        exit 1
    fi

    log "auth failed"
    exit 1
}

main "$@"
AUTO_LOGIN

chmod 700 "$LOGIN"
sh -n "$LOGIN"

cat > "$HOTPLUG" <<'HOTPLUG'
#!/bin/sh
[ "$INTERFACE" = "wwan" ] || exit 0
[ "$ACTION" = "ifup" ] || exit 0
( sleep 8; /etc/campus_network/auto_login.sh "hotplug:$ACTION:$INTERFACE" ) >/dev/null 2>&1 &
HOTPLUG

chmod 755 "$HOTPLUG"
sh -n "$HOTPLUG"

if [ -f /etc/rc.local ]; then
    awk '
        /\/etc\/campus_network\/auto_login\.sh/ { next }
        /^exit 0$/ && !done {
            print "( sleep 30; /etc/campus_network/auto_login.sh boot ) >/dev/null 2>&1 &"
            done=1
        }
        { print }
        END {
            if (!done) {
                print "( sleep 30; /etc/campus_network/auto_login.sh boot ) >/dev/null 2>&1 &"
                print "exit 0"
            }
        }
    ' /etc/rc.local > /tmp/rc.local.campus.new
    mv /tmp/rc.local.campus.new /etc/rc.local
    chmod 755 /etc/rc.local
fi

(
    crontab -l 2>/dev/null | grep -v '/etc/campus_network/auto_login.sh' || true
    echo '*/5 * * * * /etc/campus_network/auto_login.sh cron >/dev/null 2>&1'
) | crontab -

/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron restart >/dev/null 2>&1 || true

echo "OK: installed campus auto-login."
echo "Backup: $BACKUP"
"$LOGIN" install || true
tail -n 80 /tmp/campus_network.log 2>/dev/null || true
