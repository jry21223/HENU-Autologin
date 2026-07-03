# HENU-Autologin

河南大学校园网/运营商 portal 自动认证脚本，适用于路由器等设备通过校园网认证链路自动登录。

## 适用边界

本项目只处理校园网认证相关接口，例如：

- `http://172.29.35.27:8088/aaa-auth/api/v1/auth`
- `http://172.29.35.27:8882/user/check-only`
- `http://172.29.35.36:6060/quickauth.do`

本项目不处理图书馆预约系统的 CAS ticket、CASTGC、图书馆 token 或 `/v4/*` 预约接口。图书馆预约需单独适配 `ids.henu.edu.cn` 到 `zwyy.henu.edu.cn` 的 CAS 登录链路。

## 使用方法

在 OpenWrt/ImmortalWrt 路由器 SSH 中运行一键安装脚本。首次安装时用环境变量传入账号密码；后续重装会自动从 `/etc/campus_network/credentials.conf` 或旧脚本提取配置。

```bash
cd /tmp
wget -O install_openwrt.sh https://raw.githubusercontent.com/jry21223/HENU-Autologin/main/install_openwrt.sh
USERNAME='你的学号' PASSWORD='你的密码' sh install_openwrt.sh
```

如果路由器没有 `wget`，也可以把仓库里的 `install_openwrt.sh` 内容完整复制到 SSH 里执行。

脚本会写入：

- `/etc/campus_network/credentials.conf`
- `/etc/campus_network/auto_login.sh`
- `/etc/hotplug.d/iface/99-campus-auto-login`
- root crontab：每 5 分钟兜底执行一次

关键点：

- `aaa-auth` 和 `check-only` 请求都会带 `operatorSuffix=@henuyd`。
- 网络检查使用 HTTP 204/网页访问，不再只用 `ping`，避免 ICMP 放行时误判为已登录。
- `wwan ifup` 后会自动触发一次登录，开机时还有 cron 兜底。

如果只想手动运行已安装脚本：

```bash
/etc/campus_network/auto_login.sh
```

查看日志
```bash
cat /tmp/campus_network.log
```
