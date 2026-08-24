# OpenWrt RoutePolicy 详细实施计划

> 目标形态：核心包 `routepolicy` + LuCI 包 `luci-app-routepolicy` + 少量首次手工配置。
> 公开仓库建议名：`openwrt-routepolicy`。
> 许可证：MIT。
> 本地清理脚本不进入公开仓库。

## 1. 状态标识

- ✅ 已确定：架构、边界、命名、安全原则、迁移顺序。
- 🟡 待实施：代码、测试、构建和发布。
- 🔵 本地交付：仅在设备迁移时使用，不进入公开仓库。
- ⛔ 不纳入：软件包不负责的操作。

## 2. 实施路线总览

```text
路线 0：手工建立安全基线
   ↓
路线 1：建立公开仓库和构建骨架
   ↓
路线 2：实现 routepolicy 核心包 MVP
   ↓
路线 3：实现 SmartDNS 适配与清单引擎
   ↓
路线 4：实现迁移、诊断、回滚和接口事件处理
   ↓
路线 5：实现 luci-app-routepolicy
   ↓
路线 6：虚拟机集成测试和 APK 发布
   ↓
路线 7：目标设备安装、导入、并行验证
   ↓
路线 8：运行本地清理脚本，移除旧手工脚本
   ↓
路线 9：重启验收并进入日常维护
```

| 路线 | 状态 | 主要产物 | 通过条件 |
|---|---|---|---|
| 0. 手工基线 | ✅ 方案已确定，现场待执行 | LAN/WAN、SmartDNS、策略接口基础配置 | 默认路径可用，管理入口稳定 |
| 1. 仓库骨架 | 🟡 待实施 | MIT 仓库、包目录、CI 骨架 | SDK 能生成两个 APK |
| 2. 核心包 MVP | 🟡 待实施 | UCI、服务、nftables、策略路由 | 静态 IPv4 规则可稳定工作 |
| 3. DNS 与清单 | 🟡 待实施 | SmartDNS 片段、更新器、转换器 | 域名结果按 TTL 进入动态集合 |
| 4. 运维能力 | 🟡 待实施 | 导入、诊断、回滚、热插拔处理 | 断线、更新失败和重启均可恢复 |
| 5. LuCI | 🟡 待实施 | 5 个管理页面、ACL、ubus/ucode | 日常设置不再需要编辑脚本 |
| 6. 构建发布 | 🟡 待实施 | x86_64 APK、校验值、Release | 干净系统可安装和卸载 |
| 7. 迁移安装 | 🟡 待实施 | 导入记录、验证报告 | 新旧系统并行验证通过 |
| 8. 旧脚本清理 | 🔵 脚本已单独交付 | 私有清理脚本和完整备份 | 旧服务消失，新服务保持正常 |
| 9. 最终验收 | 🟡 待实施 | 验收记录 | 重启、断线、更新、回滚全部通过 |

## 3. 固定边界

### 3.1 软件包负责

- 根据 UCI 生成独立 nftables 表、集合和分类规则。
- 维护策略路由表、标记规则和严格阻断默认路由。
- 监听默认接口、策略接口和 LAN 接口状态变化。
- 生成独立 SmartDNS 配置片段，只引用已有解析组。
- 维护策略域名、默认覆盖域名、策略 IPv4、默认覆盖 IPv4。
- 下载远程清单，完成格式转换、语法检查、条目检查、原子替换和回滚。
- 保存最近可用版本和可选的动态集合暖启动快照。
- 提供 CLI、ubus、LuCI 状态、诊断、导入和回滚入口。
- 在安装、升级、停用和卸载时保持可恢复性。

### 3.2 仅首次手工完成

- 群晖 VMM 的虚拟网卡映射和 USB 设备直通。
- OpenWrt LAN 地址、上游接口和管理入口确认。
- 关闭 OpenWrt LAN DHCP、RA、DHCPv6、NDP。
- 首次创建策略接口并加入具有 NAT/MSS 钳制的防火墙区域。
- 安装并完成 SmartDNS 基础解析组配置。
- 客户端静态 IPv4、网关和 DNS 设置。

### 3.3 明确不纳入

- 不自动更改 LAN 地址或桥接关系。
- 不自动修改群晖 VMM。
- 不自动创建或删除 SmartDNS 上游服务器。
- 不在安装 APK 时自动重启 network 或 firewall。
- 不控制客户端网络设置。
- 不重新开发完整历史流量图；继续复用现有统计组件。

## 4. 软件包拆分

### 4.1 核心包：`routepolicy`

建议依赖：

```text
nftables
ip-full
curl
ca-bundle
jsonfilter
ubus
uci
smartdns
```

建议安装文件：

```text
/etc/config/routepolicy
/etc/init.d/routepolicy
/usr/sbin/routepolicyctl
/usr/libexec/routepolicy/apply
/usr/libexec/routepolicy/validate
/usr/libexec/routepolicy/status
/usr/libexec/routepolicy/diagnose
/usr/libexec/routepolicy/update
/usr/libexec/routepolicy/rollback
/usr/libexec/routepolicy/import-legacy
/usr/libexec/routepolicy/converters/*
/etc/hotplug.d/iface/95-routepolicy
/lib/upgrade/keep.d/routepolicy
```

持久数据：

```text
/etc/routepolicy/user.d/
/etc/routepolicy/managed.d/current/
/etc/routepolicy/managed.d/previous/
/etc/routepolicy/state/
```

运行时数据：

```text
/tmp/routepolicy/rules.nft
/tmp/routepolicy/lists/
/tmp/routepolicy/status.json
/tmp/routepolicy/update.log
```

### 4.2 LuCI 包：`luci-app-routepolicy`

依赖：

```text
routepolicy
luci-base
rpcd-mod-ucode
```

页面：

1. **运行状态**：服务、接口、路由表、集合数量、上次更新和错误摘要。
2. **基础设置**：LAN、默认接口、策略接口、严格阻断、DNS 重定向、暖启动、更新时间。
3. **清单来源**：URL、格式、目标类型、最低条目数、最大缩减比例、是否绑定策略接口更新。
4. **人工规则**：四类人工清单，保存前逐行校验。
5. **诊断与迁移**：检测、导入旧目录、预览变更、应用、回滚、导出诊断报告。

后端只开放固定 ubus 方法：

```text
routepolicy.status
routepolicy.validate
routepolicy.apply
routepolicy.reload
routepolicy.update
routepolicy.rollback
routepolicy.diagnose
routepolicy.import_legacy
routepolicy.read_user_list
routepolicy.write_user_list
```

不开放任意 shell、任意 nft 文本或任意命令执行。

## 5. UCI 配置模型

建议 `/etc/config/routepolicy`：

```uci
config main 'main'
        option enabled '0'
        option lan_interface 'lan'
        option default_interface 'wan'
        option policy_interface 'usbwan'
        option strict_enforcement '1'
        option dns_redirect '1'
        option warm_restore '1'
        option route_table '200'
        option rule_priority '12000'
        option mark '0x100'
        option mark_mask '0x100'
        option smartdns_enabled '1'
        option smartdns_policy_group 'policy'
        option auto_update '1'
        option update_hour '4'
        option update_minute '17'
        option update_via_policy_interface '1'

config source 'example_source'
        option enabled '1'
        option name 'Example source'
        option url 'https://example.invalid/list.txt'
        option format 'plain-domain'
        option target 'domain-policy'
        option min_entries '100'
        option max_shrink_percent '50'
```

高级参数默认折叠，LuCI 提供“恢复推荐值”。

## 6. 核心包实现任务

### 6.1 服务和配置生命周期

- 默认 `enabled=0`，安装不接管系统。
- `validate` 只读检查，不修改任何状态。
- `apply` 先生成候选配置，再执行 `nft -c`、接口和 mark 冲突检查。
- 仅候选配置全部通过后才原子应用。
- 应用失败时保留上一版运行配置。
- `stop` 只删除自身 nftables 表、规则和路由，不修改用户网络配置。
- `reload` 不清空仍有效的动态集合；只有结构变化时才重建表。

### 6.2 nftables 设计

独立表：

```text
table inet routepolicy
```

集合：

```text
domain_policy4    动态、timeout
domain_default4   动态、timeout
static_policy4    interval
static_default4   interval
```

规则要求：

- 只处理配置的 LAN 逻辑接口对应实际设备。
- 排除本地、私网、链路本地、CGNAT、组播和保留地址。
- 默认覆盖集合优先于策略集合。
- 只修改指定 mark bit，不能覆盖完整 mark。
- 使用 conntrack mark 固定已建立连接的路径。
- 可选重定向 LAN 的 TCP/UDP 53 到本机 DNS。
- 每类规则带独立 counter。

### 6.3 策略路由设计

- 默认路径继续由 main 表负责，核心包不修改其默认路由。
- 策略路径使用独立表，默认表号 200。
- 始终存在高 metric blackhole default，保证接口断开时不继续查询 main 表。
- 策略接口在线时，根据 ubus 状态写入其直连路由和真实默认路由。
- 接口下线时只移除真实路由，保留 blackhole。
- 热插拔脚本必须幂等，重复触发不能产生重复规则。

### 6.4 SmartDNS 适配

生成：

```text
/etc/smartdns/conf.d/90-routepolicy.conf
```

只包含：

- `nftset-timeout`。
- 两类 domain-set。
- 两类 nftset 映射。
- 对已有解析组的引用。
- 关闭参与策略判断域名的过期缓存响应和不适合的本机测速。

不包含：

- 任何上游服务器地址。
- SmartDNS 主监听端口。
- 用户已有的普通解析规则。

核心包通过 SmartDNS 的附加配置文件机制加载该片段；停用后删除引用并重载 SmartDNS，不覆盖用户的 `custom.conf`。

### 6.5 清单引擎

首版支持：

```text
plain-domain
plain-ipv4
hosts-domain
adblock-domain
dnsmasq-domain
clash-domain
clash-ipv4
```

更新流水线：

```text
下载临时文件
→ 检查 HTTP 和 HTML 错误页
→ 按显式格式转换
→ 过滤非法项、IPv6、私网和保留地址
→ 去重、排序
→ 检查最低数量和最大缩减比例
→ 生成候选集合
→ nft 语法预检
→ 原子切换 current/previous
→ 重载相关组件
→ 失败自动回滚
```

远程清单不直接在 LuCI 中完整渲染，只显示数量、大小、更新时间、摘要和少量预览。

### 6.6 迁移工具

命令：

```sh
routepolicyctl import-legacy /etc/splitroute
```

导入内容：

- 旧人工域名清单。
- 旧人工 IPv4/CIDR 清单。
- 旧自动清单作为初始 last-known-good。
- 旧更新时间和关键参数，能够识别时才导入。

导入后生成：

```text
/etc/routepolicy/.legacy-imported
/etc/routepolicy/state/legacy-import-report.json
```

导入只复制和转换，不删除旧文件。

## 7. LuCI 实现任务

### 7.1 运行状态页

显示：

- 服务是否启用、运行、配置是否已应用。
- 三个逻辑接口及其实际设备、地址和在线状态。
- main 默认路径是否存在。
- 策略表是否包含真实默认路由和 blackhole。
- SmartDNS 是否运行、适配片段是否加载。
- 四个集合的元素数量和规则累计字节数。
- 上次更新、上次回滚和最近错误。

### 7.2 基础设置页

- 接口使用 LuCI 网络选择器，不允许任意文本填写设备名。
- 保存只写 UCI；“保存并验证”与“应用”分开。
- 应用前显示将修改的 nftables、ip rule、路由表和 SmartDNS 片段摘要。
- 首次启用时要求用户确认已有 VMM 控制台回退路径。

### 7.3 清单和人工规则页

- 来源 URL 做协议和长度校验。
- 所有用户文本以纯文本节点显示，禁止拼接为 HTML。
- 人工规则保存前返回有效、重复、非法和被过滤数量。
- 大文件编辑通过专用固定接口，不给予通用文件系统权限。

### 7.4 诊断页

至少包括：

```text
检查 UCI
检查接口存在性
检查 main 默认路径
检查 mark/mask 冲突
检查策略表和 blackhole
检查 nftables 表和集合
检查 SmartDNS 配置片段
测试普通 DNS
测试动态集合写入
检查 DNS 重定向
检查 IPv6 配置
检查防火墙 NAT/MSS
检查策略接口网段冲突
检查更新源
```

输出可导出为文本，但自动脱敏本机密钥、认证信息和完整 URL 查询参数。

## 8. 仓库与构建计划

目录：

```text
openwrt-routepolicy/
├── routepolicy/
│   ├── Makefile
│   └── files/...
├── luci-app-routepolicy/
│   ├── Makefile
│   ├── htdocs/...
│   └── root/...
├── tests/
│   ├── fixtures/
│   ├── converters/
│   └── integration/
├── .github/workflows/build.yml
├── LICENSE
└── README.md
```

构建策略：

1. 第一阶段只保证 OpenWrt 25.12 x86_64。
2. 核心脚本、ucode 和 JavaScript稳定后，再测试 `PKGARCH:=all`。
3. GitHub Actions 下载固定 25.12 SDK，构建两个 APK。
4. Release 附带 APK、SHA-256、版本说明和升级注意事项。
5. 不在仓库中加入任何实际用户地址、实际清单 URL、解析服务器地址或本地清理脚本。

版本建议：

```text
0.1.0  核心静态规则和状态
0.2.0  SmartDNS动态集合和清单更新
0.3.0  LuCI完整管理和诊断
0.4.0  迁移、暖启动和回滚增强
1.0.0  在目标设备持续运行并通过全部验收
```

## 9. 测试计划

### 9.1 自动测试

- shell 语法和 ShellCheck。
- ucode 语法检查。
- JavaScript lint。
- 每种清单格式的输入/输出 fixture。
- HTML 错误页、空文件、非法 CIDR、IPv6、重复项和数量骤降测试。
- 生成 nftables 后运行 `nft -c`。
- UCI 配置边界值和恶意字符串测试。

### 9.2 虚拟机集成测试

场景：

1. 只有默认接口在线。
2. 策略接口在线。
3. 策略接口中途断开并恢复。
4. SmartDNS 重启。
5. firewall 重载。
6. network 重载。
7. 清单更新成功、下载失败、内容异常、转换失败。
8. OpenWrt 完整重启。
9. 安装、升级、停用、卸载、重新安装。
10. LuCI 低权限用户只能执行授权动作。

### 9.3 目标设备验收

- 安装 APK 不改变网络。
- 导入后新旧人工规则数量一致。
- 启用新服务后默认路径不变。
- 策略规则命中后走策略接口。
- 策略接口断开后命中流量被阻断，不落到默认路径。
- 动态 IP 按 TTL 写入和过期。
- 更新失败仍使用 previous/current。
- 重启后服务顺序正常。
- 旧脚本清理后无重复 cron、服务、nftables 表或 UCI 规则。

## 10. 目标设备安装和迁移路线

### 步骤 A：备份

```sh
sysupgrade -b /tmp/before-routepolicy.tar.gz
```

另行备份：

```text
/etc/config
/etc/splitroute
/etc/smartdns/custom.conf
/etc/crontabs/root
```

### 步骤 B：安装但不启用

```sh
apk add --allow-untrusted ./routepolicy-*.apk
apk add --allow-untrusted ./luci-app-routepolicy-*.apk
```

安装完成后 `enabled=0`，旧方案继续运行。

### 步骤 C：导入旧配置

```sh
routepolicyctl import-legacy /etc/splitroute
routepolicyctl validate
```

在 LuCI 检查人工规则、来源和接口映射。

### 步骤 D：并行预检

```sh
routepolicyctl render
routepolicyctl diagnose
```

确认候选 nftables 和路由表，不应用。

### 步骤 E：切换控制权

1. 暂停旧 cron。
2. 在 LuCI 中启用 routepolicy。
3. 执行 `routepolicyctl apply`。
4. 验证新表 `inet routepolicy`、策略路由表和 SmartDNS 片段。
5. 保留旧文件但不再让旧服务修改系统。

### 步骤 F：观察

至少完成：

- 默认路径测试。
- 策略路径测试。
- 策略接口断开测试。
- DNS TTL 动态集合测试。
- 更新和回滚测试。
- network/firewall/SmartDNS 重载测试。

### 步骤 G：清理旧脚本

先预演：

```sh
sh cleanup-legacy-splitroute-after-package-install.sh
```

确认输出后实际执行：

```sh
sh cleanup-legacy-splitroute-after-package-install.sh --apply
```

建议通过 VMM 控制台确认后重启一次；也可明确选择：

```sh
sh cleanup-legacy-splitroute-after-package-install.sh --apply --reload-network
```

### 步骤 H：最终验收

```sh
routepolicyctl validate
routepolicyctl diagnose
ip -4 rule show
ip -4 route show table 200
nft list table inet routepolicy
```

确认旧内容不存在：

```sh
/etc/init.d/splitroute
/usr/libexec/splitroute
/etc/splitroute
旧 splitroute cron 行
inet splitroute nftables 表
network.splitroute_usb_rule
network.splitroute_usb_blackhole
```

## 11. 本地清理脚本行为

本地脚本默认只预演，`--apply` 后执行：

1. 检查 `routepolicy` 已安装、运行并通过校验。
2. 检查旧目录已导入并存在迁移标记。
3. 将网络、防火墙、DHCP、SmartDNS、cron 和旧目录打包到 `/root`。
4. 停止并禁用旧 `splitroute` 服务。
5. 只删除旧 splitroute 的 cron 行。
6. 精确删除旧 SmartDNS 对接行，不删除用户解析服务器配置。
7. 删除此前手册创建的两个命名 UCI 网络段。
8. 删除旧 `inet splitroute` 表。
9. 将 `/etc/splitroute` 移到 `/root/legacy-splitroute-files-时间戳`，不直接销毁。
10. 删除不属于任何软件包的旧脚本和 hotplug 文件。
11. 重新加载 `routepolicy` 和 SmartDNS。
12. 输出完整备份位置和最终验证命令。

该脚本永远不由 APK 自动执行，也不进入公开仓库。

## 12. 完成定义

项目达到 1.0.0 前必须满足：

- 核心包和 LuCI 包均可在 OpenWrt 25.12 x86_64 干净系统安装。
- 安装默认不改变网络。
- 用户不编辑 shell/nft 文件即可完成日常设置。
- 所有配置先校验后应用，失败自动保留上一版。
- 策略接口断开时严格阻断有效。
- SmartDNS 动态集合按 TTL 工作，软件包不创建上游解析服务器。
- 远程清单更新有格式、数量、HTML、地址范围和原子回滚保护。
- 升级、停用、卸载和重启均不会留下重复规则。
- LuCI 不提供任意命令执行，动态文本均安全转义。
- 旧手工方案可以无损导入，并可通过本地脚本安全清理。
