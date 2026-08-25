# SmartDNS 管理功能实施方案

> 状态：需求已确认，等待实施
>
> 日期：2026-08-25
>
> 适用基线：OpenWrt 25.12 x86_64，`routepolicy` / `luci-app-routepolicy` 0.1.1 之后的版本

## 1. 实施目标

在现有 RoutePolicy 项目中新增一个独立的 SmartDNS 管理页面，使管理员无需安装官方 `luci-app-smartdns`，即可安全完成 SmartDNS 服务、上游服务器、缓存与 TTL、本地主机名、全局 DNS 行为和可选仪表盘的日常管理；同时保持与官方 LuCI 共存、保留未知配置、可预览、可验证、可回滚，并且不把 SmartDNS 应用与 RoutePolicy 的路由/nftables 应用混在一起。

本目标包含以下强制交付物：

1. 修复 `90-routepolicy.conf` 目前“文件存在但未必被 SmartDNS 加载”的缺陷。
2. 实现本方案约定的 SmartDNS 核心、LuCI、RPC、迁移、诊断和测试能力。
3. **更新 `README.md`**，完整说明新功能、配置所有权、默认值/建议值、危险操作、迁移与卸载行为。
4. 同步更新 `SECURITY.md`，移除“不创建上游 DNS、只管理附加片段”等已经失效的旧边界描述。
5. 保持现有 RoutePolicy、LuCI、构建和发布契约测试通过，并新增 SmartDNS 合同测试。

完成定义：代码、测试、README 和 SECURITY 必须在同一实施变更中一致落地；只实现页面而未更新 README，不视为完成。

## 2. 范围与非目标

### 2.1 纳入范围

- SmartDNS 服务启停、UDP 端口、TCP DNS、IPv6 监听、dnsmasq 自动配置。
- 上游 DNS 的新增、编辑、启用/停用和删除。
- 缓存、预取、过期缓存应答、缓存持久化和 TTL 限制。
- IPv4/IPv6 双栈优选、AAAA 屏蔽、HTTPS/SVCB 屏蔽的三态设置。
- 静态本地 IP、主机名和别名，以及被动读取 DHCP 租约名称。
- 检测并管理可选的 `smartdns-ui` 仪表盘。
- 保存候选配置、验证、预览、独立应用、冲突检测和失败回滚。
- 官方 LuCI 共存、旧配置迁移、卸载清理和诊断。

### 2.2 明确不纳入

- 不依赖、不安装、不复制官方 `luci-app-smartdns`；也不接管其页面。
- 不提供任意 SmartDNS 配置文本、`addition_arg`、任意命令或任意路径编辑入口。
- 不提供独立的“客户端最小 TTL”：SmartDNS 核心没有对应的独立选项。
- 不提供虚假的“保留过期缓存但禁止后台刷新”开关；本期只提供 `serve_expired` 总开关。
- 不提供单独的“过期缓存预取时间”设置。
- 不在仪表盘页面管理密码、终端、CORS、HTTPS 或证书。
- 不自动创建、启用、启动、修改或重载 DHCP/dnsmasq。
- 不改变当前仅支持 OpenWrt 25.12 x86_64 的发布范围。

## 3. 当前状态与必须修复的缺口

1. `routepolicy/files/usr/libexec/routepolicy/render` 会生成 `/etc/smartdns/conf.d/90-routepolicy.conf`，但当前应用流程没有确保它出现在 `/etc/config/smartdns` 的 `conf_files` 列表中。
2. OpenWrt SmartDNS init 脚本只加载显式登记的附加配置；仅生成文件并重载不能证明规则生效。
3. 当前 `status` 的 `fragment_loaded` 只检查文件存在，会产生“存在但未载入”的假阳性。
4. `90-routepolicy.conf` 中的策略域名规则固定带有 `-no-serve-expired`，会覆盖全局过期缓存策略。
5. 当前 LuCI 只允许开关 RoutePolicy 的 SmartDNS 适配并填写已有组名，不能管理 SmartDNS 本身。
6. 当前 README/SECURITY 明确声称不创建上游服务器；新增 CRUD 后必须修订。

以上六项都是实施阻断项，不能只新增 UI 而保留旧行为。

## 4. 架构与配置所有权

### 4.1 单页入口，分层存储

LuCI 增加一个菜单页：`服务 → 路由策略 → SmartDNS`。页面内部使用“服务、上游、缓存与 TTL、本地主机、仪表盘、状态”标签；这仍是一个页面，不引入官方 LuCI 依赖。

“一个页面”不等于“全部写进 90 文件”。90 片段加载顺序靠后，确实具有覆盖能力，因此更不能重复生成标准服务/上游/缓存字段：标准字段只精确写 UCI，90 只放 RoutePolicy 规则，91 只补 init 未映射的核心选项。用户仍然只需查看和操作这一个页面，但不会形成两个相互遮蔽的配置来源。

| 存储位置 | 内容 | 所有权与生命周期 |
|---|---|---|
| `/etc/config/smartdns` | 服务、监听、上游、缓存、TTL、全局行为、仪表盘插件可映射字段；以及 RoutePolicy 两个片段的 `conf_files` 登记 | 用户的标准 SmartDNS 配置；只做精确字段/段修改，保留未知字段和段，卸载 RoutePolicy 时不删除 |
| `/etc/smartdns/conf.d/90-routepolicy.conf` | RoutePolicy domain-set/nftset/domain-rules、`nftset-timeout yes`、本地主机文件引用和 PTR 扩展 | RoutePolicy 拥有；是否生成由 SmartDNS 适配开关决定，但不受 `routepolicy.main.enabled` 限制 |
| `/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf` | SmartDNS 核心支持但 OpenWrt init 当前未映射的标准项，例如 `serve-expired-reply-ttl`、`cache-checkpoint-time` | RoutePolicy 拥有；由相应额外设置决定，独立于路由策略启停 |
| `/etc/routepolicy/user.d/local-hosts.list` | 静态 IP、主名称和别名 | RoutePolicy 管理的用户配置；升级保留，卸载时移除引用，数据按包配置文件保留策略处理 |
| `/tmp/routepolicy/` | 候选、预览、锁和临时验证结果 | 运行时状态；权限收紧，重启可丢失，不作为唯一配置来源 |
| `/etc/routepolicy/state/` | 最近成功应用基线及待应用状态 | 仅用于事务回滚；0600，不暴露为任意下载接口 |

### 4.2 标准 UCI 修改规则

- 没有 `config smartdns` 根段时，页面显示“未初始化”；只在用户点击“初始化 SmartDNS”后创建最小根段。
- 存在多个 SmartDNS 根段时拒绝写入，给出段名和修复提示；不得默选第一个或重写整个文件。
- 上游 `config server` 使用稳定的 UCI 段标识读写；匿名段发生外部重排时视为冲突，不猜测合并。
- 未触碰的选项保持缺省，不因打开页面而写入默认值。
- 三态字段使用“继承/开启/关闭”：继承表示删除该 option，开启写 `1`，关闭写 `0`。
- 编辑既有段时保留页面不认识的 option；删除上游段必须明确确认，删除行为本身除外。

### 4.3 `conf_files` 登记

- 幂等登记：最多各保留一个 `90-routepolicy.conf` 和 `91-routepolicy-smartdns-extra.conf`。
- 迁移时接管既有的同名手工登记并消除重复，不修改其他 `conf_files` 项。
- 关闭相应功能或卸载时只移除 RoutePolicy 拥有的两个列表值。
- 应用后必须检查实际生成的 `/var/etc/smartdns/smartdns.conf` 中存在预期 `conf-file` 行；不能再以片段文件存在作为“已加载”的依据。
- 登记、渲染、重载或生效验证任一步失败，都恢复原 UCI、原片段和原本地主机文件。

## 5. 功能设计

### 5.1 服务管理

提供：

- 启用/停用 SmartDNS 服务。
- UDP 监听端口；默认/标准端口为 53。
- TCP DNS 开关。
- IPv6 监听开关。
- dnsmasq 自动配置三态开关。
- 当前运行状态、实际监听端口、最近应用结果、候选是否未应用、90/91 实际加载状态。

SmartDNS 的保存和应用独立于 `routepolicy.main.enabled`。应用 SmartDNS 时不得重建 nftables、策略路由或远程清单；应用 RoutePolicy 时也不得暗中提交 SmartDNS 页面未应用的候选。

### 5.2 上游 DNS 管理

每个上游支持：

- 显示名称和启用/停用。
- UDP、TCP、TLS、HTTPS、QUIC、H3。
- IP、域名或 URL，以及端口。
- 服务器组。
- 排除默认组。
- SNI（`host_name`）。
- HTTP Host。
- fallback。
- proxy。
- interface。
- set mark。

约束：

- 不暴露 `addition_arg`。
- 保留既有服务器的未知字段。
- 删除或停用后若使 RoutePolicy 引用的 `policy`（或用户配置的策略组）没有可用服务器，阻止应用并指出受影响组。
- 单纯 SmartDNS 没有显式上游时，只要有效的 resolv-file 路径仍可工作，不强制伪造默认服务器。
- 帮助文本提示官方实践建议：上游总数约 10 个，并尽量使用不同运营者和协议；这是建议，不是硬上限。

### 5.3 缓存、预取和 TTL

| 设置 | 表达方式 | 默认/建议与校验 |
|---|---|---|
| 域名预取 `prefetch_domain` | 继承/开/关 | 核心默认不启用；热门域名可提高命中率，但增加空闲 CPU 和上游查询 |
| 过期缓存应答 `serve_expired` | 继承/开/关 | SmartDNS 核心默认开启，建议开启以减少等待；一个总开关，不伪造“只关刷新” |
| 缓存条数 `cache_size` | 整数 | `-1` 按内存自动，`0` 禁用缓存，正数为条目数；推荐 `-1`，同时显示实际值 |
| 持久化 `cache_persist` | 继承/0/1 | `0` 关闭、`1` 开启；核心可能在可用内存大于 128 MiB 时自动选择，但 OpenWrt wrapper 默认值为 0，页面必须区分继承和显式值 |
| 缓存文件 `cache_file` | 受限绝对路径 | 仅允许 `/etc/smartdns/`、`/tmp/`、`/var/cache/` 下的普通非符号链接文件 |
| 检查点间隔 `cache_checkpoint_time` | 秒 | `0` 关闭周期写入，非零必须 `>=120`；参考默认 86400；位于 `/etc` 且小于 3600 时警告闪存写入 |
| 内部最小 TTL `rr_ttl_min` | 正整数或继承 | 官方建议 600–1800 秒；必须 `>0` |
| 内部最大 TTL `rr_ttl_max` | 正整数或继承 | 无统一推荐，默认继承；官方文档示例 600；必须 `>0` |
| 客户端最大 TTL `rr_ttl_reply_max` | 正整数或继承 | 无统一推荐，默认继承；官方文档示例 60；大于内部最大 TTL 时允许保存但提示不会增加实际 TTL |
| 过期应答 TTL `serve_expired_reply_ttl` | 正整数或继承 | 核心默认 3 秒；由 91 片段落地 |

交叉校验：同时填写内部最小/最大 TTL 时，必须满足最小值不大于最大值。页面明确说明不存在“客户端最小 TTL”。关闭缓存持久化会按官方行为删除当前缓存文件，必须展示精确目标并二次确认；缓存数据不纳入配置事务回滚。

实施时移除 `90-routepolicy.conf` 策略域名规则中的固定 `-no-serve-expired`，让这些域名继承全局设置。

### 5.4 全局 DNS 行为

以下三项全部采用继承/开/关，不在安装或升级时自动物化：

| 设置 | 0 | 1 | 说明 |
|---|---|---|---|
| `dualstack_ip_selection` | 不执行 IPv4/IPv6 双栈优选 | 执行双栈优选 | 页面显示 OpenWrt 当前实际继承结果，避免把核心默认与 wrapper 默认混为一谈 |
| `force_aaaa_soa` | 允许 AAAA（类型 28） | 对 AAAA 返回 SOA | 开启属于高影响操作，需确认 |
| `force_https_soa` | 允许 HTTPS/SVCB（类型 65） | 对 HTTPS/SVCB 返回 SOA | 开启属于高影响操作，需确认 |

帮助文本统一解释：缺省=继承，`0`=关闭，`1`=开启；任何可能接受 `-1` 的数值字段还要单独解释 `-1`，不能把布尔语义套在数值上。

### 5.5 本地 IP 与主机名

文件格式：

```text
192.168.1.10 nas nas.lan storage.lan
2001:db8::10 nas6 nas6.lan
```

规则：

- 第一列为 IPv4 或 IPv6，第二列为主名称，后续为别名。
- 所有名称提供 A/AAAA 正向查询；PTR 只返回主名称。
- 同一名称不得指向不同 IP；同一 IP 可以有多个名称。
- 可选本地域后缀，默认留空。例如设置 `lan` 时，界面统一处理 `nas` 与 `nas.lan` 并检测冲突。
- 被动读取 dnsmasq/odhcpd 已有租约用于展示动态名称；静态 RoutePolicy 名称优先。
- DHCP 未安装、未启用、未运行或没有租约时，只显示“无动态名称”；不得创建配置、启动服务或重载 DHCP。
- 仪表盘显示友好名称属于兼容性/尽力而为；硬验收以实际 A、AAAA、PTR 查询成功为准。

### 5.6 dnsmasq 自动配置

页面必须先解释官方 SmartDNS init 脚本的目的和副作用：

- SmartDNS 使用 53 端口时，官方流程会关闭 dnsmasq 的 DNS 监听（`port=0`），由 SmartDNS 直接占用 53；dnsmasq 的 DHCP 功能可以继续运行。
- SmartDNS 使用非 53 端口时，dnsmasq 保持监听 53，并把 DNS 转发到 `127.0.0.1#<SmartDNS 端口>`。
- 官方脚本还可能调整 `noresolv`、重绑定保护、`domainneeded`、DHCP option 6，并重启 dnsmasq。

守卫：

- 三态默认继承，不能在页面加载时自动写 `0` 或 `1`。
- 若有效值为开启，但 dnsmasq 未启用或未运行，阻止 SmartDNS 应用并要求用户显式关闭；绝不自动启动 dnsmasq。
- 若 dnsmasq 正在运行，应用前列出会受影响的 `/etc/config/dhcp` 字段及服务动作，并要求确认。
- RoutePolicy 自己不直接启停、修改或重载 dnsmasq；只有用户确认后允许 SmartDNS 官方 init 流程执行其既定动作。

### 5.7 可选仪表盘

- `smartdns-ui` 是可选插件，不加入硬依赖。
- 检测到受支持插件后，提供启用/停用、端口、数据目录、日志保留和“打开仪表盘”。
- 默认端口显示为 6080。
- 插件缺失时禁止启用并说明需要安装的包，不静默降级。
- 启用前明确确认：本项目不会创建防火墙放行规则；必须修改默认凭据；仪表盘会监听所配置端口。
- 仅使用检测到的插件版本所支持的标准字段；不猜测或生成私有配置。

## 6. 保存、应用与回滚事务

页面提供三个清晰分离的动作：

1. **保存 SmartDNS**：持久化候选配置，但不重载/启停服务。
2. **验证并应用 SmartDNS**：只应用 SmartDNS 候选。
3. **应用 RoutePolicy**：沿用现有路由策略应用，不隐式提交 SmartDNS 候选。

SmartDNS 保存/应用流程：

1. 页面加载时，后端保存受限的服务器端基线快照并返回不含路径能力的临时版本令牌。
2. 保存前对当前 UCI 导出与基线做精确比较；若 SSH、官方 LuCI 或其他页面已经修改，则拒绝并要求刷新。比较采用规范化配置文本，不新增例行 hash。
3. 第一次保存未应用候选时保存“最近运行/已应用基线”；后续保存只更新候选，不覆盖该基线。
4. 验证根段数量、字段类型、协议组合、组引用、TTL 关系、路径、dnsmasq 守卫、仪表盘插件和本地主机冲突。
5. 展示字段级预览和服务动作；危险操作要求单独确认。
6. 精确提交 SmartDNS UCI、90/91 登记和 RoutePolicy 自有文件。
7. 按目标状态启停或重载 SmartDNS。
8. 检查服务状态、实际监听和 `/var/etc/smartdns/smartdns.conf` 中的 90/91 `conf-file` 行。
9. 成功后更新最近应用基线并清除候选标记；失败时恢复原 UCI、90/91、本地主机文件和服务状态，然后报告失败步骤。

危险操作包括：删除上游、停用 SmartDNS、自动配置 dnsmasq、关闭缓存持久化并删除缓存、开启 AAAA 屏蔽、开启 HTTPS/SVCB 屏蔽、启用仪表盘。

## 7. 安全与权限设计

- LuCI 页面不直接获得整个 `smartdns` UCI 的浏览器写权限；通过枚举、受限的 RPC 方法调用核心事务层。
- RPC 只接受固定 schema：布尔/三态、有限协议枚举、长度受限字符串、数字范围和结构化服务器列表。
- 所有子进程使用固定 argv，不经过 shell 拼接；请求字段不能成为命令、路径或 SmartDNS 原始参数。
- 本地主机和缓存路径分别使用固定文件或目录允许列表；拒绝相对路径、`..`、目录、符号链接和越界解析路径。
- 基线/候选文件权限为 0600，限制大小并定期清理；不通过 RPC 提供任意文件读取。
- 官方 LuCI 若已安装，仍可访问标准 UCI；本页面用冲突检测处理并发，不覆盖未知字段。
- ACL 只增加明确命名的 `smartdns_read`、`smartdns_save`、`smartdns_validate`、`smartdns_apply`、`smartdns_discard_candidate`、`read_local_hosts`、`write_local_hosts` 和仪表盘状态方法，不增加通配符、`file` 或 `exec` 权限。

## 8. 代码实施工作包

### 工作包 A：核心配置模型与只读发现

主要文件：

- 扩展 `routepolicy/files/usr/sbin/routepolicyctl`。
- 新增 `routepolicy/files/usr/libexec/routepolicy/smartdns-*` 深模块，集中处理读取、规范化、验证、预览、保存和应用。
- 扩展 `routepolicy/files/usr/libexec/routepolicy/common` 的固定路径、锁和安全文件辅助函数。
- 扩展 `routepolicy/Makefile` 安装清单与 conffiles。

产物：根段歧义检测、上游规范化模型、有效值/继承值发现、服务与插件状态、候选版本令牌。此阶段只读，不改变现网。

### 工作包 B：片段登记与事务应用

主要文件：

- 修改 `render`、`apply`、`status`、`diagnose`。
- 新增 91 渲染、`conf_files` 幂等登记、真实加载检查和 SmartDNS 独立事务。
- 从 90 的 domain-rules 移除 `-no-serve-expired`。

产物：90/91 能被官方 init 脚本实际加载；失败恢复 UCI、片段、主机文件和服务状态；RoutePolicy 与 SmartDNS 分开应用。

### 工作包 C：上游、缓存、TTL 与全局行为

实现标准 UCI 的精确字段修改、服务器 CRUD/启停、组引用检查、三态、不物化缺省、91 额外选项和数值/路径校验。

### 工作包 D：本地主机与 DHCP 被动发现

- 新增 `/etc/routepolicy/user.d/local-hosts.list` 模板/保留声明。
- 实现规范化、别名/后缀冲突检测、原子写入、90 引用和 PTR 扩展。
- 只读解析现有租约；任何情况下都不主动修改 DHCP。

### 工作包 E：可选仪表盘适配

检测已安装 `smartdns-ui` 的实际版本和标准配置字段，再启用受限编辑；缺失或版本不支持时只展示诊断和安装提示。

### 工作包 F：LuCI 单页与 RPC

主要文件：

- 新增 `luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/smartdns.js`。
- 扩展 `luci-app-routepolicy/htdocs/luci-static/resources/routepolicy/api.js`。
- 扩展 `luci-app-routepolicy/root/usr/libexec/rpcd/routepolicy` 的固定方法和 schema 校验。
- 扩展 menu JSON、ACL JSON 与 `tests/luci/check-static.ps1`。
- 调整 `settings.js`，保留 RoutePolicy 适配开关，但链接到新的 SmartDNS 管理页并删除“不会创建上游”的旧说明。

页面需要显示来源：显式值、继承值、实际生成值；所有危险操作都展示影响摘要。

### 工作包 G：迁移、卸载与文档

- 首次运行识别已经手工登记的 `90-routepolicy.conf`，归一为一个列表项。
- 保留已有 SmartDNS 根段、服务器、未知 option 和其他片段。
- 卸载只移除 90/91 登记和 RoutePolicy 自有运行片段，不删除 `/etc/config/smartdns` 或用户上游。
- 更新 README、SECURITY 和必要的发布说明；版本号按发布流程统一提升。

## 9. README 与文档更新清单

`README.md` 是本实施目标的一部分，至少新增或改写：

1. SmartDNS 管理功能总览和页面入口。
2. `/etc/config/smartdns`、90、91、本地主机文件的所有权边界。
3. “SmartDNS 服务启用”“RoutePolicy 启用”“90 适配启用”三者的区别。
4. 不依赖官方 `luci-app-smartdns`，但支持共存；发生外部改动时会拒绝覆盖。
5. 上游协议和 CRUD 范围，以及未知字段保留策略。
6. 预取、过期应答、缓存持久化、TTL、继承/0/1/-1 的含义和官方建议值。
7. dnsmasq 自动配置在 53/非 53 端口下的具体副作用和“不自动启动 DHCP”守卫。
8. 本地主机文件格式、主名称/PTR、别名、后缀与 DHCP 被动读取。
9. 可选仪表盘依赖、6080 默认端口、凭据和防火墙警告。
10. 从手工 `conf_files` 登记迁移、失败回滚、卸载保留和故障排查。
11. 继续明确支持范围为 OpenWrt 25.12 x86_64。

`SECURITY.md` 同步改写安全边界：承认页面可以在用户授权下管理上游和标准 SmartDNS UCI，同时强调受限 RPC、路径允许列表、危险确认、外部冲突拒绝和精确卸载。旧的“不创建上游 DNS”承诺必须删除。

## 10. 测试计划

### 10.1 核心合同测试

- 无根段时只读不创建；显式初始化创建最小根段。
- 多根段拒绝写入。
- 未触碰字段继续缺省，未知字段和未知服务器 option 保留。
- 上游所有协议和字段 CRUD 往返不丢失；启停与删除确认有效。
- 策略组被清空时阻止应用；合法 resolv-file 场景不误拦。
- 90/91 登记幂等、无重复、关闭/卸载只移除自有项。
- 实际生成配置包含 90/91；仅文件存在不再判定 loaded。
- SmartDNS 重载或验证失败时完整恢复 UCI、片段、本地主机和服务状态。
- 页面基线过期时拒绝保存/应用，不自动合并匿名段。
- prefetch/serve-expired 三态和 91 选项渲染正确。
- `cache_size` 的 `-1/0/正数`、checkpoint 的 `0/>=120`、TTL 关系和允许路径校验正确。
- 关闭持久化只在确认后删除精确缓存文件；拒绝符号链接和越界路径。
- dnsmasq 未运行时不启动并阻止有效 auto-config；运行时返回完整预览。
- DHCP 不存在时不产生任何配置或服务写操作。
- 本地主机 IPv4/IPv6、别名、后缀和冲突校验；集成环境验证 A/AAAA/PTR。
- 仪表盘插件缺失时阻止启用；存在时只写受支持字段。
- 应用 SmartDNS 不调用 RoutePolicy nft/路由流程；应用 RoutePolicy 不提交 SmartDNS 候选。

### 10.2 LuCI 与权限合同测试

- menu/ACL JSON 可解析，所有 JS 通过 `node --check`。
- API 方法、RPC 方法和 ACL 三者完全对应。
- RPC 不包含通配 UCI、任意 file/exec、shell 拼接或请求控制路径。
- 三态字段不会因页面渲染产生默认 option。
- 危险操作没有确认时无法提交。
- 现有 `tests/luci/check-static.ps1` 与包安全合同继续通过。

### 10.3 回归与目标机验收

- 运行 `tests/core/run.sh`、转换器测试、LuCI 静态检查、CI 静态检查和 package contract tests。
- 在 OpenWrt 25.12 x86_64 干净环境、已有 SmartDNS 配置环境、安装官方 LuCI 环境各验收一次。
- 验证 UDP/TCP 查询、IPv4/IPv6 监听、A/AAAA/PTR、缓存过期行为、策略域名组、重启恢复和卸载保留。
- 验收 README/SECURITY 不再含与实现矛盾的旧承诺。

## 11. 实施顺序与合并门槛

1. A 只读模型与测试先落地。
2. B 修复 90 加载缺陷并建立事务边界；未通过回滚测试前不开发危险写操作。
3. C、D、E 分模块增加能力与合同测试。
4. F 接入 LuCI，浏览器层不重复实现核心校验。
5. G 完成迁移、卸载、README、SECURITY 和发布说明。
6. 全套测试及三类目标环境通过后才能发布。

任何阶段若需要扩大 RPC 权限、直接写 `/etc/config/dhcp`、接管官方 LuCI 或新增任意文本配置入口，均视为偏离本方案，必须重新确认，不能作为实现便利自行加入。

## 12. 验收清单

- [ ] SmartDNS 页面在 RoutePolicy 停用时仍能独立工作。
- [ ] 90/91 已登记且实际加载，状态不再假阳性。
- [ ] 服务、上游、缓存/TTL、三项 DNS 行为、本地主机和可选仪表盘满足本方案。
- [ ] 所有继承项保持缺省，未知配置不丢失。
- [ ] dnsmasq/DHCP 守卫、危险确认、冲突拒绝和失败回滚可复现。
- [ ] 官方 LuCI 未安装时可用，已安装时安全共存。
- [ ] 卸载不删除用户 SmartDNS 主配置和上游，只清理 RoutePolicy 自有登记/片段。
- [ ] 新旧核心、LuCI、CI、包合同测试全部通过。
- [ ] `README.md` 已按第 9 节更新并与实现一致。
- [ ] `SECURITY.md` 已同步更新安全边界。
- [ ] OpenWrt 25.12 x86_64 目标机验收通过。

## 13. 官方参考

- [SmartDNS 配置文档](https://pymumu.github.io/smartdns/en/configuration/)
- [SmartDNS FAQ 与缓存建议](https://pymumu.github.io/smartdns/en/faq/)
- [SmartDNS 官方示例配置](https://github.com/pymumu/smartdns/blob/master/etc/smartdns/smartdns.conf)
- [SmartDNS OpenWrt init 脚本](https://github.com/pymumu/smartdns/blob/master/package/openwrt/files/etc/init.d/smartdns)
- [官方 luci-app-smartdns 页面实现](https://github.com/pymumu/luci-app-smartdns/blob/master/htdocs/luci-static/resources/view/smartdns/smartdns.js)
