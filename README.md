# NJTechCampusNetAutoLogin

南京工业大学校园网路由器自动登录脚本
---

### 我的设备信息：

路由器：小米 AX3000T

系统版本：原厂固件 v1.0.84（已解锁 ssh）

------

### **以下为使用说明：**

### **`startup_script.sh`**
它会完成以下事情：
- 获取 WAN 口当前 IP
- 读取当前接口 MAC
- 组装校园网登录请求
- 发送登录请求
- 记录日志
- 在开机后等待一段时间自动执行

在 `startup_script.sh` 中，你需要先修改配置区里的这几项：

这里替换成你的学号：
```bash
LOGIN_ACCOUNT="${LOGIN_ACCOUNT:-202400000000}"
```

---

这里替换成你的校园网密码：

```bash
LOGIN_PASSWORD="${LOGIN_PASSWORD:-password}"
```

---

运营商`cmcc/telecom` 对应中国移动/中国电信
```bash
ACCOUNT_SUFFIX="${ACCOUNT_SUFFIX:-@cmcc}"
```

---

这里是路由器 WAN 口接口名

我的 AX3000T 原厂固件里 WAN 口接口名是 `eth0.1`，

```bash
NET_IFACE="${NET_IFACE:-eth0.1}"
```

如果你的路由器使用的 WAN 口不同，请先用下面命令确认：

```bash
ip route get 10.50.255.11
```

------


之后输入以下内容赋予运行权限：

```bash
chmod +x /data/startup_script.sh
```

之后运行脚本进行测试：

```bash
sh /data/startup_script.sh run
```

脚本运行后会在同目录下生成：

- `autoLogin.log`
- `login_result.txt`

其中：

- `autoLogin.log` 用于记录完整登录过程
- `login_result.txt` 用于保存 portal 的原始返回内容

成功登录时，`login_result.txt` 中可能看到如下内容：

```bash
dr1003({"result":1,"msg":"Portal协议认证成功！"});
```

如果当前 IP 已经在线，也可能看到如下内容：

```bash
dr1003({"result":0,"msg":"IP: 10.40.21.63 已经在线！","ret_code":2});
```

这两种情况在当前脚本里都会被视为成功。

---

如果你想移除开机启动，可以执行：

```bash
sh /data/startup_script.sh uninstall
```

------
**由于小米原厂固件限制，`/root` 文件夹只读，所以我把脚本放在了 `/data` 目录下。如果你要更改放置位置，请自行替换脚本中的 `/data` 路径。**

### 有问题或者建议欢迎在 issue 中讨论，或者添加我的 QQ 3287554459
