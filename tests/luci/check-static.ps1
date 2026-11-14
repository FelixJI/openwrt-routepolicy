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

& node (Join-Path $PSScriptRoot 'view-render-contract-test.js')
if ($LASTEXITCODE -ne 0) { throw 'LuCI view render contract failed' }

& node (Join-Path $PSScriptRoot 'interaction-contract-test.js')
if ($LASTEXITCODE -ne 0) { throw 'LuCI interaction contract failed' }

& node (Join-Path $PSScriptRoot 'wizard-contract-test.js')
if ($LASTEXITCODE -ne 0) { throw 'LuCI wizard interaction contract failed' }

& node (Join-Path $PSScriptRoot 'observability-contract-test.js')
if ($LASTEXITCODE -ne 0) { throw 'LuCI observability contract failed' }

& node (Join-Path $PSScriptRoot 'rpcd-contract-test.js')
if ($LASTEXITCODE -ne 0) { throw 'rpcd ucode registration contract failed' }

& node (Join-Path $PSScriptRoot 'package-lifecycle-contract-test.js')
if ($LASTEXITCODE -ne 0) { throw 'LuCI package lifecycle contract failed' }

$rpcText = Get-Content -Raw -Encoding UTF8 $rpc
$methods = @(
    'status', 'validate', 'apply', 'reload', 'update', 'rollback', 'diagnose', 'import_legacy',
    'read_user_list', 'write_user_list', 'smartdns_status', 'smartdns_save', 'smartdns_validate',
    'smartdns_apply', 'smartdns_discard_candidate', 'read_local_hosts', 'write_local_hosts',
    'init_cancel', 'init_finish'
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
$menuObject = Get-Content -Raw -Encoding UTF8 $menu | ConvertFrom-Json
$settingsView = $menuObject.'admin/services/routepolicy/settings'.action.path
$settingsText = Get-Content -Raw -Encoding UTF8 (Join-Path $package "htdocs/luci-static/resources/view/$settingsView.js")
if ($settingsText -notmatch 'handleSaveApply[\s\S]*ui\.changes\.apply') {
    throw 'Save & Apply must commit staged UCI through the LuCI apply workflow'
}
$sourcesText = Get-Content -Raw -Encoding UTF8 (Join-Path $package 'htdocs/luci-static/resources/view/routepolicy/sources.js')
if ($sourcesText -notmatch 'handleSaveApply[\s\S]*ui\.changes\.apply') {
    throw 'Source Save & Apply must commit staged UCI through the LuCI apply workflow'
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

# Keep the wizard's declared API and backend ACL in sync.
$lifecycleMethods = @(
    'init_discover', 'init_preview', 'init_prepare', 'init_candidate', 'init_status',
    'init_apply', 'init_recover', 'config_export', 'config_import', 'restore_status',
    'restore_prepare', 'restore_recover', 'exit_preview', 'exit_prepare', 'exit_candidate', 'exit_apply'
)
foreach ($method in $lifecycleMethods) {
    if ($apiText -notmatch [regex]::Escape("'$method'")) { throw "Missing LuCI lifecycle API declaration: $method" }
    if ($aclText -notmatch [regex]::Escape('"' + $method + '"')) {
        throw "Missing lifecycle ACL declaration: $method"
    }
}

# The browser never talks HTML: reject script sinks across all shipped JS.
foreach ($view in $views) {
    $viewText = Get-Content -Raw -Encoding UTF8 $view.FullName
    foreach ($forbidden in @('innerHTML', 'insertAdjacentHTML', 'document.write', 'outerHTML', 'new Function', 'eval(')) {
        if ($viewText -match [regex]::Escape($forbidden)) { throw "Forbidden HTML/script sink '$forbidden' found in $($view.FullName)" }
    }
}

$wizardView = Join-Path $package 'htdocs/luci-static/resources/view/routepolicy/wizard.js'
$wizardText = Get-Content -Raw -Encoding UTF8 $wizardView
if ($wizardText -notmatch [regex]::Escape("admin/services/routepolicy/confirm")) {
    throw 'The wizard must confirm through the fixed LuCI HTTP controller endpoint'
}
foreach ($forbidden in @('initConfirm', 'init_confirm', 'console.', 'window.confirm')) {
    if ($wizardText -match [regex]::Escape($forbidden)) { throw "Forbidden wizard capability/log sink: $forbidden" }
}
$lifecycleHelper = Join-Path $package 'htdocs/luci-static/resources/routepolicy/lifecycle.js'
foreach ($forbidden in @('console.', 'innerHTML', 'insertAdjacentHTML')) {
    if ((Get-Content -Raw -Encoding UTF8 $lifecycleHelper) -match [regex]::Escape($forbidden)) {
        throw "Forbidden lifecycle helper sink: $forbidden"
    }
}
if ($wizardText -notmatch [regex]::Escape('new FormData')) {
    throw 'The HTTP confirmation must post a real form body because http.formvalue does not parse JSON'
}
$menuObject = Get-Content -Raw -Encoding UTF8 $menu | ConvertFrom-Json
if (-not $menuObject.'admin/services/routepolicy/wizard') { throw 'Missing wizard menu entry' }
if ($menuObject.'admin/services/routepolicy/wizard'.action.path -ne 'routepolicy/wizard') {
    throw 'The wizard menu entry must point at the routepolicy/wizard view'
}
$smartdnsView = Get-Content -Raw -Encoding UTF8 (Join-Path $package 'htdocs/luci-static/resources/view/routepolicy/smartdns.js')
foreach ($required in @('api.smartdnsSave', 'api.smartdnsValidate', 'api.smartdnsApply', 'window.confirm', 'data-server')) {
    if ($smartdnsView -notmatch [regex]::Escape($required)) { throw "SmartDNS page missing contract token: $required" }
}

Write-Output 'LuCI static contract checks passed.'
