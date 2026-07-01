# HENU-Autologin

河南大学校园网/运营商 portal 自动认证脚本，适用于路由器等设备通过校园网认证链路自动登录。

## 适用边界

本项目只处理校园网认证相关接口，例如：

- `http://172.29.35.27:8088/aaa-auth/api/v1/auth`
- `http://172.29.35.27:8882/user/check-only`
- `http://172.29.35.36:6060/quickauth.do`

本项目不处理图书馆预约系统的 CAS ticket、CASTGC、图书馆 token 或 `/v4/*` 预约接口。图书馆预约需单独适配 `ids.henu.edu.cn` 到 `zwyy.henu.edu.cn` 的 CAS 登录链路。

## 使用方法

修改下面的username，password后，在路由器的ssh运行
```bash
cat > /etc/campus_network/auto_login.sh << 'EOF'
#!/bin/sh

USERNAME="***"
PASSWORD="***"
OPERATOR_SUFFIX="@henuyd"
CAMPUS_CODE="07cdfd23373b17c6b337251c22b7ea57"

LOG_FILE="/tmp/campus_network.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

# 获取网络参数
get_auth_params() {
    # 获取当前WAN IP
    WAN_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    
    # 生成时间戳和UUID
    TIMESTAMP=$(($(date +%s) * 1000))
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    
    echo "$WAN_IP $TIMESTAMP $UUID"
}

# 第一步认证
first_auth() {
    log "第一步认证..."
    RESPONSE1=$(curl -s -X POST \
        "http://172.29.35.27:8088/aaa-auth/api/v1/auth" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Referer: http://172.29.35.36:6060/" \
        --data-raw "campusCode=${CAMPUS_CODE}&username=${USERNAME}&password=${PASSWORD}&operatorSuffix=${OPERATOR_SUFFIX}")
    
    log "第一步响应: $RESPONSE1"
    if echo "$RESPONSE1" | grep -q '"code":1'; then
        return 0
    else
        return 1
    fi
}

# 第二步认证
second_auth() {
    log "第二步认证..."
    RESPONSE2=$(curl -s -X POST \
        "http://172.29.35.27:8882/user/check-only" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Referer: http://172.29.35.36:6060/" \
        --data-raw "username=${USERNAME}&password=${PASSWORD}&operatorSuffix=${OPERATOR_SUFFIX}")
    
    log "第二步响应: $RESPONSE2"
    if echo "$RESPONSE2" | grep -q '"code":1'; then
        return 0
    else
        return 1
    fi
}

# 第三步门户认证（使用简化成功的版本）
portal_auth() {
    log "第三步门户认证..."
    
    # 获取参数
    PARAMS=$(get_auth_params)
    WAN_IP=$(echo "$PARAMS" | cut -d' ' -f1)
    TIMESTAMP=$(echo "$PARAMS" | cut -d' ' -f2)
    UUID=$(echo "$PARAMS" | cut -d' ' -f3)
    
    log "使用参数: IP=$WAN_IP, TS=$TIMESTAMP, UUID=$UUID"
    
    # 使用简化成功的URL格式
    RESPONSE3=$(curl -s \
        "http://172.29.35.36:6060/quickauth.do?userid=${USERNAME}%40henuyd&passwd=${PASSWORD}&wlanuserip=${WAN_IP}&wlanacname=HD-SuShe-ME60&wlanacIp=172.22.254.253&timestamp=${TIMESTAMP}&uuid=${UUID}" \
        -H "Referer: http://172.29.35.36:6060/" \
        -b "macAuth=; ABMS=362ee66b-fa1f-4ef9-a651-bfd9d61d194a" \
        --connect-timeout 10)
    
    log "第三步响应: $RESPONSE3"
    
    if echo "$RESPONSE3" | grep -q '"message":"认证成功"'; then
        log "✅ 第三步认证成功"
        return 0
    else
        log "❌ 第三步认证失败"
        return 1
    fi
}

# 网络检查
check_network() {
    ping -c 2 -W 3 8.8.8.8 > /dev/null 2>&1
}

# 完整认证流程
full_auth() {
    log "开始完整认证流程..."
    
    if first_auth; then
        sleep 2
        if second_auth; then
            sleep 2
            if portal_auth; then
                log "🎉 所有认证步骤成功完成"
                return 0
            else
                log "❌ 第三步认证失败"
                return 1
            fi
        else
            log "❌ 第二步认证失败"
            return 1
        fi
    else
        log "❌ 第一步认证失败"
        return 1
    fi
}

main() {
    log "=== 校园网认证启动 ==="
    
    if check_network; then
        log "网络已连通"
        return 0
    fi
    
    log "网络未连通，开始完整认证流程..."
    if full_auth; then
        sleep 5
        if check_network; then
            log "🎉 认证成功，网络已连通！"
        else
            log "⚠️ 认证完成但网络检测失败"
        fi
    else
        log "❌ 认证流程失败"
    fi
}

main
EOF
```
设置权限并设置
```bash
chmod +x /etc/campus_network/auto_login.sh
/etc/campus_network/auto_login.sh
```

查看日志
```bash
cat /tmp/campus_network.log
```
