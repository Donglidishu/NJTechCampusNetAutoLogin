#!/bin/sh

# ----------------------------------------------------
# NJTech campus network auto login cleanup script
# 实验版本：
# 1) 无参数执行：作为路由器开机启动脚本
# 2) run：手动执行一次登录，必要时尝试设备清理
# 3) fetch-captcha：仅拉取统一认证验证码
# 4) cleanup：仅执行统一认证登录 + 设备下线
# 5) install / uninstall：注册或移除开机启动
# ----------------------------------------------------

# ---------------------- 配置区 ----------------------
LOGFILE="${LOGFILE:-/data/autoLogin.log}"
RESULT_FILE="${RESULT_FILE:-/data/login_result.txt}"
NET_IFACE="${NET_IFACE:-eth0.1}"
BOOT_WAIT="${BOOT_WAIT:-90}"
MAX_TRIES="${MAX_TRIES:-8}"
RETRY_SLEEP="${RETRY_SLEEP:-10}"
LOCKDIR="${LOCKDIR:-/tmp/njtech-auto-login.lock}"
INSTALL_PATH="${INSTALL_PATH:-/data/startup_script_cleanup.sh}"
WORKDIR="${WORKDIR:-/tmp/njtech-auto-login}"

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

ENABLE_DEVICE_CLEANUP="${ENABLE_DEVICE_CLEANUP:-1}"
SSO_LOGIN_URL="${SSO_LOGIN_URL:-https://sfgl.njtech.edu.cn/cas/login?service=http:%2F%2F210.28.203.39:8080%2FSelf%2Fsso_login}"
SSO_BASE="${SSO_BASE:-https://sfgl.njtech.edu.cn}"
SELF_BASE="${SELF_BASE:-http://210.28.203.39:8080/Self}"
SSO_CURL_INSECURE="${SSO_CURL_INSECURE:-1}"
SSO_CAPTCHA_IMAGE="${SSO_CAPTCHA_IMAGE:-/data/njtech_sso_captcha.jpg}"
SSO_CAPTCHA_CODE="${SSO_CAPTCHA_CODE:-}"
SSO_CAPTCHA_CODE_FILE="${SSO_CAPTCHA_CODE_FILE:-/data/njtech_sso_captcha_code.txt}"
OFFLINE_MATCH_MAC_FIRST="${OFFLINE_MATCH_MAC_FIRST:-1}"
# ---------------------------------------------------

SSO_COOKIE_JAR="$WORKDIR/sso.cookie"
SSO_LOGIN_PAGE="$WORKDIR/cas_login.html"
SSO_CAPTCHA_META="$WORKDIR/captcha_meta.json"
SSO_DASHBOARD_HTML="$WORKDIR/dashboard.html"
SSO_ONLINE_LIST_JSON="$WORKDIR/online_list.json"
SSO_OFFLINE_RESULT="$WORKDIR/offline_result.txt"

LAST_RESULT_CODE=""
LAST_RESULT_MSG=""
LAST_RESULT_RAW=""
LOGIN_IP=""
NORMALIZED_MAC=""
FINAL_USER_ACCOUNT=""

if [ "$SSO_CURL_INSECURE" = "1" ]; then
    SSO_CURL_FLAG="-k"
else
    SSO_CURL_FLAG=""
fi

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

ensure_workdir() {
    mkdir -p "$WORKDIR" >/dev/null 2>&1
}

require_command() {
    command -v "$1" >/dev/null 2>&1
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

extract_msg_from_file() {
    sed -n 's/.*"msg":"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

extract_result_from_file() {
    sed -n 's/.*"result":\([0-9-]*\).*/\1/p' "$1" | head -n 1
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

needs_device_cleanup_message() {
    case "$1" in
        *终端超限*|*设备超限*|*在线终端清理*|*手动清理*)
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

parse_portal_result() {
    LAST_RESULT_RAW="$(cat "$RESULT_FILE" 2>/dev/null)"
    LAST_RESULT_CODE="$(extract_result_from_file "$RESULT_FILE")"
    LAST_RESULT_MSG="$(extract_msg_from_file "$RESULT_FILE")"
}

show_portal_result() {
    echo "************** 登录请求已发送 **************"
    echo "返回内容："
    head -n 5 "$RESULT_FILE"
}

perform_portal_login() {
    PORTAL_URL="${PORTAL_SCHEME}://${PORTAL_HOST}:${PORTAL_PORT}${PORTAL_PATH}"

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
        return "$CURL_EXIT_CODE"
    fi

    parse_portal_result
    show_portal_result
    log "响应内容: $(mask_sensitive "$LAST_RESULT_RAW")"
    return 0
}

finish_success() {
    if check_connectivity; then
        echo "网络已通，登录成功。"
        log "登录成功，网络探测通过。"
    else
        echo "Portal 提示登录成功，但联网探测未通过，请观察实际网络状态。"
        log "Portal 提示成功，但联网探测未通过。"
    fi

    log "************** 登录结束 **************"
    return 0
}

extract_html_id_text() {
    FILE="$1"
    TARGET_ID="$2"
    tr -d '\r' < "$FILE" \
        | sed -n "s:.*id=['\"]$TARGET_ID['\"][^>]*>[[:space:]]*\\([^<]*\\)[[:space:]]*<.*:\\1:p" \
        | head -n 1
}

extract_json_string_value() {
    FILE="$1"
    KEY="$2"
    sed -n "s/.*\"$KEY\":\"\\([^\"]*\\)\".*/\\1/p" "$FILE" | head -n 1
}

get_captcha_code_value() {
    if [ -n "$SSO_CAPTCHA_CODE" ]; then
        printf '%s' "$SSO_CAPTCHA_CODE" | tr -d '\r\n '
        return 0
    fi

    if [ -f "$SSO_CAPTCHA_CODE_FILE" ]; then
        head -n 1 "$SSO_CAPTCHA_CODE_FILE" | tr -d '\r\n '
        return 0
    fi

    return 1
}

decode_base64_key_to_hex() {
    KEY_B64="$1"
    printf '%s' "$KEY_B64" \
        | openssl enc -base64 -d -A 2>/dev/null \
        | hexdump -ve '1/1 "%.2x"'
}

openssl_des_encrypt_base64() {
    KEY_HEX="$1"
    PLAINTEXT="$2"

    OUT="$(printf '%s' "$PLAINTEXT" | openssl enc -des-ecb -nosalt -K "$KEY_HEX" -base64 2>/dev/null | tr -d '\r\n')"
    if [ -n "$OUT" ]; then
        printf '%s' "$OUT"
        return 0
    fi

    OUT="$(printf '%s' "$PLAINTEXT" | openssl enc -provider legacy -des-ecb -nosalt -K "$KEY_HEX" -base64 2>/dev/null | tr -d '\r\n')"
    if [ -n "$OUT" ]; then
        printf '%s' "$OUT"
        return 0
    fi

    return 1
}

encrypt_sso_password() {
    CRYPTO_B64="$1"

    if ! require_command openssl; then
        log "统一认证清理失败：路由器环境缺少 openssl，无法完成 DES 加密。"
        return 1
    fi

    if ! require_command hexdump; then
        log "统一认证清理失败：路由器环境缺少 hexdump，无法转换 DES 密钥。"
        return 1
    fi

    KEY_HEX="$(decode_base64_key_to_hex "$CRYPTO_B64")"
    if [ -z "$KEY_HEX" ]; then
        log "统一认证清理失败：无法把 croypto 转成 DES 密钥。"
        return 1
    fi

    ENCRYPTED_PASSWORD="$(openssl_des_encrypt_base64 "$KEY_HEX" "$LOGIN_PASSWORD")"
    if [ -z "$ENCRYPTED_PASSWORD" ]; then
        log "统一认证清理失败：DES 加密未返回结果。"
        return 1
    fi

    printf '%s' "$ENCRYPTED_PASSWORD"
}

fetch_sso_login_page() {
    ensure_workdir
    rm -f "$SSO_COOKIE_JAR" "$SSO_LOGIN_PAGE" "$SSO_CAPTCHA_META" "$SSO_DASHBOARD_HTML" "$SSO_ONLINE_LIST_JSON" "$SSO_OFFLINE_RESULT"

    curl -sS $SSO_CURL_FLAG -c "$SSO_COOKIE_JAR" -b "$SSO_COOKIE_JAR" "$SSO_LOGIN_URL" -o "$SSO_LOGIN_PAGE"
}

fetch_sso_captcha() {
    CAPTCHA_API="$SSO_BASE/cas/api/protected/user/findCaptchaCount/$LOGIN_ACCOUNT?$(date +%s)"
    CAPTCHA_PATH=""

    curl -sS $SSO_CURL_FLAG -c "$SSO_COOKIE_JAR" -b "$SSO_COOKIE_JAR" "$CAPTCHA_API" -o "$SSO_CAPTCHA_META" >/dev/null 2>&1
    CAPTCHA_PATH="$(extract_json_string_value "$SSO_CAPTCHA_META" "captchaUrl")"
    if [ -z "$CAPTCHA_PATH" ]; then
        CAPTCHA_PATH="api/captcha/generate/DEFAULT"
    fi

    case "$CAPTCHA_PATH" in
        http://*|https://*)
            CAPTCHA_URL="$CAPTCHA_PATH"
            ;;
        /*)
            CAPTCHA_URL="$SSO_BASE$CAPTCHA_PATH"
            ;;
        *)
            CAPTCHA_URL="$SSO_BASE/cas/$CAPTCHA_PATH"
            ;;
    esac

    curl -sS $SSO_CURL_FLAG -c "$SSO_COOKIE_JAR" -b "$SSO_COOKIE_JAR" "$CAPTCHA_URL" -o "$SSO_CAPTCHA_IMAGE"
}

prepare_sso_session() {
    log "开始准备统一认证登录页。"

    if ! fetch_sso_login_page; then
        log "统一认证清理失败：无法获取 CAS 登录页。"
        return 1
    fi

    SSO_EXECUTION="$(extract_html_id_text "$SSO_LOGIN_PAGE" "login-page-flowkey")"
    SSO_CRYPTO="$(extract_html_id_text "$SSO_LOGIN_PAGE" "login-croypto")"

    if [ -z "$SSO_EXECUTION" ] || [ -z "$SSO_CRYPTO" ]; then
        log "统一认证清理失败：未能从登录页提取 execution 或 croypto。"
        return 1
    fi

    if fetch_sso_captcha; then
        log "统一认证验证码已保存到: $SSO_CAPTCHA_IMAGE"
    else
        log "统一认证清理失败：验证码下载失败。"
        return 1
    fi

    return 0
}

submit_sso_login() {
    CAPTCHA_CODE="$1"
    ENCRYPTED_PASSWORD="$2"

    curl -sS $SSO_CURL_FLAG -L \
        -c "$SSO_COOKIE_JAR" \
        -b "$SSO_COOKIE_JAR" \
        -e "$SSO_LOGIN_URL" \
        --data-urlencode "username=$LOGIN_ACCOUNT" \
        --data-urlencode "type=UsernamePassword" \
        --data-urlencode "_eventId=submit" \
        --data-urlencode "geolocation=" \
        --data-urlencode "execution=$SSO_EXECUTION" \
        --data-urlencode "captcha_code=$CAPTCHA_CODE" \
        --data-urlencode "captcha_code=$CAPTCHA_CODE" \
        --data-urlencode "croypto=$SSO_CRYPTO" \
        --data-urlencode "password=$ENCRYPTED_PASSWORD" \
        "$SSO_LOGIN_URL" \
        -o "$SSO_DASHBOARD_HTML"
}

load_dashboard_page() {
    curl -sS $SSO_CURL_FLAG -c "$SSO_COOKIE_JAR" -b "$SSO_COOKIE_JAR" "$SELF_BASE/dashboard" -o "$SSO_DASHBOARD_HTML"
}

dashboard_login_ok() {
    grep -q 'Online List' "$SSO_DASHBOARD_HTML" 2>/dev/null \
        || grep -q 'dashboard/getOnlineList' "$SSO_DASHBOARD_HTML" 2>/dev/null
}

fetch_online_list() {
    curl -sS $SSO_CURL_FLAG -c "$SSO_COOKIE_JAR" -b "$SSO_COOKIE_JAR" \
        "$SELF_BASE/dashboard/getOnlineList?t=$(date +%s)" \
        -o "$SSO_ONLINE_LIST_JSON"
}

split_online_list_rows() {
    tr -d '\r\n' < "$SSO_ONLINE_LIST_JSON" | sed 's/},{/}\n{/g'
}

extract_row_field() {
    ROW="$1"
    KEY="$2"
    printf '%s\n' "$ROW" | sed -n "s/.*\"$KEY\":\"\\{0,1\\}\\([^\",}]*\\).*/\\1/p"
}

select_session_id() {
    SELECTED=""
    FIRST_FALLBACK=""

    while IFS= read -r ROW; do
        [ -z "$ROW" ] && continue
        SESSION_ID="$(extract_row_field "$ROW" "sessionId")"
        ROW_MAC="$(extract_row_field "$ROW" "mac")"

        if [ -z "$FIRST_FALLBACK" ] && [ -n "$SESSION_ID" ]; then
            FIRST_FALLBACK="$SESSION_ID"
        fi

        if [ "$OFFLINE_MATCH_MAC_FIRST" = "1" ] && [ -n "$NORMALIZED_MAC" ] && [ "$ROW_MAC" = "$NORMALIZED_MAC" ] && [ -n "$SESSION_ID" ]; then
            SELECTED="$SESSION_ID"
            break
        fi
    done <<EOF
$(split_online_list_rows)
EOF

    if [ -n "$SELECTED" ]; then
        printf '%s' "$SELECTED"
        return 0
    fi

    if [ -n "$FIRST_FALLBACK" ]; then
        printf '%s' "$FIRST_FALLBACK"
        return 0
    fi

    return 1
}

offline_session() {
    SESSION_ID="$1"

    curl -sS $SSO_CURL_FLAG -c "$SSO_COOKIE_JAR" -b "$SSO_COOKIE_JAR" -G \
        --data-urlencode "sessionid=$SESSION_ID" \
        --data-urlencode "t=$(date +%s)" \
        "$SELF_BASE/dashboard/tooffline" \
        -o "$SSO_OFFLINE_RESULT"
}

offline_result_ok() {
    grep -qi '"success"[[:space:]]*:[[:space:]]*true' "$SSO_OFFLINE_RESULT" 2>/dev/null \
        || grep -qi 'successfully' "$SSO_OFFLINE_RESULT" 2>/dev/null
}

handle_device_cleanup() {
    if [ "$ENABLE_DEVICE_CLEANUP" != "1" ]; then
        log "检测到设备超限，但已禁用统一认证清理流程。"
        return 1
    fi

    if ! prepare_sso_session; then
        return 1
    fi

    CAPTCHA_CODE="$(get_captcha_code_value)"
    if [ -z "$CAPTCHA_CODE" ]; then
        echo "检测到设备超限，已拉取统一认证验证码。"
        echo "验证码图片: $SSO_CAPTCHA_IMAGE"
        echo "把验证码写入 $SSO_CAPTCHA_CODE_FILE 后重新执行：sh $0 run"
        log "统一认证清理暂停：未提供验证码。请查看 $SSO_CAPTCHA_IMAGE，并将验证码写入 $SSO_CAPTCHA_CODE_FILE。"
        return 1
    fi

    log "开始提交统一认证登录。"
    ENCRYPTED_PASSWORD="$(encrypt_sso_password "$SSO_CRYPTO")" || return 1

    if ! submit_sso_login "$CAPTCHA_CODE" "$ENCRYPTED_PASSWORD"; then
        log "统一认证清理失败：CAS 登录请求发送失败。"
        return 1
    fi

    if ! load_dashboard_page; then
        log "统一认证清理失败：无法打开 Self dashboard。"
        return 1
    fi

    if ! dashboard_login_ok; then
        echo "统一认证登录未进入 Self 页面，可能是验证码错误或加密参数失效。"
        log "统一认证清理失败：未进入 Self dashboard，可能是验证码错误或登录参数失效。"
        return 1
    fi

    log "统一认证登录成功，开始获取在线设备列表。"
    if ! fetch_online_list; then
        log "统一认证清理失败：获取在线设备列表失败。"
        return 1
    fi

    SESSION_ID="$(select_session_id)"
    if [ -z "$SESSION_ID" ]; then
        log "统一认证清理失败：在线设备列表为空，未找到可下线的 sessionId。"
        return 1
    fi

    log "准备下线 sessionId=$SESSION_ID"
    if ! offline_session "$SESSION_ID"; then
        log "统一认证清理失败：下线请求发送失败。"
        return 1
    fi

    log "下线接口返回: $(tr -d '\r\n' < "$SSO_OFFLINE_RESULT")"
    if ! offline_result_ok; then
        log "统一认证清理失败：下线接口未返回成功。"
        return 1
    fi

    log "统一认证清理成功：已下线一个在线设备。"
    return 0
}

fetch_captcha_only() {
    if ! prepare_sso_session; then
        echo "验证码获取失败，请查看 $LOGFILE"
        return 1
    fi

    echo "统一认证验证码已保存到: $SSO_CAPTCHA_IMAGE"
    echo "把验证码写入: $SSO_CAPTCHA_CODE_FILE"
    return 0
}

run_login() {
    if ! mkdir "$LOCKDIR" >/dev/null 2>&1; then
        log "检测到已有登录任务正在运行，跳过本次执行。"
        return 0
    fi

    trap cleanup_lock EXIT INT TERM

    ensure_workdir

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

    echo "************** 开始执行登录 **************"
    echo "当前 IP: $LOGIN_IP"
    echo "当前 MAC: $NORMALIZED_MAC"
    echo "当前账号: $FINAL_USER_ACCOUNT"

    log "LOGIN_IP=$LOGIN_IP"
    log "WLAN_USER_MAC=$NORMALIZED_MAC"
    log "USER_ACCOUNT=$FINAL_USER_ACCOUNT"

    if ! perform_portal_login; then
        log "************** 登录结束 **************"
        return 1
    fi

    if [ "$LAST_RESULT_CODE" = "1" ] || is_success_message "$LAST_RESULT_MSG"; then
        log "Portal 返回成功: ${LAST_RESULT_MSG:-result=$LAST_RESULT_CODE}"
        finish_success
        return 0
    fi

    if needs_device_cleanup_message "$LAST_RESULT_MSG"; then
        log "Portal 返回设备超限，开始统一认证清理流程。"

        if handle_device_cleanup; then
            echo "设备清理完成，正在重试校园网登录。"
            log "设备清理完成，准备重试 Portal 登录。"

            if ! perform_portal_login; then
                log "设备清理后重试 Portal 登录失败。"
                log "************** 登录结束 **************"
                return 1
            fi

            if [ "$LAST_RESULT_CODE" = "1" ] || is_success_message "$LAST_RESULT_MSG"; then
                log "Portal 重试成功: ${LAST_RESULT_MSG:-result=$LAST_RESULT_CODE}"
                finish_success
                return 0
            fi

            log "设备清理后 Portal 仍失败，result=${LAST_RESULT_CODE:-unknown}，msg=${LAST_RESULT_MSG:-none}"
        else
            log "统一认证清理流程未完成。"
        fi
    fi

    echo "登录失败。"
    if [ -n "$LAST_RESULT_MSG" ]; then
        echo "失败信息: $LAST_RESULT_MSG"
    fi
    log "登录失败，result=${LAST_RESULT_CODE:-unknown}，msg=${LAST_RESULT_MSG:-none}"
    log "************** 登录结束 **************"
    return 1
}

startup_hook() {
    chmod +x "$0" >> "$LOGFILE" 2>&1
    log "开机启动触发，等待 $BOOT_WAIT 秒后执行登录。"
    sleep "$BOOT_WAIT"
    sh "$0" run >> "$LOGFILE" 2>&1 &
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
        fetch-captcha)
            fetch_captcha_only
            ;;
        cleanup)
            handle_device_cleanup
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
