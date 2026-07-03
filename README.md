# HENU-Autologin

河南大学校园网/运营商 portal 自动认证脚本，适用于路由器等设备通过校园网认证链路自动登录。

## 适用边界

本项目只处理校园网认证相关接口，例如：

- `http://172.29.35.27:8088/aaa-auth/api/v1/auth`
- `http://172.29.35.27:8882/user/check-only`
- `http://172.29.35.36:6060/quickauth.do`

本项目不处理图书馆预约系统的 CAS ticket、CASTGC、图书馆 token 或 `/v4/*` 预约接口。图书馆预约需单独适配 `ids.henu.edu.cn` 到 `zwyy.henu.edu.cn` 的 CAS 登录链路。

## 使用方法

在 OpenWrt/ImmortalWrt 路由器 SSH 中粘贴下面整段命令。先把开头的 `USERNAME` 和 `PASSWORD` 改成自己的校园网账号密码；整段脚本不依赖 GitHub raw 或外网下载，适合还没登录校园网的离线路由器。脚本内的认证请求优先使用 ImmortalWrt/OpenWrt 默认可用的 `wget`。

```bash
USERNAME='你的学号'
PASSWORD='你的密码'
OPERATOR_SUFFIX='@henuyd'
CAMPUS_CODE='07cdfd23373b17c6b337251c22b7ea57'

cat > /tmp/install_openwrt.sh <<'HENU_AUTOLOGIN_INSTALLER'
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
    if [ -f "$LOCK_DIR/pid" ] && kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
        log "skip: another auto-login process is running (${1:-manual})"
        exit 0
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || {
        log "skip: cannot create lock (${1:-manual})"
        exit 0
    }
fi
echo "$$" > "$LOCK_DIR/pid"
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

http_empty_body() {
    url="$1"
    out="$2"
    rm -f "$out"
    wget -q -T 10 -O "$out" "$url" 2>/dev/null || return 1
    [ "$(wc -c < "$out" 2>/dev/null || echo 1)" = "0" ]
}

http_get_body() {
    wget -q -T 15 -O - "$1" 2>/dev/null || true
}

http_post_form() {
    url="$1"
    data="$2"
    wget -q -T 15 -O - \
        --header="Content-Type: application/x-www-form-urlencoded" \
        --header="Referer: http://172.29.35.36:6060/" \
        --post-data="$data" \
        "$url" 2>/dev/null || true
}

check_network() {
    for url in \
        "http://connectivitycheck.gstatic.com/generate_204" \
        "http://www.gstatic.com/generate_204"
    do
        if http_empty_body "$url" "/tmp/campus_http_check.$$"; then
            rm -f "/tmp/campus_http_check.$$"
            return 0
        fi
        rm -f "/tmp/campus_http_check.$$"
    done

    wget -q -T 10 -O "/tmp/campus_baidu_check.$$" "http://www.baidu.com/" 2>/dev/null || true
    if grep -qi 'STATUS OK\|baidu\|百度' "/tmp/campus_baidu_check.$$" 2>/dev/null; then
        rm -f "/tmp/campus_baidu_check.$$"
        return 0
    fi
    rm -f "/tmp/campus_baidu_check.$$"
    return 1
}

first_auth() {
    log "first auth"
    data="campusCode=${CAMPUS_CODE}&username=${USERNAME}&password=${PASSWORD}&operatorSuffix=${OPERATOR_SUFFIX}"
    RESPONSE1="$(http_post_form \
        "http://172.29.35.27:8088/aaa-auth/api/v1/auth" \
        "$data")"
    log "first auth response: $RESPONSE1"
    echo "$RESPONSE1" | grep -q '"code":1'
}

second_auth() {
    log "second auth"
    data="username=${USERNAME}&password=${PASSWORD}&operatorSuffix=${OPERATOR_SUFFIX}"
    RESPONSE2="$(http_post_form \
        "http://172.29.35.27:8882/user/check-only" \
        "$data")"
    log "second auth response: $RESPONSE2"
    echo "$RESPONSE2" | grep -q '"code":1'
}

portal_auth() {
    WAN_IP="$(get_wan_ip)"
    TIMESTAMP="$(($(date +%s) * 1000))"
    UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$TIMESTAMP")"
    ENCODED_SUFFIX="$(printf "%s" "$OPERATOR_SUFFIX" | sed 's/@/%40/g')"

    log "portal auth: ip=$WAN_IP ts=$TIMESTAMP uuid=$UUID"
    RESPONSE3="$(http_get_body \
        "http://172.29.35.36:6060/quickauth.do?userid=${USERNAME}${ENCODED_SUFFIX}&passwd=${PASSWORD}&wlanuserip=${WAN_IP}&wlanacname=HD-SuShe-ME60&wlanacIp=172.22.254.253&timestamp=${TIMESTAMP}&uuid=${UUID}")"
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
HENU_AUTOLOGIN_INSTALLER

USERNAME="$USERNAME" PASSWORD="$PASSWORD" OPERATOR_SUFFIX="$OPERATOR_SUFFIX" CAMPUS_CODE="$CAMPUS_CODE" sh /tmp/install_openwrt.sh
```

脚本会写入：

- `/etc/campus_network/credentials.conf`
- `/etc/campus_network/auto_login.sh`
- `/etc/hotplug.d/iface/99-campus-auto-login`
- root crontab：每 5 分钟兜底执行一次

关键点：

- `aaa-auth` 和 `check-only` 请求都会带 `operatorSuffix=@henuyd`。
- 网络检查使用 ImmortalWrt/OpenWrt 默认可用的 `wget` 做 HTTP 204/网页访问判断，不再只用 `ping`，避免 ICMP 放行时误判为已登录。
- `wwan ifup` 后会自动触发一次登录，开机时还有 cron 兜底。

如果只想手动运行已安装脚本：

```bash
/etc/campus_network/auto_login.sh
```

查看日志
```bash
cat /tmp/campus_network.log
```
