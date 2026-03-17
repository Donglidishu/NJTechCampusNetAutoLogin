#!/bin/sh
# autoLogin.sh
# -----------------------------------------------
# 1) 获取当前 IP (eth0.1)，多次尝试
# 2) 用 sed 将 __IP__ 替换为真实 IP
# 3) 执行 /data/login.sh
# -----------------------------------------------

LOGFILE="/data/autoLogin.log"

echo "************** 开始自动登录流程 **************" >> "$LOGFILE"
echo "当前时间: $(date)" >> "$LOGFILE"

# 1) 复制“干净”模板
cp /data/login_base.sh /data/login.sh
echo "已复制 login_base.sh 到 login.sh" >> "$LOGFILE"

# 2) 多次尝试获取 IP
MAX_TRIES=5        # 最大尝试次数
TRY=1              # 当前尝试次数
SLEEP_TIME=10      # 每次尝试之间的等待时间（秒）
IP=""

while [ $TRY -le $MAX_TRIES ]; do
    echo "尝试 $TRY: 获取 IP 地址..." >> "$LOGFILE"
    # 获取 IP 地址，假设接口名为 eth0.1
    IP=$(ip addr show eth0.1 | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    
    if [ -n "$IP" ]; then
        echo "成功获取到 IP: $IP" >> "$LOGFILE"
        break
    else
        if [ $TRY -lt $MAX_TRIES ]; then
            echo "未能获取到 IP，等待 $SLEEP_TIME 秒后重试..." >> "$LOGFILE"
            sleep $SLEEP_TIME
        else
            echo "未能获取到 IP，已达到最大尝试次数，不再等待。" >> "$LOGFILE"
        fi
    fi
    
    TRY=$((TRY + 1))
done

# 检查是否成功获取到 IP
if [ -z "$IP" ]; then
    echo "错误: 未能在 $MAX_TRIES 次尝试后获取到 IP 地址，退出脚本。" >> "$LOGFILE"
    exit 1
fi

# 3) 用 sed 将 __IP__ 替换为真实 IP
sed -i "s|__IP__|${IP}|" /data/login.sh
echo "已将 login.sh 中的 __IP__ 替换为 $IP" >> "$LOGFILE"

# 4) 执行 login.sh
echo "开始执行 /data/login.sh" >> "$LOGFILE"
sh /data/login.sh >> "$LOGFILE" 2>&1
echo "login.sh 执行完毕" >> "$LOGFILE"


echo "************** 自动登录流程结束 **************" >> "$LOGFILE"
