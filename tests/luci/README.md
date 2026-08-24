# LuCI 静态检查

在宿主机运行：

```powershell
powershell -ExecutionPolicy Bypass -File tests/luci/check-static.ps1
```

检查 JSON、所有 LuCI JavaScript 的语法，以及 RPC 方法白名单和 ACL 是否意外包含命令执行能力。若构建主机安装了 `ucode`，还应额外运行：

```sh
ucode -c luci-app-routepolicy/root/usr/libexec/rpcd/routepolicy
```
