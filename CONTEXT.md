# RoutePolicy 领域上下文

## 受管接口

RoutePolicy 配置的 LAN、默认出口、策略出口三个逻辑网络，经 ubus 解析为实际 L3 设备。展示统计时按实际设备去重，同时保留它承担的逻辑角色。

## 本机流量与转发流量

- 本机流量：由 OpenWrt 路由器上的进程产生，进入 nftables output hook。
- 转发流量：从 LAN 等入口进入路由器并被转发，进入 prerouting hook。

两者共享目标分类规则，但使用不同 adapter 处理入口、DNS 和 mark 生命周期。

## 策略标记

由 `mark`/`mark_mask` 指定的单一 bit。`meta mark` 作用于当前数据包，`ct mark` 作用于连接。OUTPUT 新连接已有的 socket/meta mark 是显式意图，不能被空的 `ct mark` 覆盖。

## 接口流量

实际设备的 Linux RX/TX 累计计数器。它是设备口径，可能包含 IPv4、IPv6、非 IP、桥接或其他服务流量。

## 归因 IP 流量

由 RoutePolicy 自有、容量和超时均受限的 nftables 动态 set 统计的 IPv4 packets/bytes。入站键为进入设备与 `ip saddr`，出站键为 SNAT 前的离开设备与 `ip saddr`。它不是接口总量，也不是完整流量审计。

## 生效域名

最近一次应用事务成功后实际交付给 SmartDNS 的规范化 domain-policy/domain-default 规则。候选渲染文件不等同于生效域名。

## 动态业务 IP

SmartDNS 解析域名后写入 `domain_policy4` 或 `domain_default4` 的 IPv4 元素。元素具有 timeout 和当前 expires，但 set 本身不保存产生该 IP 的域名来源。

## 静态业务 IP

人工或订阅 IPv4 清单规范化后写入 `static_policy4` 或 `static_default4` 的永久 IPv4 地址/CIDR。

## active catalog

应用事务成功后原子发布的只读运行态域名目录，用于回答“当前生效域名”。应用失败和回滚必须保留或恢复与实际 SmartDNS 状态一致的 generation。

## 观测快照与查询

- 快照：固定上限、适合周期轮询的接口累计计数和集合摘要。
- 查询：针对服务端枚举数据集的过滤和分页；不得接受任意文件路径、nft 对象或 shell 表达式。

## 会话折线

只存在于当前 LuCI 页面内存中的有限历史。页面重载、关闭或路由器重启后可丢失，不属于持久监控。
