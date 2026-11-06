# OpenWrt RoutePolicy

为 OpenWrt 提供独立的策略分流核心包 `routepolicy` 与 LuCI 管理包 `luci-app-routepolicy`。它以 UCI 配置生成自己的 nftables 表、策略路由和 SmartDNS 附加片段，并将默认路径与策略路径分开管理。

## 支持范围

当前发布物**只面向 OpenWrt 25.12 x86_64**。请勿在其它 OpenWrt 版本、架构或衍生发行版上安装；这些组合未经过构建或运行验证。

RoutePolicy 路由功能默认 `enabled=0`。安装和升级不会自动重启 network/firewall，也不改变 LAN 地址、桥接、DHCP 或客户端设置。LuCI 包安装流程会清理 LuCI 服务端缓存并同步重启 rpcd 以注册固定 RPC 对象；rpcd 重启失败会使包脚本报错，不会静默留下无法调用的页面。该动作不需要重启路由器，RoutePolicy 服务仍保持禁用。SmartDNS 页面只有在管理员明确保存并应用后才修改 SmartDNS 标准 UCI；打开页面不会写入默认值。

## 本机分流与可观测性

0.3.0 在原有 LAN 转发分类之外增加可选的“路由器本机 IPv4 分流”。该开关默认关闭；开启并应用后，路由器上的下载器、插件和守护进程产生的未显式打标 IPv4 新连接会按同一组 dynamic/static policy/default 集合分类。已有 RoutePolicy socket/meta mark 和已建立连接的 conntrack mark 会被保留；保留地址仍不进入策略路径。策略出口离线时，命中策略的连接继续由 table 200 的 blackhole default 严格阻断，不回落默认出口。

“服务 → 路由策略 → 流量与集合”提供三类只读观测：

- 三个受管逻辑接口解析后的实际 L3 设备 RX/TX 累计量与实时速率；重复设备只采集一次并保留角色标签。
- 可选的“按源 IP 统计”；默认关闭，启用后用两个容量和超时均受限的 nftables IPv4 set 记录入站/出站 packets、bytes 和剩余活动时间。
- 四个业务 nft set 的摘要，以及当前生效域名、静态 IPv4、SmartDNS 动态 IPv4 的受限检索与分页。

接口总量与按 IP 归因口径不同。接口计数可能包含 IPv6、非 IP、桥接和其他服务流量；按源 IP 统计只覆盖经过 RoutePolicy hooks 的 IPv4，flow/hardware offload 也可能绕过逐 IP 计数。页面不会用二者相减推断“未知流量”。折线只保留当前页面最多 5 分钟/150 点，页面隐藏时暂停采样，不写闪存。

设置页还提供“归因闲置超时”（60..86400 秒）和“每方向最大 IP 数”（256..16384）；默认分别为 600 秒和 4096。达到容量时只可能遗漏新的归因键，不影响数据包转发，页面会显示 saturated 提示。关闭 `source_accounting` 并重新应用可停止归因；关闭 `route_local_traffic` 并重新应用可恢复升级前的路由器本机出站行为，LAN 转发分类不受影响。

## 安装

1. 在 [Releases](../../releases) 下载与目标版本对应的 `routepolicy-*.apk`、`luci-app-routepolicy-*.apk`、`*-packages.adb` 索引文件、`INSTALL.txt` 和 `SHA256SUMS`。
2. 通过 OpenWrt 控制台上传 APK；保留可用的本地/VMM 回退入口。
3. 在设备上先安装、但不要立即启用：

   ```sh
   apk add --allow-untrusted ./routepolicy-*.apk
   apk add --allow-untrusted ./luci-app-routepolicy-*.apk
   routepolicyctl validate
   ubus list | grep -qx routepolicy
   ubus call routepolicy status '{}'
   ```

   最后一条应返回包含 `"ok": true` 的状态对象。LuCI 包脚本已同步重启 rpcd；若对象检查仍失败，不要重复安装或启用 RoutePolicy，请先运行 `logread | grep -Ei 'rpcd|ucode|routepolicy' | tail -n 100` 保存插件加载错误。

   下载全部 Release 附件后，可先执行 `sha256sum -c SHA256SUMS`；校验失败时停止安装并重新下载。

4. 在 LuCI 或 UCI 中核对 LAN、默认接口、策略接口和 SmartDNS 已有解析组，再显式启用并应用。

依赖由 OpenWrt 软件包仓库解析；离线安装前请确保设备已具备发布说明所列依赖。`--allow-untrusted` 仅适用于直接安装本项目未签名的 release APK，请只从本仓库 Release 获取文件。

### 首次旁路由初始化（管理员 CLI）

请从预览开始安排一次单人维护。初始化期间，请暂停自动改配置的脚本，也不要在其他页面或 SSH 中保存网络、DHCP、防火墙、RoutePolicy 或 SmartDNS 设置。等到确认成功或回滚完成后再修改；即使改的是不同选项，同时保存也可能丢失修改。已有暂存和可检测的配置变化仍会触发冲突检查。

从带外控制台或 SSH 运行 `routepolicyctl init-discover`。核对接入侧的管理地址、两个出口的逻辑接口与网关，以及接入侧现有的 DHCP 服务。保留带外控制台，以便更改地址后重新连接。以下示例假设已存在 `lan`、`wan`、`policy` 三个接口。单臂接入与默认出口共用 `lan` 时，前两个参数均为 `lan`，该接口须有可达的上游网关。

```sh
routepolicyctl init-preview lan wan policy - - - - - - - -
routepolicyctl init-prepare lan wan policy - - - - - - - -
```

`-` 表示保留对应设置。三个角色之后依次为新建出口的角色、网卡、协议、IPv4 地址、前缀长度、网关，以及接入侧的新管理地址和前缀长度。为尚未配置的独立网卡创建出口时，逻辑接口名使用 `rp_init_default` 或 `rp_init_policy`。`dhcp` 出口的静态地址、前缀和网关填 `-`。`static` 出口需填写这三项。

末尾还可追加默认出口和策略出口的 DNS 上游两个参数。每个参数是最多四个以逗号分隔的 `IPv4` 或 `IPv4#端口`，省略或填 `-` 时读取所选接口当前获得的 DNS 地址。新建 DHCP 出口在预览时还没有租约，或接口没有提供 DNS 地址时，请显式填写实际可用的上游。预览会列出选择结果，应用会分别验证两个解析组。

客户端直接向旁路由接入地址的 TCP/UDP 53 端口查询 SmartDNS。接管后 SmartDNS 开机启动，dnsmasq 停止并禁止开机启动，避免重启后争用端口；保留 dnsmasq 软件包和配置用于恢复。如果其他网段仍依赖 dnsmasq 提供 DHCP 等服务，预检会拒绝接管并说明原因。初始化关闭 SmartDNS 的隐式自动配置，在同一事务中管理监听、两组上游、原服务启动状态和恢复。默认组与策略组分别使用所选出口，原有用户上游和配置字段保留。兼容验证包括 [FelixJI/smartdns 修改版](https://github.com/FelixJI/smartdns)，版本对照记录见 [隔离验证](tests/integration/smartdns-openwrt-25.12.0.md)。

接管后的开机顺序先准备分流规则，再启动 SmartDNS。DNS 缓存使用本项目的临时路径，整机重启后重新解析，避免恢复旧 DNS 缓存却缺少对应动态分流集合；原用户缓存文件保留，回滚恢复原路径。这不代表能够重建终端自身已经缓存的全部 DNS 地址。

如果新静态出口的网卡处于 DOWN，预览会标记地址冲突探测待执行，网卡保持原状态。显式应用后，事务才临时启用这块网卡，等待链路就绪并用 ARP 探测候选地址。发现地址已占用或无法确认链路时，事务停止，并在网卡仍由本事务管理时恢复原状态。

核对 `init-prepare` 返回的变更和管理入口，保存该次返回的 token。确认要应用时执行 `routepolicyctl init-apply TOKEN`。从接入侧通过 SSH 连接预览中的管理地址，检查管理连接与网络，再执行 `routepolicyctl init-confirm TOKEN`。可从带外控制台运行 `routepolicyctl init-status` 查看状态；待确认期间可用 `routepolicyctl init-recover` 主动回滚。超过确认时限，守卫会回滚本次变更。若状态为 `conflict`，从控制台核对外部改动后再处理。

尚未应用的预览在重启后失效，需要重新执行 `init-prepare`；也可用 `init-recover` 取消未应用的预览。这两种情况不会撤销此前已确认的配置。

初始化仅管理所选接口。受管 LAN 不提供 DHCPv4、RA、DHCPv6 或 NDP 代理；所选旁路由接口按 IPv4 配置，保留出口的 DHCPv4 client。SmartDNS 使用 IPv4 监听并抑制 AAAA 应答。终端仍须通过现有 DHCP 或其网络设置，把网关和 DNS 指向旁路由的接入地址。防火墙继续限制受管 IPv6 转发；这不能阻止终端直接使用其他路由器通告的 IPv6 网关，也不能把过滤 AAAA 当作完整防绕行。

## 升级

LuCI 的“服务 → 路由策略 → 运行状态”会显示当前安装的 luci-app-routepolicy 与 SmartDNS 完整 APK 版本，并提供同一份更新脚本和显式启用命令，供管理员复制到 SSH 执行；页面不会自动执行这些命令。

升级前先备份配置，并保留上一个 Release 的 APK。下面的命令会从 GitHub `latest` Release 自动识别两个最新版 APK，分别保存为固定文件名并一次性更新，无需手工填写版本号：

```sh
set -eu

sysupgrade -b /tmp/before-routepolicy.tar.gz

REPO=FelixJI/openwrt-routepolicy
ASSET_URLS="$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" \
  | jsonfilter -e '@.assets[*].browser_download_url')"
CORE_URL="$(printf '%s\n' "$ASSET_URLS" \
  | grep '/routepolicy-[0-9][^/]*\.apk$' | head -n 1)"
LUCI_URL="$(printf '%s\n' "$ASSET_URLS" \
  | grep '/luci-app-routepolicy-[0-9][^/]*\.apk$' | head -n 1)"

[ -n "$CORE_URL" ] && [ -n "$LUCI_URL" ] || {
  echo '未在 latest Release 中找到完整的 RoutePolicy APK'
  exit 1
}

LATEST_DOWNLOAD="https://github.com/${REPO}/releases/latest/download"
CORE_ASSET="${CORE_URL##*/}"
LUCI_ASSET="${LUCI_URL##*/}"

cd /tmp
wget -O routepolicy-latest.apk "${LATEST_DOWNLOAD}/${CORE_ASSET}"
wget -O luci-app-routepolicy-latest.apk "${LATEST_DOWNLOAD}/${LUCI_ASSET}"
# 旧 r1 回执未绑定 boot；先使用旧程序显式撤下旧运行态。
/etc/init.d/routepolicy stop
apk add --allow-untrusted \
  ./routepolicy-latest.apk \
  ./luci-app-routepolicy-latest.apk
routepolicyctl validate
routepolicyctl diagnose
ubus list | grep -qx routepolicy
ubus call routepolicy status '{}'
```

该命令依赖 OpenWrt 自带的 `wget` 和 `jsonfilter`，并在任一 APK 未找到或下载失败时停止。这里使用 `apk add` 精确更新这两个本地包，不要使用 `apk upgrade` 批量升级设备上的全部软件包。升级后无需重启路由器。基础设置页使用新的静态资源 generation，避免继续命中旧版 `form.NetworkSelect` 页面；已打开的旧标签页仍需重新载入一次菜单。

每个 Release 会说明配置迁移和兼容性变化。升级失败时不要删除旧配置；先停用服务并根据 Release 说明恢复上一版本。

规则重建保留两个 SmartDNS 动态业务 set 的内核对象及剩余 TTL，已有 DNS 缓存对应的地址不会因规则替换而丢失。源 IP 归因统计允许在完整重建时归零。遇到不兼容的旧集合结构会明确报错，保留现场供处理。升级不会自动开启本机分流或按源 IP 统计。

### 声明备份与固件升级后恢复

本轮核心与 LuCI 包均为 `0.3.3-r2`。从旧 `0.3.3-r1` 升级时，先使用旧程序显式停止分流，再安装 r2 并重建。缺少当前 boot 授权的旧回执不能认领同名运行对象；遇到对象时新程序保留并拒绝操作，不能用强制重装冒充版本升级。

`routepolicyctl migrate --json` 校验兼容的 v0.3.3 配置并登记 schema 1、迁移确认记录目录；它不接管或重启网络。新程序拒绝更高的配置 schema。受支持的包迁移入口为 `printf '目标APK版本\t1\n' | routepolicyctl package-check --json`：不支持的 schema 或较旧版本会实际拒绝。该准入不能阻止管理员绕过入口、用原生 APK 强装不认识新 schema 的旧程序；这种降级不受支持。

固件升级前，在单人维护窗口和带外控制台中完成：

```sh
umask 077
routepolicyctl migrate --json
routepolicyctl config-export > /tmp/routepolicy.rpconf
sysupgrade -l
sysupgrade -b /tmp/before-firmware.tar.gz
```

核对备份包含 `/etc/config/routepolicy`、人工清单、静态 `managed.d/current` 清单，以及 `state/init-transaction/active`、`source` 和 `confirmed/` 中完整的确认记录／累计退出原值。SmartDNS、network、dhcp、firewall 的原有未知字段由系统自己的配置备份保存。临时锁、未提交 WAL、applied 回执、warm 动态集合和官方 init／二进制不属于应用保留清单。恢复入口会重新建立 0700 目录和 0600 记录。

把系统备份、portable 声明、上一个可用版本和待安装版本的两个 APK、依赖说明及已有发布校验材料复制到路由器之外，再按 OpenWrt 官方流程升级。普通 sysupgrade 和公共 ASU 不会自动保留本项目的自定义 APK。应用缺失期间没有分流规则与 strict 保护；SmartDNS 缺失时也可能没有 DNS，接入 DHCP 仍保持关闭。先保留带外管理与离线安装材料，避免依赖待恢复的 DNS 下载应用。

升级完成后从控制台重新安装受支持的两个 APK 及依赖，再执行 `routepolicyctl init-repair --json`、`routepolicyctl diagnose --json` 和 `ubus call routepolicy status '{}'`。恢复根据声明重新检查当前接口、受管字段、依赖和内核对象，先建立策略规则再启动 DNS；旧启动的 applied 不能认领新内核的同名资源。缺失依赖、静态清单或所有权冲突会保留现场并报错，不能把空规则或陈旧回执当作 strict 成功。实际固件升级只在隔离环境验收，本命令不会代替管理员执行 sysupgrade。

系统解析接管保留标准 `/etc/resolv.conf` 链接，只把 `/tmp/resolv.conf` 指向受管的 IPv4 lo53 文件。接口 DNS 和 netifd 的 `resolv.conf.auto` 保持原样，供 SmartDNS 的 hostname 上游启动解析使用；自定义 resolver 布局或外部修改会阻止接管。普通停用继续保留 DNS，显式退出才恢复本次启动的原入口；固件恢复和冷启动不会重放旧 `/tmp` 内容。

旧确认记录若没有系统 resolver 合同，`init-repair` 会明确拒绝虚报 DNS 就绪。可在维护窗口复用已验证记录的参数，先重新预览和准备，再按新 token 执行原有 apply、真实 LAN SSH confirm 流程，无需逐项重填：

```sh
token=$(cat /etc/routepolicy/state/init-transaction/active) || exit 1
case "$token" in ''|*[!0-9a-f]*) exit 1 ;; esac
[ "${#token}" = 32 ] || exit 1
parameters=$(cat "/etc/routepolicy/state/init-transaction/confirmed/$token/parameters") || exit 1
set -f
IFS="$(printf '\t')"
set -- $parameters
routepolicyctl init-preview "$@" --json
routepolicyctl init-prepare "$@" --json
```

### 在另一台设备导入

portable 使用 `routepolicy-config` schema 1 的 UTF-8 文本记录，最多 2 MiB、每份人工清单最多 256 KiB。它保存应用设置、来源、人工规则和初始化绑定提示；不接受 archive、任意文件路径、journal、applied 或动态集合。来源 URL、本地主机、接口与 DNS 地址可能敏感，备份必须私下保存。

```sh
routepolicyctl config-import --json < /tmp/routepolicy.rpconf
routepolicyctl restore-status --json
```

这两步只建立候选，不接管目标设备。schema 1 的 DNS 可移植意图限于初始化的默认／策略两组上游提示；其他 SmartDNS UCI 字段和用户上游会逐项列为 `unportable_fields`，目标设备不执行原始配置文本。请在目标设备核对这些设置；本机包升级和标准系统备份继续保留它们。

`restore-prepare` 从 stdin 接收恰好一行、15 列 Tab 分隔的参数：接入、默认出口、策略出口，新出口角色、网卡、协议、IPv4、前缀、网关，新管理地址、前缀，两组 DNS，危险确认 `1`，不可移植字段确认 `1`。前 13 列与 `init-prepare` 相同，保留项填 `-`；必须重新明确目标设备接口与 DNS，旧设备绑定不自动生效。导入的启用来源重新下载，缺少快照的来源也必须准备齐全；初始化事务先建立新出口，再按原意图绑定出口下载，验证清单后才建立策略和确认。不会暗中通过默认出口下载或以空规则成功；下载或后续应用失败会恢复原 `current/previous` 清单，外部冲突保留并报告。

目标已有活动分流、运行回执或不能判明的内核策略时，恢复会在安装任何声明前拒绝。请先按下述停用流程显式停用分流并确认撤除成功，再重试恢复；导入不会自动清除目标规则。人工清单导出按原有严格转换器规范化支持的 Tab、CRLF 和注释，保留规则语义；其他控制字符仍拒绝。

初始化仍共用原来的 120 秒总窗口。应用完成首次进入待确认时，必须在完成核验、持久化待确认状态和生成结果后留出至少 20 秒；时间不足会回滚并报告。对同一待确认 token 重试应用只是读取既有状态，不重做配置，也不延长原期限。

需要 DNS 解析才能下载时，同一未确认事务先建立受管策略对象和 DNS，引导时优先沿用已验证的旧静态集合；缺少规则的部分仍是待准备状态。此时 `source_bootstrap=true`、`applied=false`，诊断和确认入口都会拒绝把它当成完成。下载、最终策略与 DNS 校验完成后才能清除引导状态；整个过程共用原 120 秒窗口、首次写前意图和逐字段回滚，不另外启动临时 DNS 程序。

预检通过后只安装应用自己的声明，网络仍待确认；保存返回的 token，按 `init-apply TOKEN` → 连接目标管理地址 → `init-confirm TOKEN` 完成现有事务。声明六个固定文件有同一共享写锁下的写前记录；安装、预检、下载或确认失败时先检查 `init-status`／`restore-status`，网络事务用 `init-recover` 收敛，再用 `restore-recover` 逐文件恢复旧应用声明。外部已改的值不会被覆盖。

恢复 RPC 提供同一候选、应用和状态合同；本轮确认传输为 `confirmation_transport=trusted-ssh`。`init_confirm` RPC 明确返回需要可信确认，不会把浏览器自报地址写成 `SSH_CONNECTION`。实际确认必须从新管理入口的 LAN SSH 连接执行；浏览器的可信 HTTP 重连确认适配属于后续 #20，本轮不宣称浏览器闭环已完成。

## SmartDNS 管理

LuCI 入口为“服务 → 路由策略 → SmartDNS”。它不依赖官方 `luci-app-smartdns`，但可以与其共存；若 SSH、官方页面或其他工具在本页面打开后修改了 SmartDNS UCI，版本/基线比较会拒绝覆盖并要求刷新。RoutePolicy 停用时仍可独立管理 DNS。旁路由初始化会统一协调 DNS 和分流设置，期间其他 SmartDNS 写入入口须等待事务完成。

页面中的“已初始化”只表示识别到一个 `config smartdns` 根段，不表示服务已安装、正在运行或候选已经应用。命名根段和常见的匿名 `config smartdns` 都会被识别；不存在根段时，“保存 SmartDNS”只保存候选，首次“验证并应用”才会创建最小命名根段。已有匿名 `config server` 会按 `@server[N]` 精确显示和编辑，页面打开后的外部重排仍会触发基线冲突并拒绝覆盖。新建上游使用仅含字母、数字和下划线的稳定 UCI 段标识。

配置所有权按层分开：

- `/etc/config/smartdns` 保存 SmartDNS 服务、监听、上游、缓存、TTL、DNS 行为及两个附加片段的 `conf_files` 登记。RoutePolicy 只精确修改页面涉及的字段，保留未知 option、未知段和其他 `conf_files`。
- `/etc/smartdns/conf.d/90-routepolicy.conf` 只保存 RoutePolicy domain-set/nftset/domain-rules、本地主机引用和 PTR 扩展；`routepolicy.main.smartdns_enabled` 只控制这一适配片段。
- `/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf` 保存 OpenWrt init 未映射的 `serve-expired-reply-ttl`、`cache-checkpoint-time` 和受支持的可选仪表盘字段。
- `/etc/routepolicy/user.d/local-hosts.list` 是保留的用户配置，每行为 `IP 主名称 [别名 ...]`；A/AAAA 覆盖全部名称，PTR 只扩展主名称。DHCP 租约页面只读。只有管理员确认旁路由初始化方案后，后端才可关闭选定接入接口的 DHCPv4、RA、DHCPv6 与 NDP 服务。保留出口 DHCP client 和其他接口配置；若其他接口仍依赖 dnsmasq 提供服务，拒绝接管。成功接管后由 SmartDNS 提供 DNS，dnsmasq 停止并禁用自启动。

服务启用、RoutePolicy 启用、90 适配启用是三个独立状态。90/91 的 loaded 状态来自 `/var/etc/smartdns/smartdns.conf` 中实际生成的 `conf-file`，不是仅检查文件存在。

上游支持 UDP、TCP、TLS、HTTPS、QUIC 和 H3，以及组、SNI、HTTP Host、fallback、proxy、interface 和 set mark；支持新增、停用、编辑和确认删除，且不暴露 `addition_arg`。编辑既有服务器保留未知字段。建议上游总数约 10 个，并分散运营者和协议；这是建议而非硬上限。没有显式上游但仍有有效 resolv-file 时不会强制创建默认服务器。

缓存与 TTL 字段保留四类语义：布尔三态的空值=继承、`0`=关闭、`1`=开启；`cache_size=-1` 表示按内存自动、`0` 表示禁用缓存、正数表示条目数。推荐 `cache_size=-1`、内部最小 TTL 600–1800 秒；最大 TTL 与客户端最大 TTL 默认继承。检查点 `0` 表示关闭，非零至少 120 秒。页面不提供不存在的“客户端最小 TTL”。关闭持久化、屏蔽 AAAA/HTTPS、删除上游、停用服务、dnsmasq 自动配置和启用仪表盘都要求危险确认。

dnsmasq 自动配置使用 SmartDNS 官方 init 行为：端口 53 时可能把 dnsmasq DNS 端口设为 0；非 53 时可能让 dnsmasq 转发到 `127.0.0.1#端口`，还可能调整 `noresolv`、重绑定保护、`domainneeded`、DHCP option 6 并重启 dnsmasq。若有效设置要求自动配置但 dnsmasq 未运行，应用会被阻止；RoutePolicy 不会替用户启动 dnsmasq。

`smartdns-ui` 是可选项，缺失时不能启用。检测到插件后可配置启用状态、端口（建议/默认 6080）、数据目录和日志保留；项目不会创建防火墙放行规则，也不会管理密码、终端、CORS、HTTPS 或证书。启用前必须修改默认凭据并自行限制访问。

应用事务会备份 SmartDNS UCI、90/91、本地主机和服务状态，执行字段校验、预览所对应的危险确认、精确提交、服务动作和真实加载验证；失败会恢复上述配置与文件。缓存内容本身不属于配置回滚。首次接管会去重同名 90/91 登记，不触碰其他附加片段。

## 从旧手工方案迁移

先安装但不启用，然后只做复制式导入：

```sh
routepolicyctl import-legacy /etc/splitroute
routepolicyctl validate
routepolicyctl render
```

确认候选规则、接口和清单后，才暂停旧 cron 并启用新服务。旧文件在并行验证完成前必须保留。

本项目**不公开也不分发**本地旧方案清理脚本；它不由 APK 自动调用。清理属于设备现场的最后一步，应在已经验证新服务、具备控制台回退路径和完整备份后单独完成。

## 卸载与回退

停用分流、退出旁路由模式和卸载是三种不同操作。`disable-preview` 显示停用影响；关闭 `routepolicy.main.enabled` 后重载服务会撤掉应用分流，但保留接入 DHCP 关闭与 DNS 接管配置，不能把它当作恢复原网络。

停用按已应用回执中的精确内容核对 90 片段，不按后来修改的设置猜测。旧回执若缺少该内容且没有同启动、同 token 的已确认记录可证明归属，会保留片段并拒绝清理；请先核实旧配置并通过受支持的应用流程重建回执，不要手工删除归属记录或用户片段。

如需恢复最初的接入地址、DHCP/DNS 配置和服务启动／运行状态，请先从带外控制台显式退出：

```sh
routepolicyctl exit-preview --json
routepolicyctl exit-prepare --json
# 核对预览并保存返回的 token；退出可能改变管理地址与 DHCP 服务。
routepolicyctl exit-apply TOKEN
```

退出只恢复有累计来源且仍符合预期的字段。旧版本多次初始化后缺少中间原值、外部编辑或未知子字段会在预览中列出并阻止猜测恢复；不会整份覆盖配置。成功退出后原用户上游和未知字段仍保留。

确认默认网络和 DNS 可用后，再运行 `routepolicyctl package-preview --json`，用 `printf 'CONFIRM-REMOVE-ROUTEPOLICY\n' | routepolicyctl uninstall` 明确删除两个包。也可以明确选择保留接管配置后删除程序，但此时分流保护和应用管理都不可用，应安排重装或外部维护。

原生 `apk del` 不等于退出，APK 的 pre-deinstall 失败也不能阻止删除。卸载只撤销自有分流和 90 适配登记，不启动 DHCP，不在程序删除后重载 DNS；91、用户 SmartDNS 上游、未知 `conf_files` 和用户声明保留。下次 SmartDNS 重启不再引用已撤下的 90 片段。没有新增 purge，也不删除旧方案文件。

## 安全边界

- 路由应用仅操作独立的 `inet routepolicy` 表和策略路由表；SmartDNS 页面可在用户授权后精确管理标准 SmartDNS UCI、上游和自有附加片段。
- RPC 只执行仓库内枚举的固定完整命令字符串；请求字段不进入 shell，动态正文只通过 stdin 传递。不提供任意命令、任意 nft 文本或任意路径访问接口。
- 观测查询只接受固定 dataset、排序和设备枚举；query、cursor、limit 都有长度/范围上限。域名 active catalog 只在完整应用成功后发布，失败候选不会显示为“当前生效”。
- 远程清单经过格式、数量、地址范围和原子回滚检查；不要把不可信订阅 URL 或凭据提交到 issue。
- 策略接口断开时设计为严格阻断，避免命中策略的流量回落到默认路径。

更多信息见 [贡献指南](CONTRIBUTING.md)、[安全策略](SECURITY.md) 和仓库内的设计文档。
