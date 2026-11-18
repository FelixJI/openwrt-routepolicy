# RoutePolicy 操作手册

本文按当前源码的安装器、初始化与恢复向导及生命周期命令整理。仅适用于 OpenWrt 25.12 x86_64；设备实际安装版本以 `apk info -v routepolicy luci-app-routepolicy` 为准，发布包能力以对应 tag 为准。

## 安装与升级

下载同一 Release 的全部附件到独立目录，完整上传设备。升级前执行 `sysupgrade -b /tmp/before-routepolicy.tar.gz` 并把备份移出设备；需要整机回退时另保留已验证的完整系统备份或虚拟机快照。

```sh
sha256sum -c SHA256SUMS
sh install.sh --allow-local-unsigned
ubus list | grep -qx routepolicy
ubus call routepolicy status '{}'
```

从旧 `0.3.3-r1` 升级，须在安装前用旧程序执行 `/etc/init.d/routepolicy stop`，解决旧回执缺少本次启动归属的问题；其他版本不要提前停掉正常运行的分流。新装默认禁用，升级保留设置。安装器核对平台、介质、依赖和落地版本，拒绝降级与未提交的 RoutePolicy 配置；失败可能留下已安装依赖或部分应用包，不承诺原子回退。保留日志，按随附 `INSTALL.txt` 恢复。

安装后重新载入 LuCI 菜单。新设备进入“服务 → 路由策略 → 初始化与恢复向导”向导；已有设备不必重新初始化。详细安装行为和自动下载升级命令见 [README](README.md#安装)。

## 首次配置与确认

安排单人维护窗口并保留带外控制台。向导打开时只读；核对接入、默认出口、策略出口、管理地址、DNS、规则与来源，然后预览实际配置差异，再明确应用。

应用可能改变地址、DHCP/IPv6 服务及 DNS 所有权。按提示重连目标管理地址并确认；180 秒总窗口不会因刷新而延长，超时回滚。冲突或请求超时时先读状态，不重复盲点应用。终端网关与 DNS 仍须由管理员或现有 DHCP 指向旁路由。CLI 参数及确认边界见 [首次初始化](README.md#首次旁路由初始化管理员-cli)。

## 日常管理与排障

- “运行状态”查看服务与包版本，可验证、重新应用、启用或停用；应用失败后允许再次点击“启用并应用”，UCI 已启用不等于实际应用成功。
- “SmartDNS”保存候选、验证再应用。初始化事务期间其他写入口受门禁限制；不要并发修改网络与 DNS。
- “流量与集合”查询生效集合、设备速率和可选的按源 IP 统计。路由器本机 IPv4 分流与按源 IP 统计均默认关闭，分别开启。

```sh
routepolicyctl status --json
routepolicyctl diagnose --json
routepolicyctl init-status
logread | grep -Ei 'rpcd|ucode|routepolicy' | tail -n 100
```

诊断检查独立 `dns_prerouting` NAT 链；DNS redirect 不能放入 filter 链。核心包显式依赖 `kmod-nft-nat`。若安装后 RPC 缺失，先保留插件加载日志，不靠重装、重启整机或反复启用掩盖问题。

## 备份、退出与卸载

跨设备迁移使用向导导出声明，再在目标重新选择接口与 DNS；导出内容可能含私有 URL 和上游信息。固件备份与恢复的详细范围见 [README](README.md#声明备份与固件升级后恢复)。

停用分流、退出旁路由模式和卸载是不同操作：停用保留 DNS/DHCP 接管状态，退出才尝试按归属恢复原网络；存在外部编辑时拒绝猜测覆盖。

```sh
routepolicyctl exit-preview --json
routepolicyctl exit-prepare --json
# 核对变化，使用上一条返回的真实 token；此操作可能改变管理地址。
routepolicyctl exit-apply TOKEN
routepolicyctl package-preview --json
# 仅在确认网络、DNS 和卸载预览后执行：
printf 'CONFIRM-REMOVE-ROUTEPOLICY\n' | routepolicyctl uninstall
```

卸载需要无暂存配置、无待确认或遗留 rpcd 快照的维护窗口。不要把原生 `apk del` 当作退出流程，也不要通过强装旧 APK 回退。完整失败处理及保留字段见 [卸载与回退](README.md#卸载与回退)。维护者发版见 [RELEASE.md](RELEASE.md)，旧实施计划仅供设计追溯。
