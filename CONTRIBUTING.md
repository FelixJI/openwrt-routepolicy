# 参与贡献

欢迎提交 issue 和 pull request。项目当前发布目标仅为 **OpenWrt 25.12 x86_64**，请勿把尚未验证的平台兼容性作为既有能力描述。

## 提交前检查

请保持修改小而聚焦，并在本地执行：

```sh
sh tests/ci/static-checks.sh
sh tests/ci/validate-workflows.sh
sh tests/ci/package-contract-tests.sh
python3 -B tests/ci/release-version-test.py
```

涉及包行为的修改还应在 OpenWrt 25.12 x86_64 SDK 中构建两个包。不要提交 SDK、APK、用户配置、实际上游 DNS、真实清单 URL、令牌、日志或设备地址。

涉及核心运行时，执行 `sh tests/converters/run.sh` 和 `sh tests/core/run.sh`；涉及 LuCI，执行 `pwsh -File tests/luci/check-static.ps1`。Windows 可用 Git Bash 执行 shell 测试。YAML 解析需要 Ruby；缺工具时应明确记录未验证，不把跳过当成通过。真实 nft 内核、SDK 和 OpenWrt 生命周期验证见 [隔离实验室](tests/integration/openwrt-lab.md)。

## 发版与文档

正式发布按 [发版手册](RELEASE.md) 在默认分支选择 patch/minor/major。无需在日常改动中手动升版本；两个包版本必须一致，发布提交统一设置版本与 release 序号。既有测试中的固定旧版本夹具用于兼容性与降级场景，不随新版本机械替换。

用户行为变化同时更新 [README](README.md)、[操作手册](OPERATIONS.md) 及相关 Release 安装说明。历史实施计划保持明确标识，不用旧计划中的“待实施”推断当前能力。

## 代码与安全约束

- 默认配置必须保持 `enabled=0`；安装、升级和卸载不能接管用户网络。
- 初始化须先预览接口角色、地址及 DHCP/fw4 差异，再由管理员确认。测试必须覆盖共享设备与分离设备两种拓扑、断连超时和外部并发修改；网络演练使用独立虚拟网络与带外控制台。
- 不得添加任意 shell、任意 nft 文本或任意文件路径的 LuCI/ubus 接口。
- 用户输入必须逐项校验，显示时按纯文本处理。
- 修改路由、nftables、SmartDNS 或迁移逻辑时，说明失败和回滚路径。
- 本地旧方案清理脚本不属于公开仓库，也不得在软件包安装脚本中调用。

安全问题请按 [SECURITY.md](SECURITY.md) 的方式私下报告，不要公开披露可利用细节。
