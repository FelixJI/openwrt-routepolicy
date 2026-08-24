# 参与贡献

欢迎提交 issue 和 pull request。项目当前发布目标仅为 **OpenWrt 25.12 x86_64**，请勿把尚未验证的平台兼容性作为既有能力描述。

## 提交前检查

请保持修改小而聚焦，并在本地执行：

```sh
sh tests/ci/static-checks.sh
sh tests/ci/validate-workflows.sh
```

涉及包行为的修改还应在 OpenWrt 25.12 x86_64 SDK 中构建两个包。不要提交 SDK、APK、用户配置、实际上游 DNS、真实清单 URL、令牌、日志或设备地址。

## 代码与安全约束

- 默认配置必须保持 `enabled=0`；安装、升级和卸载不能接管用户网络。
- 不得添加任意 shell、任意 nft 文本或任意文件路径的 LuCI/ubus 接口。
- 用户输入必须逐项校验，显示时按纯文本处理。
- 修改路由、nftables、SmartDNS 或迁移逻辑时，说明失败和回滚路径。
- 本地旧方案清理脚本不属于公开仓库，也不得在软件包安装脚本中调用。

安全问题请按 [SECURITY.md](SECURITY.md) 的方式私下报告，不要公开披露可利用细节。
