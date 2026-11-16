# 发版操作手册

发布目标为 OpenWrt 25.12 x86_64。日常构建见 `Build OpenWrt packages`，正式发版见 `Release OpenWrt packages`。两者都会执行离线测试并使用固定 25.12.0 SDK 构建；普通构建只上传 Actions artifact，不创建 Release。

## 自动计算版本

1. 将要发布的代码、文档和测试合入默认分支。工作流不会读取维护者电脑上的未提交内容。
2. 打开 Actions → Release OpenWrt packages → Run workflow，选择默认分支。
3. `bump` 选择 `patch`（默认）、`minor` 或 `major`，`tag` 留空。
4. 查看运行摘要中的最终 tag 和源码提交；等待检查、SDK 构建、介质收集及 Release 创建全部完成。

版本基线取两个 Makefile 中的一致 `PKG_VERSION` 与仓库全部正式 `vX.Y.Z` tag 的数值最大值，忽略预发布和其他 tag。例如基线 `0.3.3` 时：

| 选择 | 结果 |
| --- | --- |
| patch | v0.3.4 |
| minor | v0.4.0 |
| major | v1.0.0 |

两个包统一更新版本，`PKG_RELEASE` 重置为 `1`。工作流在 runner 上生成仅更新两个 Makefile 的发布提交，检查和构建使用该提交；成功收集附件后才创建并推送 tag。**默认分支不自动回写版本提交**，后续发版从已有 tag 继续递增。`BUILD-INFO.txt` 的 Source revision 对应发布 tag 的提交，不一定等于触发运行时的分支提交。

自动发版仅允许默认分支。所有发版运行共用并发组，不中断正在进行的发版；不要把排队运行当作可靠的发布队列，应等本次完成后再启动下一次。

工作流需要 `contents: write`，仓库 tag 规则也须允许工作流创建 tag。使用内置 `GITHUB_TOKEN` 推 tag 后不会依赖另一次 push 工作流，构建和发布在本次运行完成。参见 [GitHub 触发规则](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)。

## 发布已有 tag 与失败恢复

`tag` 填写已有的 `vX.Y.Z` 时优先于 `bump`：检出精确 tag，两包 `PKG_VERSION` 必须与 tag 一致；不修改源码、不自动升版。也保留推送 `v*` tag 的入口，但最终只接受正式 `vX.Y.Z`。旧 tag 运行其当时的代码和测试，旧附件格式可能不含当前安装器。

- 检查或构建失败、尚未推 tag：修复默认分支后重新运行自动发版，不占用版本号。
- tag 已推送但 Release 创建失败：核对该 tag 与失败运行的源码提交，再填写该 tag 重试；不要重新选择 patch，否则会产生下一个版本。
- Release 已存在或附件部分上传：先核对远端资产与运行日志。工作流不会覆盖已有 Release、强推 tag 或静默替换附件；本流程不自动修补部分发布。
- tag 被他人抢先创建或权限不足：推送失败即停止，不覆盖远端。检查冲突、仓库权限或 tag 保护后再处理。

发布旧 tag 的手动重试应从包含本版工作流的默认分支启动，再填写目标 tag。首次使用下拉入口前，工作流必须已合入默认分支。

## 验收与交付

核对 Actions 中所有检查与 SDK 构建结论、Release 的 tag/commit 对应关系以及附件清单：恰好两个应用 APK、`install.sh`、`INSTALL.txt`、`BUILD-INFO.txt`、`SHA256SUMS`，以及按 feed 前缀命名的 `*-packages.adb` 和构建产生的 `*-index.json`。以本次实际 SDK feed 输出确定索引的精确数量与名称。

`prepare-release.sh` 生产既有 `SHA256SUMS`，安装端消费并在损坏时拒绝安装。发布完成后不为再次校验摘要而下载最终附件；维护者默认核对 Actions、Release 元数据、资产清单及提交关系。真实安装、网络切换、回滚与重启能力还需按 [集成验证](tests/integration/openwrt-lab.md) 在隔离 OpenWrt 环境验证，不能由离线测试推断。

用户安装和升级使用完整介质及 `install.sh`，见 [操作手册](OPERATIONS.md)。发布说明需列出配置兼容性变化和已验证范围，不再把所有升级实例描述为“默认禁用”。
