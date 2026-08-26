# OpenWrt RoutePolicy

为 OpenWrt 提供独立的策略分流核心包 `routepolicy` 与 LuCI 管理包 `luci-app-routepolicy`。它以 UCI 配置生成自己的 nftables 表、策略路由和 SmartDNS 附加片段，并将默认路径与策略路径分开管理。

## 支持范围

当前发布物**只面向 OpenWrt 25.12 x86_64**。请勿在其它 OpenWrt 版本、架构或衍生发行版上安装；这些组合未经过构建或运行验证。

RoutePolicy 路由功能默认 `enabled=0`。安装和升级不会自动重启 network/firewall，也不改变 LAN 地址、桥接、DHCP 或客户端设置。LuCI 包安装流程会重载 rpcd 以注册固定 RPC 对象，但不需要重启路由器，RoutePolicy 服务仍保持禁用。SmartDNS 页面只有在管理员明确保存并应用后才修改 SmartDNS 标准 UCI；打开页面不会写入默认值。

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

   最后一条应返回包含 `"ok": true` 的状态对象。若对象检查失败，可执行一次 `/etc/init.d/rpcd restart` 后重试；这只是 rpcd 注册恢复，不需要重启路由器，也不需要为查看状态而重启 RoutePolicy。

   下载全部 Release 附件后，可先执行 `sha256sum -c SHA256SUMS`；校验失败时停止安装并重新下载。

4. 在 LuCI 或 UCI 中核对 LAN、默认接口、策略接口和 SmartDNS 已有解析组，再显式启用并应用。

依赖由 OpenWrt 软件包仓库解析；离线安装前请确保设备已具备发布说明所列依赖。`--allow-untrusted` 仅适用于直接安装本项目未签名的 release APK，请只从本仓库 Release 获取文件。

## 升级

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
apk add --allow-untrusted \
  ./routepolicy-latest.apk \
  ./luci-app-routepolicy-latest.apk
routepolicyctl validate
routepolicyctl diagnose
ubus list | grep -qx routepolicy
ubus call routepolicy status '{}'
```

该命令依赖 OpenWrt 自带的 `wget` 和 `jsonfilter`，并在任一 APK 未找到或下载失败时停止。这里使用 `apk add` 精确更新这两个本地包，不要使用 `apk upgrade` 批量升级设备上的全部软件包。升级后无需重启路由器；若 LuCI 仍显示旧页面，请强制刷新浏览器缓存。

每个 Release 会说明配置迁移和兼容性变化。升级失败时不要删除旧配置；先停用服务并根据 Release 说明恢复上一版本。

## SmartDNS 管理

LuCI 入口为“服务 → 路由策略 → SmartDNS”。它不依赖官方 `luci-app-smartdns`，但可以与其共存；若 SSH、官方页面或其他工具在本页面打开后修改了 SmartDNS UCI，版本/基线比较会拒绝覆盖并要求刷新。SmartDNS 的“保存候选/验证并应用”与 RoutePolicy 的 nftables、策略路由应用完全分离，RoutePolicy 停用时仍可管理 DNS。

页面中的“已初始化”只表示识别到一个 `config smartdns` 根段，不表示服务已安装、正在运行或候选已经应用。命名根段和常见的匿名 `config smartdns` 都会被识别；不存在根段时，“保存 SmartDNS”只保存候选，首次“验证并应用”才会创建最小命名根段。已有匿名 `config server` 会按 `@server[N]` 精确显示和编辑，页面打开后的外部重排仍会触发基线冲突并拒绝覆盖。新建上游使用仅含字母、数字和下划线的稳定 UCI 段标识。

配置所有权按层分开：

- `/etc/config/smartdns` 保存 SmartDNS 服务、监听、上游、缓存、TTL、DNS 行为及两个附加片段的 `conf_files` 登记。RoutePolicy 只精确修改页面涉及的字段，保留未知 option、未知段和其他 `conf_files`。
- `/etc/smartdns/conf.d/90-routepolicy.conf` 只保存 RoutePolicy domain-set/nftset/domain-rules、本地主机引用和 PTR 扩展；`routepolicy.main.smartdns_enabled` 只控制这一适配片段。
- `/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf` 保存 OpenWrt init 未映射的 `serve-expired-reply-ttl`、`cache-checkpoint-time` 和受支持的可选仪表盘字段。
- `/etc/routepolicy/user.d/local-hosts.list` 是保留的用户配置，每行为 `IP 主名称 [别名 ...]`；A/AAAA 覆盖全部名称，PTR 只扩展主名称。DHCP 租约只读展示，项目不会创建、启用、启动、修改或重载 DHCP。

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

先停用服务，确认默认网络仍可访问，再移除包：

```sh
/etc/init.d/routepolicy stop
apk del luci-app-routepolicy routepolicy
```

卸载只移除 90/91 的 `conf_files` 登记和 RoutePolicy 自有运行片段，不删除 `/etc/config/smartdns`、用户上游、未知字段或保留的本地主机 conffile，也不删除旧方案文件。若此预期不成立，请停止操作并保留现场信息后按 [安全策略](SECURITY.md) 报告。

## 安全边界

- 路由应用仅操作独立的 `inet routepolicy` 表和策略路由表；SmartDNS 页面可在用户授权后精确管理标准 SmartDNS UCI、上游和自有附加片段。
- RPC 只执行仓库内枚举的固定完整命令字符串；请求字段不进入 shell，动态正文只通过 stdin 传递。不提供任意命令、任意 nft 文本或任意路径访问接口。
- 远程清单经过格式、数量、地址范围和原子回滚检查；不要把不可信订阅 URL 或凭据提交到 issue。
- 策略接口断开时设计为严格阻断，避免命中策略的流量回落到默认路径。

更多信息见 [贡献指南](CONTRIBUTING.md)、[安全策略](SECURITY.md) 和仓库内的设计文档。
