#!/bin/sh
# RoutePolicy 离线安装介质单入口（仅 OpenWrt 25.12 x86_64，apk-tools 3）。
#
# 用法（在与本脚本相同的介质目录中执行，目录须包含两个 APK 与 SHA256SUMS）：
#   sh install.sh --allow-local-unsigned
#
# 合同：
# - 本脚本不下载并执行远程脚本，不修改网络配置，不做批量升级。
# - SHA256SUMS 是介质唯一的完整性清单（不是身份签名）：先逐行校验记录
#   结构（64 位 hex 摘要、精确分隔符、纯 basename、无重复），再核对整套
#   介质；GNU sha256sum -c 会忽略格式坏行，结构校验必须先行。
# - 所有 apk 调用均命令级 APK_CONFIG=/dev/null，不继承 /etc/apk/config
#   等全局配置里的软件源或信任选项。
# - 依赖经 apk adbdump 从本地 APK 的 ADB 元数据解析；字段唯一、依赖 token
#   先做合法性检查，绝不让元数据变成任意 apk 选项。
# - 两阶段安装：
#   阶段一 在私有空目录、临时 repositories-file（仅当前 OpenWrt 25.12 补丁
#   版官方 distfeeds）中，只补缺失依赖；已安装依赖（含手选 SmartDNS）的
#   现有 world 版本/来源一律保留，simulate 发现会升级/替换已安装包时拒绝。
#   阶段二 以 --network=no --repositories-file /dev/null 离线求解，先
#   --simulate 预检：动作行只允许本介质双包，未知动作或外来包一律在安装前
#   拒绝。apk-tools 的 --allow-untrusted 作用于整个调用，只出现在无网络、
#   无软件源的阶段，不会扩展到远端依赖。
# - apk 失败可能留下部分安装：不虚构原子恢复，不自动重试，如实报告并要求
#   保留介质核对现场。安装健康（包落地、RPC 可用）与未初始化设备的候选可
#   应用性分开：新装/未启用设备输出待向导配置提示；已启用实例的 validate
#   失败是真实错误，不遮掩。

set -eu

usage() {
	printf '用法: sh install.sh --allow-local-unsigned\n'
	printf '在与本脚本相同的介质目录中执行；目录须包含两个 APK 与 SHA256SUMS。\n'
}

die() {
	printf 'install.sh: %s\n' "$1" >&2
	exit 1
}

run_apk() {
	APK_CONFIG=/dev/null apk "$@"
}

allow_unsigned=0
for arg in "$@"; do
	case "$arg" in
	--allow-local-unsigned) allow_unsigned=1 ;;
	-h|--help) usage; exit 0 ;;
	*) printf '未知参数: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
	esac
done

[ "$(basename "$0")" = install.sh ] || die '请保持脚本文件名 install.sh，使其与 SHA256SUMS 记录一致'
[ "$(id -u)" = 0 ] || die '请以 root 在目标设备上运行'
command -v apk >/dev/null 2>&1 || die '未找到 apk；本入口仅支持 OpenWrt 25.12 x86_64'
command -v sha256sum >/dev/null 2>&1 || die '未找到 sha256sum'

# RP_ROOT 仅为仓库测试提供根前缀；正常安装必须为空。
prefix=${RP_ROOT:-}
release_file="$prefix/etc/openwrt_release"
[ -f "$release_file" ] && [ ! -L "$release_file" ] || die '缺少 /etc/openwrt_release；本入口仅支持官方 OpenWrt 25.12 x86_64'
distrib_id=$(sed -n "s/^DISTRIB_ID='\([^']*\)'.*/\1/p" "$release_file" | sed -n '1p')
distrib_release=$(sed -n "s/^DISTRIB_RELEASE='\([^']*\)'.*/\1/p" "$release_file" | sed -n '1p')
[ "$distrib_id" = OpenWrt ] || die "不支持的系统发行标识: ${distrib_id:-未知}；本入口仅支持官方 OpenWrt 25.12 x86_64"
case "$distrib_release" in
25.12|25.12.*) ;;
*) die "不支持的 OpenWrt 版本 ${distrib_release:-未知}；本入口仅支持 25.12" ;;
esac
device_arch=$(run_apk --print-arch 2>/dev/null) || die 'apk --print-arch 失败，不能确认架构'
[ "$device_arch" = x86_64 ] || die "不支持的架构 $device_arch；本入口仅支持 x86_64"

media_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || die '无法定位介质目录'
cd "$media_dir" || die "无法进入介质目录: $media_dir"

core_apk='' luci_apk=''
for candidate in routepolicy-*.apk; do
	[ -e "$candidate" ] || continue
	[ -z "$core_apk" ] || die '介质中存在多个 routepolicy-*.apk，拒绝混杂介质'
	[ -f "$candidate" ] && [ ! -L "$candidate" ] || die "APK 不是安全普通文件: $candidate"
	core_apk=$candidate
done
[ -n "$core_apk" ] || die '介质缺少 routepolicy-*.apk'
for candidate in luci-app-routepolicy-*.apk; do
	[ -e "$candidate" ] || continue
	[ -z "$luci_apk" ] || die '介质中存在多个 luci-app-routepolicy-*.apk，拒绝混杂介质'
	[ -f "$candidate" ] && [ ! -L "$candidate" ] || die "APK 不是安全普通文件: $candidate"
	luci_apk=$candidate
done
[ -n "$luci_apk" ] || die '介质缺少 luci-app-routepolicy-*.apk'

core_version=${core_apk#routepolicy-}; core_version=${core_version%.apk}
luci_version=${luci_apk#luci-app-routepolicy-}; luci_version=${luci_version%.apk}
case "$core_version$luci_version" in
''|*[!0-9A-Za-z._+-]*) die 'APK 文件名中的版本非法' ;;
esac
[ "$core_version" = "$luci_version" ] || die "两个 APK 版本不一致（$core_version 与 $luci_version），拒绝混杂介质"

[ -f SHA256SUMS ] && [ ! -L SHA256SUMS ] || die '介质缺少 SHA256SUMS'
# 先做逐行结构校验：64 位 hex 摘要、pos65 恰为空格、pos66 为空格或 '*'、
# 文件名为纯 basename、无重复。GNU sha256sum -c 会静默忽略格式坏行，这里
# 必须在任何 -c 之前拒绝。
awk '
	{
		line = $0
		if (length(line) < 67) { bad = 1; next }
		if (substr(line, 65, 1) != " ") { bad = 1; next }
		marker = substr(line, 66, 1)
		if (marker == "*" || marker == " ") fname = substr(line, 67)
		else { bad = 1; next }
		if (substr(line, 1, 64) !~ /^[0-9a-fA-F]+$/) { bad = 1; next }
		if (fname !~ /^[A-Za-z0-9][A-Za-z0-9._+-]*$/) { bad = 1; next }
		if (seen[fname]++ > 0) dup = 1
	}
	END { exit (bad || dup) ? 1 : 0 }
' SHA256SUMS || die 'SHA256SUMS 记录结构非法（摘要/分隔符/文件名）或存在重复记录'
required_record_count() {
	wanted=$1
	count=$(awk -v name="$wanted" '
		{
			if (substr($0, 65, 1) != " ") next
			marker = substr($0, 66, 1)
			if (marker == "*" || marker == " ") fname = substr($0, 67)
			else next
			if (fname == name) n++
		}
		END { print n + 0 }
	' SHA256SUMS)
	[ "$count" = 1 ] || die "SHA256SUMS 中 $wanted 必须恰好有一条记录（实际 $count 条）"
}
required_record_count install.sh
required_record_count "$core_apk"
required_record_count "$luci_apk"

if ! sha256sum -c SHA256SUMS; then
	die '介质完整性校验失败：停止安装，请重新下载完整介质后再试'
fi

if [ "$allow_unsigned" != 1 ]; then
	printf 'install.sh: 本 Release APK 未签名。确认介质来自本仓库 Release 且校验已通过后，请显式追加 --allow-local-unsigned 重试；未执行任何安装动作。\n' >&2
	exit 1
fi

# 先完整捕获 apk adbdump 的结果并确认成功，再做结构解析：直接管道会吞掉
# apk 的非零退出，半截元数据不能进入后续判断。
parse_adbdump() {
	dump_output=$(run_apk adbdump "$1" 2>/dev/null) || return 1
	printf '%s\n' "$dump_output" | awk '
		/^  (pkgname|name): / {
			line = $0; sub(/^  (pkgname|name): /, "", line)
			if (nname++ > 0) exit 1
			name = line; next
		}
		/^  version: / {
			line = $0; sub(/^  version: /, "", line)
			if (nver++ > 0) exit 1
			version = line; next
		}
		/^  arch: / {
			line = $0; sub(/^  arch: /, "", line)
			if (narch++ > 0) exit 1
			arch = line; next
		}
		/^  depends:/ { indeps = 1; next }
		indeps && /^    - / {
			# depends 列表项必须恰为单个 token；畸形或含空格的行直接拒绝。
			if ($0 !~ /^    - [^[:space:]]+$/) exit 1
			print "DEP\t" substr($0, 7); next
		}
		indeps && !/^    - / { indeps = 0 }
		END {
			if (nname != 1 || nver != 1 || narch != 1) exit 1
			printf "PKG\t%s\t%s\t%s\n", name, version, arch
		}
	'
}
core_parsed=$(parse_adbdump "./$core_apk") || die "无法从 $core_apk 解析唯一的 adbdump 元数据"
luci_parsed=$(parse_adbdump "./$luci_apk") || die "无法从 $luci_apk 解析唯一的 adbdump 元数据"

core_pkg=$(printf '%s\n' "$core_parsed" | sed -n 's/^PKG\t\([^\t]*\)\t[^\t]*\t[^\t]*$/\1/p')
core_meta_version=$(printf '%s\n' "$core_parsed" | sed -n 's/^PKG\t[^\t]*\t\([^\t]*\)\t[^\t]*$/\1/p')
core_meta_arch=$(printf '%s\n' "$core_parsed" | sed -n 's/^PKG\t[^\t]*\t[^\t]*\t\([^\t]*\)$/\1/p')
luci_pkg=$(printf '%s\n' "$luci_parsed" | sed -n 's/^PKG\t\([^\t]*\)\t[^\t]*\t[^\t]*$/\1/p')
luci_meta_version=$(printf '%s\n' "$luci_parsed" | sed -n 's/^PKG\t[^\t]*\t\([^\t]*\)\t[^\t]*$/\1/p')
luci_meta_arch=$(printf '%s\n' "$luci_parsed" | sed -n 's/^PKG\t[^\t]*\t[^\t]*\t\([^\t]*\)$/\1/p')

[ "$core_pkg" = routepolicy ] || die "$core_apk 元数据包名为 ${core_pkg:-未知}，与介质文件名不符"
[ "$core_meta_version" = "$core_version" ] || die "$core_apk 元数据版本 $core_meta_version 与文件名版本 $core_version 不符"
[ "$core_meta_arch" = x86_64 ] || die "$core_apk 元数据架构为 ${core_meta_arch:-未知}，与目标不符"
[ "$luci_pkg" = luci-app-routepolicy ] || die "$luci_apk 元数据包名为 ${luci_pkg:-未知}，与介质文件名不符"
[ "$luci_meta_version" = "$luci_version" ] || die "$luci_apk 元数据版本 $luci_meta_version 与文件名版本 $luci_version 不符"
case "$luci_meta_arch" in noarch|x86_64) ;; *) die "$luci_apk 元数据架构为 $luci_meta_arch，与目标不符" ;; esac

# 在补依赖之前检查保留的配置和双包版本，固件重装也可能只剩配置。
if [ -e "$prefix/etc/config/routepolicy" ]; then
	uci -q export routepolicy >/dev/null || die '现有 RoutePolicy 配置无法读取；未安装任何内容'
	config_schema=$(uci -q get routepolicy.main.config_schema) || config_schema=0
	case "$config_schema" in 0|1) ;; *) die '配置 schema 高于本介质支持范围；未安装任何内容' ;; esac
fi
installed_manifest=$(run_apk list --manifest --installed 2>/dev/null) || die '无法核实已安装版本；未安装任何内容'
for package in routepolicy luci-app-routepolicy; do
	installed_version=$(printf '%s\n' "$installed_manifest" | awk -v p="$package" '
		$1 == p { if (NF != 2 || count++) exit 1; version = $2 }
		END { print version }
	') || die "已安装 $package 版本记录不唯一或损坏；未安装任何内容"
	[ -n "$installed_version" ] || continue
	comparison=$(run_apk version -t "$installed_version" "$core_version") || die "无法比较 $package 版本；未安装任何内容"
	case "$comparison" in
	'<'|'=') ;;
	'>') die "不支持降级 $package（$installed_version → $core_version）；未安装任何内容" ;;
	*) die "无法确认 $package 版本顺序；未安装任何内容" ;;
	esac
done

# 依赖 token 先逐个校验再交给 apk：拒绝选项形态与非法字符，防止元数据
# 注入 apk 参数。剔除本介质自身提供的两个包名，其余逐字传递。
valid_dep_token() {
	case $1 in
	-*) return 1 ;;
	esac
	printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9._+:~!=<>-]+$' || return 1
	return 0
}
dependency_tokens=$(
	{ printf '%s\n' "$core_parsed"; printf '%s\n' "$luci_parsed"; } |
		sed -n 's/^DEP\t//p' |
		grep -v -E '^(routepolicy|luci-app-routepolicy)([<>=!].*)?$' |
		sort -u
)
for token in $dependency_tokens; do
	valid_dep_token "$token" || die "APK 元数据中的依赖 token 非法: $token"
done

# 依赖存在性用原生 apk info --exists 判定（虚拟依赖会解析到 provider，如
# nftables → nftables-json）：退出码 0=已满足（保留既有 world 版本/来源，
# 不调用 add 重写 selector）；1=缺失待装；其他=检查异常，明确失败；不凭
# stdout 判断。含约束/前缀（so:、pc:、比较符）的复杂 token 不支持自动
# 解析，显式拒绝而不是错误覆盖。
plain_dep_token() {
	printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]*$'
}
missing_tokens=''
for token in $dependency_tokens; do
	plain_dep_token "$token" || die "依赖 token 含约束/虚拟前缀，本入口不支持自动解析：$token"
	exist_status=0
	run_apk info --exists "$token" >/dev/null 2>&1 || exist_status=$?
	case $exist_status in
	0) continue ;;
	1) missing_tokens="$missing_tokens $token" ;;
	*) die "apk info --exists 检查依赖 $token 异常（退出码 $exist_status）" ;;
	esac
done

phase1_dir=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-install.XXXXXX") || die '无法创建阶段一私有目录'
cleanup_phase1() { rm -rf "$phase1_dir"; }
trap cleanup_phase1 EXIT HUP INT TERM
# 阶段一软件源：逐行读取设备实际 /etc/apk/repositories.d/distfeeds.list，
# 仅保留当前发行版、targets/x86/64/ 或 packages/x86_64/ 下且以 packages.adb
# 结尾的官方 HTTPS 行（含 kernel/kmods 源）；自定义源与其他发行版明确跳过
# 并提示，不继承、不修改原文件。
distfeeds_file="$prefix/etc/apk/repositories.d/distfeeds.list"
[ -f "$distfeeds_file" ] && [ ! -L "$distfeeds_file" ] || die "缺少官方 distfeeds 文件：$distfeeds_file"
while IFS= read -r repo_line || [ -n "$repo_line" ]; do
	case $repo_line in
	"https://downloads.openwrt.org/releases/$distrib_release/targets/x86/64/"*/packages.adb|\
	"https://downloads.openwrt.org/releases/$distrib_release/packages/x86_64/"*/packages.adb)
		printf '%s\n' "$repo_line" >>"$phase1_dir/repositories"
		;;
	'') ;;
	*)
		printf 'install.sh: 阶段一跳过非当前官方发行版软件源：%s\n' "$repo_line" >&2
		;;
	esac
done <"$distfeeds_file"
[ -s "$phase1_dir/repositories" ] || die '官方 distfeeds 中没有当前发行版 x86_64 的 packages.adb 源；拒绝在未知来源上解析依赖'

if [ -n "${missing_tokens# }" ]; then
	set -f
	# shellcheck disable=SC2086
	set -- $missing_tokens
	set +f
	printf '阶段一：官方软件源签名安装缺失依赖：%s\n' "$*"
	phase1_sim=$(cd "$phase1_dir" && run_apk add --simulate --repositories-file "$phase1_dir/repositories" "$@" 2>&1) || {
		printf 'install.sh: 官方依赖求解失败（未安装任何内容）：\n%s\n' "$phase1_sim" >&2
		exit 1
	}
	# 只允许“安装原本缺失的包”；对已安装包的任何升级/替换/移除动作都拒绝，
	# 手选 SmartDNS 等 world 版本与来源 pin 不因安装本应用而改变。
	phase1_foreign=$(printf '%s\n' "$phase1_sim" | awk '
		/^\([[:space:]]*[0-9]+\/[0-9]+\) / {
			line = $0; sub(/^\([[:space:]]*[0-9]+\/[0-9]+\) /, "", line)
			verb = line; sub(/[[:space:]].*$/, "", verb)
			if (verb != "Installing") print
			next
		}
	')
	if [ -n "$phase1_foreign" ]; then
		printf 'install.sh: 官方依赖求解将升级/替换已安装包，已拒绝（未安装任何内容）：\n%s\n' "$phase1_foreign" >&2
		exit 1
	fi
	apk_status=0
	(cd "$phase1_dir" && run_apk add --repositories-file "$phase1_dir/repositories" "$@") || apk_status=$?
	if [ "$apk_status" -ne 0 ]; then
		printf 'install.sh: 官方依赖安装失败（退出码 %s）。未安装本地未签名 APK；请核对 apk 输出与官方源可达性后重试。\n' "$apk_status" >&2
		exit "$apk_status"
	fi
else
	printf '阶段一：依赖已全部就绪，未改动任何已安装包。\n'
fi

# 阶段二：无网络、无软件源；先 simulate 预检。动作行格式实测形如
# "( 1/10) Installing routepolicy (0.3.3-r2)"（含 Replacing/Purging/Updating
# 等动词与左补空格）；只放行本介质双包，未知动作或外来包在安装前拒绝。
simulate_output=$(run_apk add --simulate --allow-untrusted --network=no --repositories-file /dev/null "./$core_apk" "./$luci_apk" 2>&1) || {
	printf 'install.sh: 离线求解预检失败，未安装介质双包（阶段一可能已补齐依赖）：\n%s\n' "$simulate_output" >&2
	exit 1
}
foreign_change=$(printf '%s\n' "$simulate_output" | awk '
	/^\([[:space:]]*[0-9]+\/[0-9]+\) / {
		line = $0; sub(/^\([[:space:]]*[0-9]+\/[0-9]+\) /, "", line)
		verb = line; sub(/[[:space:]].*$/, "", verb)
		rest = line; sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
		pkg = rest; sub(/[[:space:]].*$/, "", pkg)
		if (verb !~ /^(Installing|Re-installing|Reinstalling|Upgrading|Downgrading|Removing|Purging|Replacing|Updating)$/ ||
			(pkg != "routepolicy" && pkg != "luci-app-routepolicy"))
			print
		next
	}
')
if [ -n "$foreign_change" ]; then
	printf 'install.sh: 离线求解预检发现将改变本介质双包以外的内容或未知动作，已拒绝安装：\n%s\n' "$foreign_change" >&2
	exit 1
fi

world_before_raw=$(run_apk list --manifest --installed 2>/dev/null) || die 'apk list --manifest --installed 失败，无法建立离线安装前基线'
world_before=$(printf '%s\n' "$world_before_raw" | sort)
printf '阶段二：离线安装本地已校验双包（--network=no --repositories-file /dev/null）...\n'
apk_status=0
run_apk add --allow-untrusted --network=no --repositories-file /dev/null "./$core_apk" "./$luci_apk" || apk_status=$?
if [ "$apk_status" -ne 0 ]; then
	printf 'install.sh: 离线安装失败（退出码 %s）。可能存在部分安装；本脚本不虚构原子恢复，不会自动重试，也不会改动网络。请保留介质并核对 apk info 与 logread，再按 INSTALL.txt 处理。\n' "$apk_status" >&2
	exit "$apk_status"
fi
world_after_raw=$(run_apk list --manifest --installed 2>/dev/null) || die 'apk list --manifest --installed 失败，无法核对离线安装结果'
world_after=$(printf '%s\n' "$world_after_raw" | sort)
# 新包落地的精确证明：manifest 中双包各恰一条且版本等于介质；旧 RPC 对象
# 不足以证明新包落地。
core_landed=$(printf '%s\n' "$world_after_raw" | awk -v v="$core_version" '$1 == "routepolicy" && $2 == v { n++ } END { print n + 0 }')
luci_landed=$(printf '%s\n' "$world_after_raw" | awk -v v="$luci_version" '$1 == "luci-app-routepolicy" && $2 == v { n++ } END { print n + 0 }')
[ "$core_landed" = 1 ] && [ "$luci_landed" = 1 ] || die "离线安装后 manifest 未精确出现介质双包（routepolicy $core_version 与 luci-app-routepolicy $luci_version 各恰一条）；旧 RPC 对象不足以证明新包落地，请核对 apk info 与 logread"
# 原生 manifest 行 'name version'：按第一列精确包名排除本介质双包自身，
# routepolicy-2foo 等同名前缀包不受影响。
world_drift=$(
	{ printf '%s\n' "$world_before"; printf '%s\n' "$world_after"; } |
		sort | uniq -u | awk 'NF == 2 && $1 != "routepolicy" && $1 != "luci-app-routepolicy"' || true
)
if [ -n "$world_drift" ]; then
	printf 'install.sh: 离线安装改变了本介质双包以外的已安装包：\n%s\n安装已发生，请核对 apk info 与 logread；本脚本不会虚构原子恢复。\n' "$world_drift" >&2
	exit 1
fi

# 安装健康检查：包落地与 RPC 可用，独立捕获 ubus 退出码后再解析。
command -v routepolicyctl >/dev/null 2>&1 || die 'routepolicyctl 未随包落地；请按 INSTALL.txt 核对 apk info 与 logread'
ubus_list_output=$(ubus list 2>/dev/null) || die 'ubus list 失败，无法核对 rpcd 对象'
printf '%s\n' "$ubus_list_output" | grep -qx routepolicy || die 'rpcd 中未找到 routepolicy 对象。请按 INSTALL.txt 保存 logread 输出，不要启用 RoutePolicy'
status_output=$(ubus call routepolicy status '{}' 2>/dev/null) || die 'routepolicy status 调用失败。请按 INSTALL.txt 保存 logread 输出，不要启用 RoutePolicy'
printf '%s\n' "$status_output" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' || die 'routepolicy status 未返回 ok:true。请按 INSTALL.txt 保存 logread 输出，不要启用 RoutePolicy'

valid_ipv4() {
	valid_ipv4_input=$1
	[ -n "$valid_ipv4_input" ] || return 1
	IFS=.
	set -- $valid_ipv4_input
	unset IFS
	[ $# -eq 4 ] || return 1
	for octet in "$@"; do
		case $octet in
		''|*[!0-9]*) return 1 ;;
		esac
		[ "$octet" -le 255 ] || return 1
	done
	return 0
}
lan_raw=$(uci -q get network.lan.ipaddr 2>/dev/null) || lan_raw=''
# 实际值可能是 '192.168.1.1/24'、空格分隔多地址或多行：先取第一个空白分隔
# token，再去 CIDR 前缀后严格校验；不做整体去空白，避免拼接出假地址。
lan_address=$(printf '%s\n' "$lan_raw" | awk 'NF { print $1; exit }' | cut -d/ -f1)
valid_ipv4 "$lan_address" || lan_address=''
enabled_state='' enabled_known=0
if enabled_output=$(uci get routepolicy.main.enabled 2>/dev/null); then
	case $enabled_output in
	0|1) enabled_state=$enabled_output enabled_known=1 ;;
	esac
fi
if [ "$enabled_known" = 1 ] && [ "$enabled_state" = 1 ]; then
	# 无论此前是否安装过包，enabled=1 都验证且只陈述观察状态，不做无法证明的
	# 接管/未接管承诺。
	routepolicyctl validate || die 'routepolicyctl validate 失败：已启用实例的配置未通过验证。请按 INSTALL.txt 保存 logread 输出'
	printf '安装完成（包落地、RPC 可用）。观察到 routepolicy.main.enabled=1，请核对运行状态与分流后再交付使用。\n'
elif [ "$enabled_known" = 1 ]; then
	printf '安装完成（包落地、RPC 可用）。观察到 routepolicy.main.enabled=%s；若尚未配置，请使用 LuCI“服务 → 路由策略”的初始化与恢复向导；请核对运行状态。\n' "$enabled_state"
else
	printf '安装完成（包落地、RPC 可用）；routepolicy.main.enabled 读取失败或未设置，状态未知；若尚未配置，请使用 LuCI“服务 → 路由策略”的初始化与恢复向导；请核对运行状态。\n'
fi
if [ -n "$lan_address" ]; then
	printf 'LuCI 管理入口: http://%s/cgi-bin/luci （服务 → 路由策略）\n' "$lan_address"
else
	printf 'LuCI 管理入口: http://<设备地址>/cgi-bin/luci （服务 → 路由策略）\n'
fi
