# LuCI 静态检查

在宿主机运行：

```powershell
powershell -ExecutionPolicy Bypass -File tests/luci/check-static.ps1
```

检查 JSON、所有 LuCI JavaScript 的语法，以及 RPC 方法白名单和 ACL 是否意外包含命令执行能力。若构建主机安装了 `ucode`，还应额外运行：

```sh
ucode -c luci-app-routepolicy/root/usr/share/rpcd/ucode/routepolicy
ucode tests/luci/ucode-popen-contract.uc
```

第二条命令必须使用目标 OpenWrt 25.12 SDK 构建出的 host ucode 执行。它会实际启动固定命令字符串，防止仅做语法编译却漏掉目标运行时的 `fs.popen()` interface 差异。
