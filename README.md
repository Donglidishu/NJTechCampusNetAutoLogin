# NJTechCampusNetAutoLogin

南京工业大学校园网路由器自动登录脚本

泥工的校园网在每次熄灯之后来电，有线设备需要重新进行手动登录，并不像WiFi一样有无感登录，这导致每天还得重新登录一遍路由器才可以正常上网

一开始找到的现有的脚本来自GitHub上一位学长/学姐上传的脚本:

[Njtech-AutoLogin/路由器openwrt版](https://github.com/zqzess/Njtech-AutoLogin/tree/main/路由器openwrt版)

可能是时间太久，校园网登录策略有改变，不能直接使用了，于是重新摸索解决方法

---

### 我的设备信息：

路由器：小米AX3000T

系统版本：原厂固件 v1.0.84 （已解锁ssh）

------

### **以下为使用说明：**

在脚本运行时，autoLogin.sh会将login_base.sh中的模版复制到login.sh中，使wlan_user_ip恢复到占位符，以便替换获取到的ip

### *1.**`login_base.sh`***  

在login_base.sh中：

```bash
LOGIN_URL="http://10.50.255.11:801/eportal/portal/login?callback=dr1003&login_method=1&user_account=,1,202400000000@telecom&user_password=1234567890&wlan_user_ip=__IP__&wlan_user_ipv6=&wlan_user_mac=000000000000&wlan_ac_ip=&wlan_ac_name=&jsVersion=4.1.3&terminal_type=1&lang=zh-cn&v=1640&lang=zh"
```

此段链接包含你的登录信息，以及登录方式，需要自行修改，你需要注意如下几个部分：

```bash
user_account=,1,202400000000@telecom
```

`1`表示运营商为中国电信  `0`表示中国移动

如果你填入`0`请将后面的 `telecom `改成 `cmcc`

`202400000000`此处替换成你的学号

```bash
user_password=1234567890
```

你的密码

```bash
wlan_user_mac=000000000000
```

此处填入你路由器的mac地址

### *2.`autoLogin.sh`*

在此文件中：

```bash
# 获取 IP 地址，假设接口名为 eth0.1
IP=$(ip addr show eth0.1 | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
```

此处我的路由器wan口接口名为eth0.1，请自行查询你的wan口接口名称并替换

------

> [!NOTE]
>
> 首次使用，请将你编辑好的`login_base.sh`的内容复制到`login.sh`中

> [!CAUTION]
>
> 由于小米原厂固件限制，`/root`文件夹只读，所以我把三个.sh文件全部放置在了`/data`目录下，如果你要更改放置的位置，请自行替换脚本中`/data`为你想要的路径

之后，依次输入以下内容赋予运行权限：

```bash
chmod +x /data/autoLogin.sh
chmod +x /data/login.sh
chmod +x /data/login_base.sh
```

之后运行脚本进行测试

```bash
sh /data/autoLogin.sh
```

查看同目录下产生的`runlog.txt` `autoLogin.log` `login_result.txt` 查看运行结果

成功登录时`runlog.txt`中最后应当是以下内容：

```bash
dr1003({"result":1,"msg":"Portal协议认证成功！"});[2025-01-07 22:50:12] 登录成功，网络已通。
```

------

## 开机自动运行

如果你和我一样是小米原厂固件，无法通过编辑rc.local来进行开机运行脚本，那么你可以参照以下帖子的前半部分创建自动开机脚本

[**小米官方固件添加自启动脚本方法**](https://www.right.com.cn/forum/forum.php?mod=viewthread&tid=8340357)

在你创建好的 `startup_script.sh` 中，你需要将`startup_script()`修改为以下内容：

```bash
startup_script() {
        # Put your custom script here.
        echo "Starting custom scripts..." >> /data/autoLogin.log
        echo "Start time: $(date)" >> /data/autoLogin.log

        chmod +x /data/autoLogin.sh >> /data/autoLogin.log 2>&1
        chmod +x /data/login.sh >> /data/autoLogin.log 2>&1
        chmod +x /data/login_base.sh >> /data/autoLogin.log 2>&1
        
        echo "Permissions set." >> /data/autoLogin.log

        sleep 90
        echo "Executing autoLogin.sh..." >> /data/autoLogin.log
        sh /data/autoLogin.sh >> /data/autoLogin.log 2>&1 &
}
```

### 有问题或者建议欢迎在issue中讨论，或者添加我的QQ3287554459

