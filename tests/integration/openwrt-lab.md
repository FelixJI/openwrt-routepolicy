# OpenWrt 25.12 隔离实验室

启动器用同一份官方原始镜像创建两块全新的 qcow2 写时复制磁盘：一台待测路由器（DUT）和一台真实客户端。它只启动环境。安装、配置和验收均由测试者操作，启动成功只表示夹具已监听。

## 启动

在 Linux 或 WSL 中使用 Python 3.9+、支持网络命名空间及 pidfd 的内核、`unshare`、`ip`、`qemu-img` 和 `qemu-system-x86_64`。从 [OpenWrt 官方发布目录](https://downloads.openwrt.org/releases/) 选取同一目录中的 25.12.x x86/64 `generic-ext4-combined.img.gz` 与 `sha256sums`。调用者先用官方摘要核验下载的压缩镜像；不匹配或缺少对应条目就停止。解压到普通文件，实验期间不要移动或修改该 raw 文件。启动参数 `--verified-openwrt-raw` 是调用者的核验声明；脚本只识别磁盘格式。

在仓库根目录运行，替换两条示例路径：

```sh
LAB="$PWD/tests/integration/openwrt-lab.py"
BASE=/var/tmp/openwrt-25.12.1-x86-64-generic-ext4-combined.img
WORK=/var/tmp/routepolicy-lab-clean-01
sudo python3 -I "$LAB" start --base "$BASE" --work-dir "$WORK" \
  --user "$(id -un)" --verified-openwrt-raw
```

`BASE` 必须是当前用户可读的绝对路径。选用由当前用户控制或可安全创建子目录的位置；`WORK` 必须尚不存在，父目录必须已存在。路径不能含逗号、控制字符或符号链接；保持工作路径简短以容纳 UNIX socket。root 只建立网络命名空间并配置其回环，随后降权；磁盘、日志和所有监听进程归当前非 root 用户。同一命名空间中只有回环，无 IPv4/IPv6 默认路由；没有 TAP、物理桥接或对宿主路由的修改。

保留启动终端，另开一个 Linux shell，设置同样的 `LAB` 和 `WORK`。脚本报告监听就绪后，guest 还需时间完成启动。用串口检查引导、网卡和 UCI：

```sh
python3 "$LAB" console --work-dir "$WORK" dut 'ip link; uci show network'
python3 "$LAB" console --work-dir "$WORK" client 'ip -4 addr; ip -4 route'
```

串口每次接收一条显式 shell 命令，默认等待退出 120 秒，可用 `--timeout` 缩短或延长到 240 秒。一次只允许一个调用。超时不会中断 guest 内仍在运行的命令；先查看 UART 日志。较长的脚本可放到 `$WORK/served/`，从 guest 下载后按需运行。该 HTTP 目录仅用于测试输入，勿放凭据。

## 分离拓扑校准

按 MAC 核对 guest 中的接口名；不要把枚举顺序当作已验证的配置。串口和 monitor 位于 `$WORK/{dut,client}.{serial,monitor}`。

| guest | 预期接口与 MAC 后缀（前缀 `52:54:00:21:`） | 链路 |
| --- | --- | --- |
| DUT | eth0 / `00:00` | LAN，socket 监听命名空间回环 `127.0.0.1:21821` |
| DUT | eth1 / `00:01` | 默认出口，slirp `10.21.1.0/24` |
| DUT | eth2 / `00:02` | 独立策略出口，slirp `10.21.2.0/24` |
| client | eth0 / `01:01` | 与 DUT LAN 连接 |
| client | eth1 / `01:02` | 控制口，slirp `10.21.3.0/24`；命名空间内 `127.0.0.1:21822` 转发至此口 SSH |

在 DUT 以 `uci show network`、`ip link` 和 `ubus call network.interface.wan status` 核对初始配置：`lan` 的 `br-lan` 只接 eth0、地址为 `192.168.1.1/24`；`wan` 是 eth1 上的 DHCP，默认网关来自 `10.21.1.2`。如官方初始映射不同，只在 DUT 串口调整接口与桥的归属，例如确认 eth1 已移出 LAN 桥后设 `network.wan.device='eth1'`、`network.wan.proto='dhcp'`，提交 network 并重载。保留 DUT 出厂 LAN DHCP、RA 和 DHCPv6，先抓其正常回应，再运行被测初始化流程。自由网卡用例中 eth2 始终留空给被测流程；已有策略口用例中才预先为其建立所需的 UCI 接口。

client 的 LAN 使用 `192.168.1.2/24`，默认网关和 DNS 都是 `192.168.1.1`。不要用 client 默认自带的 DHCP/RA 回答来冒充 DUT 的回应。若接口与默认配置名相符，在 client 串口执行以下校准：

```sh
uci set network.lan.ipaddr='192.168.1.2/24'
uci -q delete network.lan.netmask
uci set network.lan.gateway='192.168.1.1'
uci -q delete network.lan.dns
uci add_list network.lan.dns='192.168.1.1'
uci set network.wan.device='eth1'
uci set network.wan.proto='dhcp'
uci set network.wan.defaultroute='0'
uci set network.wan.peerdns='0'
uci -q delete network.wan6
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci commit network
uci commit dhcp
/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart
```

用 `ip -4 route` 确认只有 LAN 的默认出口，控制网段仍直连。client 启动时的默认服务可能已经产生报文，DNS、RA 和 DHCP 的对照从校准完成后重新取样。控制口转发只建立 QEMU 入口；需要用它时，还要在 client 单独启用仅供实验的 SSH 认证和控制口防火墙规则。需要确认 DUT 的初始化事务时，从 client 发起一条新的真实 DUT LAN SSH 会话；不要伪造 `SSH_CONNECTION`。若测试要将 DUT 管理地址改为 `.2`，先把 client 移到同网段的未占用地址，例如 `.99/24`。

## 单臂拓扑

另建空工作目录，从官方 raw 重新启动，保留上一组证据。在 DUT 串口撤除 eth1 上的独立 `wan` 和 `wan6` 绑定，把 eth0（client 接入）与 eth1（默认上游）并入同一个 `br-lan`。让两者共用静态 `lan`：例如 DUT `10.21.1.16/24`、默认网关 `10.21.1.2`，client `10.21.1.99/24`、网关和 DNS `10.21.1.16`。client 控制口仍保持 `defaultroute=0`、`peerdns=0`，DUT eth2 仍作独立策略出口。初始化时接入和默认接口均选 `lan`；在该版本中核对实际命令参数。选非直连业务目标，让其经过 DUT，并在抓包中按源 MAC 区分外部上游与 DUT 的 DHCP/RA。此节给出搭建方法；启动器本身不执行或验收单臂配置。

## 受控服务和取证

`$WORK/served/` 由命名空间回环 HTTP 21799 提供。将自备 APK、索引或测试脚本复制到该目录。guest 通过各自 slirp 的 `.2:21799` 按文件路径下载。服务只提供普通文件，符号链接和目录请求返回 404。使用既有的官方签名验证流程准备离线材料。

`controlled-services.py` 随环境启动，监听配置在命名空间回环上的两个 DNS 地址（TCP/UDP 25353）及业务 HTTP 18080。

| 角色 | 受控地址 | 用法 |
| --- | --- | --- |
| 默认 DNS | `198.18.0.1:25353` | `*.lab19.test` 的 A 查询返回默认业务地址 |
| 策略 DNS | `203.0.114.1:25353` | 同域 A 查询返回策略业务地址；`rules.lab19.test` 两边均返回默认地址 |
| 默认业务 | `203.0.114.17:18080` | 默认出口对照 |
| 域名策略业务 | `203.0.115.18:18080` | 策略 DNS 回答的远端地址 |
| 静态策略业务 | `203.0.115.19:18080` | 不依赖 DNS 的独立策略目标 |

把 DNS 地址配置到此次实验的默认和策略上游组。测试者可在 `$WORK/services/` 创建空的 `blocked-policy` 或 `blocked-default` 模拟对应组无响应，删除该标记恢复；夹具会记录探测和阻断。用 `dns.jsonl`、`business.jsonl` 及 DUT 的 `lan.pcap`、`wan.pcap`、`policy.pcap` 交叉确认实际 DNS 请求与业务出口。HTTP 返回 200 本身不能证明出口正确。保留 `evidence/isolation.json`（镜像来源、boot ID、命名空间、链路、路由、各进程 PID 与实际 argv）、UART 和进程日志。隔离环境的初始化断言和历史实测另见 [#17 复现记录](init-openwrt-25.12.0.md)。

## 停止

在启动终端按 Ctrl+C，或由同一非 root 用户运行：

```sh
python3 "$LAB" stop --work-dir "$WORK"
```

停止命令核对本次启动的 boot ID、进程身份、启动参数与命名空间，用 pidfd 仅通知该启动器。等待启动终端退出。启动器会终止自己创建的进程，并保留目录、磁盘、日志和启动证据。首次启动失败时保留诊断材料，用新目录重试。如果启动器被 SIGKILL 或宿主异常关停，用原有证据逐个核对残留 PID、启动参数、boot ID 和命名空间。

## 恢复已停止的实验室

等待停止完成后，用同一 Linux 用户和同一 `WORK` 恢复已安装软件或已校准的实验室。

```sh
sudo python3 -I "$LAB" resume --work-dir "$WORK" --user "$(id -un)"
```

恢复会建立新的隔离网络命名空间，启动原有两块 qcow2 磁盘，并复用 `served/` 和 `services/`。启动器核对目录和证据的所有者、上次运行的进程，以及两块磁盘记录的原 raw 路径、格式和大小。继续保留同一份已核验的 raw 文件。如果上次记录的进程仍存活、磁盘被占用或证据不完整，恢复会失败。

恢复后，`evidence/isolation.json` 记录当前命名空间、PID 和 `output` 目录。新的 `run-…/` 目录保存上一轮的 `previous-isolation.json` 以及本轮串口、monitor、日志和抓包。用原来的 `console` 和 `stop` 命令访问当前一轮。手动连接 monitor 时使用 `output` 内的 socket。旧日志、抓包和 socket 保留在原处。如果一次恢复被强制中断且留下 `evidence/resume.lock`，后续恢复会拒绝启动。先检查该轮的进程和日志，确认没有残留进程后再处理标记。
