# Linux SNAT Manager

<img width="748" height="751" alt="image" src="https://github.com/user-attachments/assets/8356fc78-4308-412d-9a2c-c3bff1413279" />

一个用于 Linux 服务器的 SNAT / NAT / 端口放行管理脚本。

支持：

- SNAT 配置
- VPN 出口转发
- 端口放行
- IPv4 转发
- nftables / iptables
- firewalld / ufw
- 自动持久化
- 多 Linux 发行版

适用于：

- [飞将VPN](www.feijiangkeji.com)
- OpenVPN
- WireGuard
- IPsec
- SoftEther
- Docker 网络
- VPS 出口转发
- VPN 服务器部署
- 多网卡 NAT 转发

---

# 功能特性

## 自动检测系统

支持：

- Debian
- Ubuntu
- CentOS
- RHEL
- Rocky Linux
- AlmaLinux
- Fedora
- Arch Linux
- Alpine Linux

以及大部分衍生发行版。

---

## 自动检测防火墙后端

支持：

- iptables
- nftables
- firewalld
- ufw

自动识别并适配当前系统。

---

## 自动配置 IPv4 转发

自动开启：

```bash
net.ipv4.ip_forward=1
```

无需手动修改。

---

## 支持 VPN 出口 NAT

适用于：

- tun0
- wg0
- ppp0
- ipsec
- docker
- 任意自定义接口

自动完成：

- FORWARD
- MASQUERADE
- SNAT
- 端口放行

---

## 自动持久化

系统重启后规则自动恢复。

支持：

| 后端 | 持久化 |
|------|------|
| iptables | iptables-save |
| nftables | nft ruleset |
| firewalld | permanent |
| ufw | rules 文件 |

---

# 支持系统

## Debian 系

- Debian
- Ubuntu
- Kali Linux
- Linux Mint
- Proxmox VE
- Deepin
- Pop!_OS
- Armbian

---

## RHEL 系

- CentOS
- Rocky Linux
- AlmaLinux
- Fedora
- Oracle Linux
- TencentOS
- OpenCloudOS

---

## 其它

- Alpine Linux
- Arch Linux
- Manjaro

---

# 支持的 Init 系统

- systemd
- OpenRC

---

# 支持的网络接口

支持任意 Linux 网卡：

```text
eth0
ens18
ens192
enp1s0
wlan0
tun0
wg0
ppp0
docker0
```

---

# 安装

## 1. 下载脚本

```bash
wget -O snat.sh https://raw.githubusercontent.com/yangpin97/snat/refs/heads/main/snat.sh
```

或者：

```bash
curl -o snat.sh https://pan.yydy.link:2023/d/share/script/snat.sh
```

或者：

```bash
curl -o snat.sh https://www.feijiangkeji.com/assets/uploads/snat.sh
```

---

## 2. 添加执行权限

```bash
chmod +x snat.sh
```

---

## 3. 运行脚本

```bash
sudo ./snat.sh
```

---

# 使用说明

运行后会自动：

- 检测系统
- 检测防火墙
- 检测网卡
- 检测 IPv4 转发状态

然后进入菜单。

---

# 菜单功能

## SNAT 配置

用于：

- VPN 客户端上网
- 内网 NAT
- 出口转发

自动添加：

```bash
MASQUERADE
SNAT
FORWARD
```

---

## 端口放行

支持：

- TCP
- UDP
- 单端口
- 端口范围

例如：

```text
80
443
10000-20000
```

---

## 删除规则

支持：

- 删除 SNAT
- 删除 FORWARD
- 删除端口规则

---

## 查看规则

显示当前：

- iptables
- nftables
- firewalld
- ufw

规则状态。

---

# VPN 使用示例

## OpenVPN

```text
tun0 -> eth0
```

客户端流量自动 NAT 出口。

---

## WireGuard

```text
wg0 -> ens18
```

自动配置：

- FORWARD
- MASQUERADE

---

## IPsec

适用于：

- strongSwan
- libreswan
- Cisco IPsec

---

# 持久化说明

脚本会自动检测并使用：

| 系统 | 方式 |
|------|------|
| Debian/Ubuntu | iptables-persistent |
| RHEL | service save |
| nftables | /etc/nftables.conf |
| firewalld | permanent |
| ufw | before.rules |

---

# 兼容性说明

推荐系统：

| 系统 | 推荐度 |
|------|------|
| Debian 12 | ⭐⭐⭐⭐⭐ |
| Ubuntu 22.04+ | ⭐⭐⭐⭐⭐ |
| Rocky Linux 9 | ⭐⭐⭐⭐⭐ |
| AlmaLinux 9 | ⭐⭐⭐⭐⭐ |
| Fedora | ⭐⭐⭐⭐ |
| Alpine | ⭐⭐⭐ |
| Arch | ⭐⭐⭐ |

---

# 注意事项

## 必须使用 root

推荐：

```bash
sudo ./snat.sh
```

---

## 云服务器安全组

如果使用：

- AWS
- Azure
- GCP
- 阿里云
- 腾讯云

请确保：

- 已放行对应端口
- 已允许转发流量

---

## VPS NAT 问题

某些 VPS 厂商：

- 禁止 MAC spoof
- 禁止转发
- 禁止多 IP

请确认服务商策略。

---

# 已测试环境

- Debian 12
- Ubuntu 22.04
- Ubuntu 24.04
- CentOS 7
- Rocky Linux 9
- AlmaLinux 9
- Alpine 3
- Arch Linux

---

# License

MIT License

---

# Star History

如果这个项目对你有帮助，欢迎 Star ⭐
