$ErrorActionPreference = 'Stop'

$repo = Resolve-Path (Join-Path $PSScriptRoot '../..')
$package = Join-Path $repo 'luci-app-routepolicy'
$acl = Join-Path $package 'root/usr/share/rpcd/acl.d/luci-app-routepolicy.json'
$menu = Join-Path $package 'root/usr/share/luci/menu.d/luci-app-routepolicy.json'
$rpc = Join-Path $package 'root/usr/libexec/rpcd/routepolicy'

Get-Content -Raw -Encoding UTF8 $acl | ConvertFrom-Json | Out-Null
Get-Content -Raw -Encoding UTF8 $menu | ConvertFrom-Json | Out-Null

$views = Get-ChildItem (Join-Path $package 'htdocs/luci-static/resources') -Recurse -Filter '*.js'
foreach ($view in $views) {
    & node --check $view.FullName
    if ($LASTEXITCODE -ne 0) { throw "JavaScript syntax check failed: $($view.FullName)" }
}

$rpcText = Get-Content -Raw -Encoding UTF8 $rpc
$methods = @('status', 'validate', 'apply', 'reload', 'update', 'rollback', 'diagnose', 'import_legacy', 'read_user_list', 'write_user_list')
foreach ($method in $methods) {
    if ($rpcText -notmatch "(?m)^\s*${method}:") { throw "Missing fixed RPC method: $method" }
}
foreach ($forbidden in @('file.exec', '/bin/sh', 'exec(', 'req.path', 'req.command', 'req.nft')) {
    if ($rpcText -match [regex]::Escape($forbidden)) { throw "Forbidden RPC capability found: $forbidden" }
}

if ($rpcText -notmatch "apply:\s*\[\s*'/etc/init\.d/routepolicy',\s*'restart'\s*\]") {
    throw 'Apply RPC must reconcile the procd lifecycle through the fixed init script'
}
if ($rpcText -notmatch "reload:\s*\[\s*'/etc/init\.d/routepolicy',\s*'restart'\s*\]") {
    throw 'Reload RPC must reconcile the procd lifecycle through the fixed init script'
}
$settingsText = Get-Content -Raw -Encoding UTF8 (Join-Path $package 'htdocs/luci-static/resources/view/routepolicy/settings.js')
if ($settingsText -notmatch 'handleSaveApply[\s\S]*api\.reload\(\)') {
    throw 'Save & Apply must synchronize the service lifecycle after saving UCI'
}

$aclText = Get-Content -Raw -Encoding UTF8 $acl
foreach ($forbidden in @('file', 'exec', '*', '/bin/sh')) {
    if ($aclText -match [regex]::Escape($forbidden)) { throw "Overbroad ACL token found: $forbidden" }
}

Write-Output 'LuCI static contract checks passed.'
