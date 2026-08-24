# OpenWrt RoutePolicy

为 OpenWrt 提供独立的策略分流核心包 `routepolicy` 与 LuCI 管理包 `luci-app-routepolicy`。它以 UCI 配置生成自己的 nftables 表、策略路由和 SmartDNS 附加片段，并将默认路径与策略路径分开管理。

## 支持范围

当前发布物**只面向 OpenWrt 25.12 x86_64**。请勿在其它 OpenWrt 版本、架构或衍生发行版上安装；这些组合未经过构建或运行验证。

软件包默认 `enabled=0`。安装、升级和停用不会自动重启 network/firewall，也不改变 LAN 地址、桥接、DHCP、客户端设置或既有 SmartDNS 上游服务器。

## 安装

1. 在 [Releases](../../releases) 下载与目标版本对应的 `routepolicy-*.apk`、`luci-app-routepolicy-*.apk`、`*-packages.adb` 索引文件、`INSTALL.txt` 和 `SHA256SUMS`。
2. 通过 OpenWrt 控制台上传 APK；保留可用的本地/VMM 回退入口。
3. 在设备上先安装、但不要立即启用：

   ```sh
   apk add --allow-untrusted ./routepolicy-*.apk
   apk add --allow-untrusted ./luci-app-routepolicy-*.apk
   routepolicyctl validate
   ```

   下载全部 Release 附件后，可先执行 `sha256sum -c SHA256SUMS`；校验失败时停止安装并重新下载。

4. 在 LuCI 或 UCI 中核对 LAN、默认接口、策略接口和 SmartDNS 已有解析组，再显式启用并应用。

依赖由 OpenWrt 软件包仓库解析；离线安装前请确保设备已具备发布说明所列依赖。`--allow-untrusted` 仅适用于直接安装本项目未签名的 release APK，请只从本仓库 Release 获取文件。

## 升级

升级前先备份配置，并保留上一个 Release 的 APK：

```sh
sysupgrade -b /tmp/before-routepolicy.tar.gz
apk add --allow-untrusted ./routepolicy-*.apk ./luci-app-routepolicy-*.apk
routepolicyctl validate
routepolicyctl diagnose
```

每个 Release 会说明配置迁移和兼容性变化。升级失败时不要删除旧配置；先停用服务并根据 Release 说明恢复上一版本。

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

卸载仅应移除 RoutePolicy 自己创建的内容，不应删除你的接口、SmartDNS 主配置或旧方案文件。若此预期不成立，请停止操作并保留现场信息后按 [安全策略](SECURITY.md) 报告。

## 安全边界

- 仅操作独立的 `inet routepolicy` 表、策略路由表和 SmartDNS 附加片段。
- 不提供任意命令、任意 nft 文本或任意路径访问接口。
- 远程清单经过格式、数量、地址范围和原子回滚检查；不要把不可信订阅 URL 或凭据提交到 issue。
- 策略接口断开时设计为严格阻断，避免命中策略的流量回落到默认路径。

更多信息见 [贡献指南](CONTRIBUTING.md)、[安全策略](SECURITY.md) 和仓库内的设计文档。
