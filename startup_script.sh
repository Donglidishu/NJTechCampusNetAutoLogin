#!/bin/sh

# ----------------------------------------------------
# NJTech campus network auto login script
# 主版本：
# 1) 无参数执行：作为路由器开机启动脚本
# 2) run：手动执行一次登录
# 3) install / uninstall：注册或移除开机启动
#
# 自动清理在线设备的实验版本已单独拆分到：
# /data/startup_script_cleanup.sh
# ----------------------------------------------------

# ---------------------- 配置区 ----------------------
LOGFILE="${LOGFILE:-/data/autoLogin.log}"
RESULT_FILE="${RESULT_FILE:-/data/login_result.txt}"
NET_IFACE="${NET_IFACE:-eth0.1}"
BOOT_WAIT="${BOOT_WAIT:-90}"
MAX_TRIES="${MAX_TRIES:-8}"
RETRY_SLEEP="${RETRY_SLEEP:-10}"
LOCKDIR="${LOCKDIR:-/tmp/njtech-auto-login.lock}"
INSTALL_PATH="${INSTALL_PATH:-/data/startup_script.sh}"

PORTAL_SCHEME="${PORTAL_SCHEME:-http}"
PORTAL_HOST="${PORTAL_HOST:-10.50.255.11}"
PORTAL_PORT="${PORTAL_PORT:-801}"
PORTAL_PATH="${PORTAL_PATH:-/eportal/portal/login}"

LOGIN_METHOD="${LOGIN_METHOD:-1}"
TERMINAL_TYPE="${TERMINAL_TYPE:-1}"
CALLBACK="${CALLBACK:-dr1003}"
JS_VERSION="${JS_VERSION:-4.1.3}"
REQUEST_VERSION="${REQUEST_VERSION:-1640}"
LANGUAGE="${LANGUAGE:-zh-cn}"

LOGIN_ACCOUNT="${LOGIN_ACCOUNT:-202400000000}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-password}"
ACCOUNT_PREFIX="${ACCOUNT_PREFIX:-,0,}"
ACCOUNT_SUFFIX="${ACCOUNT_SUFFIX:-@cmcc}"
USER_ACCOUNT="${USER_ACCOUNT:-}"
WLAN_USER_MAC="${WLAN_USER_MAC:-}"

CHECK_URL="${CHECK_URL:-http://www.baidu.com}"
CHECK_TRIES="${CHECK_TRIES:-3}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3}"
# ---------------------------------------------------

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    printf '[%s] %s\n' "$(timestamp)" "$1" >> "$LOGFILE"
}

print_color() {
    COLOR="$1"
    MESSAGE="$2"
    printf '\033[%sm%s\033[0m\n' "$COLOR" "$MESSAGE"
}

cleanup_lock() {
    rmdir "$LOCKDIR" >/dev/null 2>&1
}

normalize_mac() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d ':-'
}

get_interface_ip() {
    ip addr show "$NET_IFACE" 2>/dev/null \
        | awk '/inet / {print $2}' \
        | cut -d'/' -f1 \
        | head -n 1
}

detect_mac() {
    ip link show "$NET_IFACE" 2>/dev/null \
        | awk '/link\/ether/ {print $2}' \
        | head -n 1
}

build_user_account() {
    if [ -n "$USER_ACCOUNT" ]; then
        printf '%s' "$USER_ACCOUNT"
    else
        printf '%s%s%s' "$ACCOUNT_PREFIX" "$LOGIN_ACCOUNT" "$ACCOUNT_SUFFIX"
    fi
}

mask_sensitive() {
    printf '%s' "$1" | sed "s|$LOGIN_PASSWORD|******|g"
}

extract_msg() {
    sed -n 's/.*"msg":"\([^"]*\)".*/\1/p' "$RESULT_FILE" | head -n 1
}

extract_result() {
    sed -n 's/.*"result":\([0-9-]*\).*/\1/p' "$RESULT_FILE" | head -n 1
}

is_success_message() {
    case "$1" in
        *Portal协议认证成功*|*已经在线*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

check_connectivity() {
    TRY=1
    while [ "$TRY" -le "$CHECK_TRIES" ]; do
        HTTP_CODE="$(curl -I -s --connect-timeout 5 --max-time 10 "$CHECK_URL" -w '%{http_code}' -o /dev/null)"
        case "$HTTP_CODE" in
            200|204|301|302)
                log "网络探测成功，HTTP 状态码: $HTTP_CODE"
                return 0
                ;;
        esac

        log "网络探测第 $TRY 次失败，HTTP 状态码: ${HTTP_CODE:-none}"
        sleep "$CHECK_INTERVAL"
        TRY=$((TRY + 1))
    done

    return 1
}

wait_for_ip() {
    TRY=1
    IP=""

    while [ "$TRY" -le "$MAX_TRIES" ]; do
        IP="$(get_interface_ip)"
        if [ -n "$IP" ]; then
            log "第 $TRY 次检查拿到 IP: $IP"
            printf '%s' "$IP"
            return 0
        fi

        log "第 $TRY 次检查未拿到 IP，$RETRY_SLEEP 秒后重试。"
        sleep "$RETRY_SLEEP"
        TRY=$((TRY + 1))
    done

    return 1
}

run_login() {
    if ! mkdir "$LOCKDIR" >/dev/null 2>&1; then
        log "检测到已有登录任务正在运行，跳过本次执行。"
        return 0
    fi

    trap cleanup_lock EXIT INT TERM

    log "************** 开始登录 **************"
    log "使用接口: $NET_IFACE"

    LOGIN_IP="$(wait_for_ip)"
    if [ -z "$LOGIN_IP" ]; then
        log "错误: 在 $MAX_TRIES 次尝试后仍未从 $NET_IFACE 获取到 IP。"
        log "************** 登录结束 **************"
        return 1
    fi

    RAW_MAC="${WLAN_USER_MAC:-$(detect_mac)}"
    NORMALIZED_MAC="$(normalize_mac "$RAW_MAC")"
    if [ -z "$NORMALIZED_MAC" ]; then
        NORMALIZED_MAC="000000000000"
    fi

    FINAL_USER_ACCOUNT="$(build_user_account)"
    PORTAL_URL="${PORTAL_SCHEME}://${PORTAL_HOST}:${PORTAL_PORT}${PORTAL_PATH}"

    echo "************** 开始执行登录 **************"
    echo "当前 IP: $LOGIN_IP"
    echo "当前 MAC: $NORMALIZED_MAC"
    echo "当前账号: $FINAL_USER_ACCOUNT"

    log "LOGIN_IP=$LOGIN_IP"
    log "WLAN_USER_MAC=$NORMALIZED_MAC"
    log "USER_ACCOUNT=$FINAL_USER_ACCOUNT"

    curl -sS -G "$PORTAL_URL" \
        --data-urlencode "callback=$CALLBACK" \
        --data-urlencode "login_method=$LOGIN_METHOD" \
        --data-urlencode "user_account=$FINAL_USER_ACCOUNT" \
        --data-urlencode "user_password=$LOGIN_PASSWORD" \
        --data-urlencode "wlan_user_ip=$LOGIN_IP" \
        --data-urlencode "wlan_user_ipv6=" \
        --data-urlencode "wlan_user_mac=$NORMALIZED_MAC" \
        --data-urlencode "wlan_ac_ip=" \
        --data-urlencode "wlan_ac_name=" \
        --data-urlencode "jsVersion=$JS_VERSION" \
        --data-urlencode "terminal_type=$TERMINAL_TYPE" \
        --data-urlencode "lang=$LANGUAGE" \
        --data-urlencode "v=$REQUEST_VERSION" \
        -o "$RESULT_FILE"
    CURL_EXIT_CODE=$?

    if [ "$CURL_EXIT_CODE" -ne 0 ]; then
        echo "登录请求发送失败，curl 退出码: $CURL_EXIT_CODE"
        log "登录请求发送失败，curl_exit_code=$CURL_EXIT_CODE"
        log "************** 登录结束 **************"
        return "$CURL_EXIT_CODE"
    fi

    RESULT="$(cat "$RESULT_FILE" 2>/dev/null)"
    RESULT_CODE="$(extract_result)"
    RESULT_MSG="$(extract_msg)"

    echo "************** 登录请求已发送 **************"
    echo "返回内容："
    head -n 5 "$RESULT_FILE"

    log "响应内容: $(mask_sensitive "$RESULT")"

    if [ "$RESULT_CODE" = "1" ] || is_success_message "$RESULT_MSG"; then
        log "Portal 返回成功: ${RESULT_MSG:-result=$RESULT_CODE}"

        if check_connectivity; then
            echo "网络已通，登录成功。"
            log "登录成功，网络探测通过。"
            log "************** 登录结束 **************"
            return 0
        fi

        echo "Portal 提示登录成功，但联网探测未通过，请观察实际网络状态。"
        log "Portal 提示成功，但联网探测未通过。"
        log "************** 登录结束 **************"
        return 0
    fi

    echo "登录失败。"
    if [ -n "$RESULT_MSG" ]; then
        echo "失败信息: $RESULT_MSG"
    fi
    log "登录失败，result=${RESULT_CODE:-unknown}，msg=${RESULT_MSG:-none}"
    log "************** 登录结束 **************"
    return 1
}

startup_hook() {
    chmod +x "$INSTALL_PATH" >> "$LOGFILE" 2>&1
    log "开机启动触发，脚本路径: $INSTALL_PATH，等待 $BOOT_WAIT 秒后执行登录。"
    sleep "$BOOT_WAIT"
    sh "$INSTALL_PATH" run >> "$LOGFILE" 2>&1 &
}

install() {
    uci set firewall.startup_script=include
    uci set firewall.startup_script.type='script'
    uci set firewall.startup_script.path="$INSTALL_PATH"
    uci set firewall.startup_script.enabled='1'
    uci commit firewall
    print_color 32 'startup_script install complete.'
}

uninstall() {
    uci delete firewall.startup_script
    uci commit firewall
    print_color 33 'startup_script has been removed.'
}

main() {
    case "${1:-startup}" in
        startup)
            startup_hook
            ;;
        run)
            run_login
            ;;
        install)
            install
            ;;
        uninstall)
            uninstall
            ;;
        *)
            print_color 31 "Unknown parameter: $1"
            return 1
            ;;
    esac
}

main "$@"
