$ErrorActionPreference = 'Stop'

$repo = Resolve-Path (Join-Path $PSScriptRoot '../..')
$package = Join-Path $repo 'luci-app-routepolicy'
$acl = Join-Path $package 'root/usr/share/rpcd/acl.d/luci-app-routepolicy.json'
$menu = Join-Path $package 'root/usr/share/luci/menu.d/luci-app-routepolicy.json'
$rpc = Join-Path $package 'root/usr/share/rpcd/ucode/routepolicy'

Get-Content -Raw -Encoding UTF8 $acl | ConvertFrom-Json | Out-Null
Get-Content -Raw -Encoding UTF8 $menu | ConvertFrom-Json | Out-Null

$views = Get-ChildItem (Join-Path $package 'htdocs/luci-static/resources') -Recurse -Filter '*.js'
foreach ($view in $views) {
    & node --check $view.FullName
    if ($LASTEXITCODE -ne 0) { throw "JavaScript syntax check failed: $($view.FullName)" }
}

& node (Join-Path $PSScriptRoot 'module-contract-test.js')
if ($LASTEXITCODE -ne 0) { throw 'LuCI module constructor contract failed' }

& node (Join-Path $PSScriptRoot 'rpcd-contract-test.js')
if ($LASTEXITCODE -ne 0) { throw 'rpcd ucode registration contract failed' }

$rpcText = Get-Content -Raw -Encoding UTF8 $rpc
$methods = @(
    'status', 'validate', 'apply', 'reload', 'update', 'rollback', 'diagnose', 'import_legacy',
    'read_user_list', 'write_user_list', 'smartdns_status', 'smartdns_save', 'smartdns_validate',
    'smartdns_apply', 'smartdns_discard_candidate', 'read_local_hosts', 'write_local_hosts'
)
foreach ($method in $methods) {
    if ($rpcText -notmatch "(?m)^\s*${method}:") { throw "Missing fixed RPC method: $method" }
}
foreach ($forbidden in @('file.exec', '/bin/sh', 'exec(', 'req.path', 'req.command', 'req.nft')) {
    if ($rpcText -match [regex]::Escape($forbidden)) { throw "Forbidden RPC capability found: $forbidden" }
}

if ($rpcText -notmatch "apply:\s*'/etc/init\.d/routepolicy restart'") {
    throw 'Apply RPC must reconcile the procd lifecycle through the fixed init script'
}
if ($rpcText -notmatch "reload:\s*'/etc/init\.d/routepolicy restart'") {
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
if ($aclText -match '"uci"\s*:\s*\[[^\]]*"smartdns"') {
    throw 'Browser ACL must not receive direct SmartDNS UCI write access'
}
$apiText = Get-Content -Raw -Encoding UTF8 (Join-Path $package 'htdocs/luci-static/resources/routepolicy/api.js')
foreach ($method in $methods) {
    if ($apiText -notmatch [regex]::Escape("'$method'")) { throw "Missing LuCI API declaration: $method" }
    if ($aclText -notmatch [regex]::Escape('"' + $method + '"')) { throw "Missing ACL declaration: $method" }
}
$smartdnsView = Get-Content -Raw -Encoding UTF8 (Join-Path $package 'htdocs/luci-static/resources/view/routepolicy/smartdns.js')
foreach ($required in @('api.smartdnsSave', 'api.smartdnsValidate', 'api.smartdnsApply', 'window.confirm', 'data-server')) {
    if ($smartdnsView -notmatch [regex]::Escape($required)) { throw "SmartDNS page missing contract token: $required" }
}

Write-Output 'LuCI static contract checks passed.'
