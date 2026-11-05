# OpenWrt 25.12.0 隔离初始化验收（#17）

实测日期：2026-11-05。下表列实际投放版本；各归档由相应 `git archive COMMIT routepolicy/files` 生成。

| 范围 | 实测提交 |
| --- | --- |
| 单臂管理变更、真实SSH及包级/DNS/双出口报文 | `196dad2bfc7e81a20daf490845946c85a975fac0` |
| 单臂仅新增验证器的只读verify；分离拓扑全量及提交/重载/超时/所有权恢复 | `2b48d8ac073421d857a2b3636e7fff8bbd4f52f6` |
| 原生 DOWN 静态出口、显式恢复与真实 SSH 确认分支 | `f53c73d363d90b8dbc21b7f5e3244233ddca3097` |
| 最终 DAD 冲突/进程终止、pending 跨 boot、新 DHCP 出口 | `c9e8bf2a2c0187d36bf866e3b74aa8775eca62ce` |

早期 ARP/rp_filter/陈旧提交只读用例实测于 `e7d1c5e8e70d16460b07e95cbeabbf6c87b8ec05`。其后的 `0a8ef25ddc500868872639fedde3da06b3586e09` 仅保留原 DAD 失败阶段/错误，由主流程回归测试验证；没有重复相同真实回滚节点。

## 环境与复现入口

官方 [25.12.0 x86/64 ext4 镜像目录](https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/) 的 `openwrt-25.12.0-x86-64-generic-ext4-combined.img.gz`，按同目录 `sha256sums` 校验后启动。guest 实报 r32713-f919e7899d、kernel 6.12.71、netifd 2026.02.26~cbb83a18-r1。

WSL Ubuntu、QEMU 8.2.2 / TCG、256 MiB DUT / 192 MiB client、qcow2 快照、UNIX 带外串口；all及受管设备rp_filter基线0并保留。归档经回环 HTTP 投放至 guest 根；工具来自官方 feed：flock、coreutils-timeout、iputils-arping、ip-full、curl、tcpdump。APK 构建与既有分流/SmartDNS 独立管理回归由主流程另行给证据。

| 角色 | 分离拓扑 | 单臂拓扑 |
| --- | --- | --- |
| 接入/管理 | lan / br-lan(eth1)，192.168.1.1/24 | lan / br-lan(eth0+eth1)，10.17.1.15→10.17.1.16/24 |
| 默认出口 | wan / eth0，DHCP 10.17.1.15/24，gw 10.17.1.2 | 与接入共用 lan / br-lan，gw 10.17.1.2 |
| 策略出口 | policy / eth2，DHCP 10.17.2.15/24，gw 10.17.2.2 | 同左 |
| 非受管 LAN | other / eth3，192.0.2.1/24，DHCP 100–119 / 1h | 同左 |

DUT eth0/eth2 分别接 user/slirp `10.17.1.0/24` / `10.17.2.0/24`；eth1/eth3 分别 socket listen `127.0.0.1:21701/21702`，client 两块 e1000 对应 connect。client 接入地址固定 `.99`，other 口仅探测；DHCP 探测使用 `-s /bin/true`，不应用租约。HTTP 目标监听 `127.0.0.1:21799`，两个 slirp 地址 `.2` 均可访问同一 `probe.txt`。WAN hostfwd 仅回环：默认 TCP 21722→22、21780→80 / UDP 21753→53；策略 TCP 21723→22、21781→80 / UDP 21754→53。没有 TAP、物理桥接或真实路由器。

下面选一条 prepare；确认命令在新 SSH 会话内重新读取 token。

```sh
T=/usr/libexec/routepolicy/init-transaction
$T prepare lan wan policy - - - - - - - - >/tmp/prepare.json  # 分离
$T prepare lan lan policy - - - - - - 10.17.1.16 24 >/tmp/prepare.json  # 单臂，换管理入口
# 新卡用例：从快照 ifdown policy、删除 network.policy，eth2 无 IP/admin-DOWN
$T prepare lan wan rp_init_policy policy eth2 dhcp - - - - - >/tmp/prepare.json
$T prepare lan wan rp_init_policy policy eth2 static 10.17.2.9 24 10.17.2.2 - - >/tmp/prepare.json
token=$(jsonfilter -i /tmp/prepare.json -e '@.token')
$T apply "$token"
/usr/libexec/routepolicy/init-transaction confirm "$(jsonfilter -i /tmp/prepare.json -e '@.token')"  # 新SSH会话
```

以上为互斥场景，分别从对应干净快照开始。实测 `apply→pending`、实际 client SSH 确认后 `confirmed`；未伪造 `SSH_CONNECTION`。全程配置 `routepolicy.main.enabled=0`，没有开启既有分流应用。

## 服务与报文观测

```sh
udhcpc -i br-lan -n -q -t 3 -T 2 -s /bin/true
odhcp6c -s /bin/true -t 1 br-lan  # 受控4秒窗口后终止
nslookup example.com MANAGEMENT_IP
wget -T 5 -qO- http://10.17.1.2:21799/probe.txt
wget -T 5 -qO- http://10.17.2.2:21799/probe.txt
ubus call network.interface.policy renew  # 新卡换 rp_init_policy；默认出口用 wan
```

抓包用 `tcpdump -U -ni DEVICE -w FILE ...`，等待日志明确 `listening on` 后发送探测；结束后 `tcpdump -nn -vv -r FILE`。比对 UCI 用四包 `uci show | sort`；规则用 `nft -s list ruleset`，不计算额外文件 hash。

| 检查 | 实际结果 |
| --- | --- |
| 只读预检/预览 | network/dhcp/firewall 文件与 nft 语义前后 cmp0；最终 DOWN preview 仍0x1002/无4、6地址，明确 pending-link-up，四包与 nft cmp0 |
| 接入 DHCPv4 | 初始真实 Discover→Offer→Request→ACK；初始化后分离3次 Discover 无 Offer。单臂只有外部10.17.1.2回应 |
| 本机 RA/DHCPv6 | 实际 RS、Solicit/Information-request 已发；按本机 MAC 和服务端口/RA类型过滤回应为0。单臂外部 fe80::2/fec0::/64 RA及外部 DHCPv6 仍可见 |
| 其他 LAN / 出口 DHCP | other 实得192.0.2.110/3600秒。分离 WAN、policy及单臂policy均实际 Request→ACK /86400秒 |
| DNS / 双出口转发 | 经管理地址解析 openwrt.lan、example.com；两个 HTTP 均返回约定正文，fw4 forwarding/MASQUERADE计数命中。单臂另加 `10.17.1.2/32 via 10.17.1.16` 排除直接上游旁路，出口源分别为.16与10.17.2.15 |
| WAN 管理/DNS隔离 | 对两 WAN hostfwd 发真实 SSH/HTTP/DNS；TCP关闭无banner、DNS超时；LAN SSH与DNS为正控制 |
| IPv6 | 显式测试路由强制新 IPv6 流经本机，拒绝规则0→1包/104字节；link-local ping及真实SSH管理仍成功，不把一次超时当规则证据 |
| 预检门禁/幂等 | 原生UCI私有delta、真实commit、list/scalar恢复合约通过；实际 rp_filter max门禁、已占用管理.99的ARP拒绝、外部提交后陈旧基线拒绝均通过；重复apply新interface/zone仍各1 |

## 故障、所有权与新卡

故障均为一次性固定节点注入，仅操作本实验。服务脚本注入后恢复原文件；持久 UCI 从未用整包 import/旧文件覆盖。

| 条件 | 观测 |
| --- | --- |
| 首个 firewall commit、提交后第二次 fw4 check | 各 RC1/rolled_back，failed_stage分别 commit / firewall-check，四包cmp0 |
| firewall reload、dnsmasq reload | 各 RC1/rolled_back，四包与原服务脚本cmp0；实测2b48原诊断为service-reload，后续已细化服务名 |
| 原调用结束且120秒未确认 | deadline+1秒独立procd已rolling_back，最终rolled_back、原干净四包cmp0/fw4有效 |
| commit时SIGKILL / applying时冷启动 | RC137或原进程消失；没有手动recover，守卫恢复rolled_back、四包cmp0、管理.1与有效fw4，无永久锁 |
| 外部修改冲突 | 候选管理.2应用后，外部提交.3/24与other租期2h；recover明确conflict=network.lan.ipaddr，实际SSH/DNS经.3可用，other实得7200秒。消除指定字段冲突后恢复.1，外部2h仍保留 |
| 原生DOWN static成功/显式恢复（f53） | pending时实际10.17.2.9/24、gw2、metric200；recover后DOWN0x1002/无4、6地址/四包cmp0/fw4有效，无异步claim误报。pending快照另一分支真实SSH确认、HTTP成功并保持UP |
| 真DAD冲突（c9） | 占用10.17.2.3实际Unicast reply；探测时0x1003且无IPv4，RC1，UCI attempted=0，rolled_back/DOWN0x1002/四包cmp0 |
| DAD时SIGKILL（c9） | 精准终止本次apply，RC137；零UCI尝试，独立guard恢复DOWN/rolled_back/cmp0 |
| pending跨真实boot（c9） | boot-id变化；uptime26.85秒即rolling_back，比原deadline早46秒；64.79秒rolled_back，仍早7秒。DOWN/无IP/四包cmp0/fw4有效；同版pending快照另一分支真实SSH确认及HTTP通过 |
| 新DHCP接口（c9） | 从DOWN自动创建rp_init_policy，实际10.17.2.15/24、gw2、metric200/peerdns0，新zone为REJECT/ACCEPT/REJECT；SSH confirmed、HTTP成功，ready后renew抓同xid Request→ACK，ACK_COUNT=1/86400秒；重复apply接口/zone各1 |

快照分支使用 QEMU monitor `savevm NAME` / `loadvm NAME`；重启用 `system_reset`。早期 `-no-reboot` 导致guest退出时，以同一磁盘/4网卡冷启动；最终 pending 用例在同一QEMU进程内真实重启。关键干净快照包括 `singlearm-full-baseline`、`free-nic-2b48`（原生DOWN）、`free-nic-f53`、`free-nic-c9`；pending快照只在其自身版本完成确认/恢复，未热替换旧pending守卫。

边界：没有真实物理/USB/无线驱动、设备热拔插或生产网络验证；外部设备认领、改MAC/ifindex、同名替换等异常仅有边界测试，未逐项做真实硬件故障。外部RA/已有IPv6 conntrack与外部终端/主路由设置不宣称已阻断或已修改。所有地址/MAC/租约及SSH密钥仅为隔离实验数据。

清理：两台自建 guest 与回环 HTTP 服务均已关闭，未关闭 WSL 或其他任务进程。
