# HENU-Autologin

河南大学校园网/运营商 portal 自动认证脚本，适用于 OpenWrt / ImmortalWrt 路由器等设备在校园网环境下自动登录。

## 适用边界

本项目只处理校园网认证相关接口，例如：

- `http://172.29.35.27:8088/aaa-auth/api/v1/auth`
- `http://172.29.35.27:8882/user/check-only`
- `http://172.29.35.36:6060/quickauth.do`

本项目不处理图书馆预约系统的 CAS ticket、CASTGC、图书馆 token 或 `/v4/*` 预约接口。图书馆预约需单独适配 `ids.henu.edu.cn` 到 `zwyy.henu.edu.cn` 的 CAS 登录链路。

## 安装方式

### 方式一：离线复制安装脚本

适合路由器还没通过校园网认证、无法直接访问外网时使用。

在本机把仓库里的 `install_openwrt.sh` 复制到路由器：

```bash
scp install_openwrt.sh root@192.168.1.1:/tmp/install_openwrt.sh
```

然后 SSH 到路由器执行：

```bash
USERNAME='你的学号'
PASSWORD='你的密码'
OPERATOR_SUFFIX='@henuyd'
CAMPUS_CODE='07cdfd23373b17c6b337251c22b7ea57'
sh /tmp/install_openwrt.sh
```

### 方式二：已有网络时直接下载

```bash
wget -O /tmp/install_openwrt.sh https://raw.githubusercontent.com/jry21223/HENU-Autologin/main/install_openwrt.sh
USERNAME='你的学号' PASSWORD='你的密码' sh /tmp/install_openwrt.sh
```

## 安装后生成的文件

脚本会写入：

```text
/etc/campus_network/auto_login.sh
/etc/campus_network/credentials.conf
/etc/hotplug.d/iface/99-campus-auto-login
/tmp/campus_network.log
```

其中 `credentials.conf` 权限会设置为 `600`，用于保存校园网账号、密码、运营商后缀和校区代码。

## 触发机制

安装后会配置三类触发：

- 开机后延迟运行一次。
- `wwan` 接口 `ifup` 后延迟运行一次。
- cron 每 5 分钟检查一次网络状态，未联网时重新认证。

## 当前修复点

- `wget --post-data` 发送表单前会对账号、密码、运营商后缀、校区代码做 URL encode，避免密码里含 `&`、`=`、`+`、`%`、空格等字符时破坏表单。
- portal 第三步 GET query 也会编码 `userid`、`passwd`、`wlanuserip`、`uuid`。
- lock 目录退出时会先删除 `pid` 文件再 `rmdir`，避免正常退出后留下非空 lock 目录。
- stale lock 判断会校验 pid 是否为纯数字，降低误判风险。

## 手动检查

安装后可以执行：

```bash
/etc/campus_network/auto_login.sh manual
tail -n 80 /tmp/campus_network.log
```

如果认证失败，优先检查：

- 账号是否需要运营商后缀。
- `OPERATOR_SUFFIX` 是否正确，例如 `@henuyd`。
- `CAMPUS_CODE` 是否仍适用于当前校区/网络。
- 路由器是否已经拿到默认路由和 WAN IP。
