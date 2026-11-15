#!/bin/sh
# scripts/install.sh 的功能级 mock 契约测试：只用临时目录、PATH 桩和仓库内
# 真实 SDK adbdump 夹具；不需要设备/apk。真实 apk-tools 3.0.5 行为由主代理
# 在设备上验证。
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
command -v sha256sum >/dev/null 2>&1 || { printf '缺少 sha256sum，install.sh 契约测试无法运行\n' >&2; exit 1; }
fixture_dir=$ROOT/tests/ci/install-media-fixtures
[ -f "$fixture_dir/core-adbdump.txt" ] && [ -f "$fixture_dir/luci-adbdump.txt" ] || {
	printf '缺少真实 adbdump 夹具，install.sh 契约测试无法运行\n' >&2
	exit 1
}

work=$(mktemp -d) || { printf '无法创建测试目录\n' >&2; exit 1; }
trap 'rm -rf "$work"' EXIT HUP INT TERM

fail() {
	printf 'install.sh 功能契约测试失败：%s\n' "$1" >&2
	exit 1
}

bin_dir=$work/bin
mkdir -p "$bin_dir"
cat >"$bin_dir/id" <<'STUB'
#!/bin/sh
printf '%s\n' "${TEST_ID_UID:-0}"
STUB
cat >"$bin_dir/apk" <<'STUB'
#!/bin/sh
state=${TEST_APK_STATE_DIR:?}
if [ "$1" = --print-arch ]; then
	printf '%s\n' "${TEST_APK_ARCH:-x86_64}"
	exit 0
fi
if [ "$1" = adbdump ]; then
	cat "${TEST_DUMP_DIR:?}/${2##*/}.adbdump" 2>/dev/null || exit 1
	exit "${TEST_DUMP_STATUS:-0}"
fi
if [ "$1" = version ]; then
	case $3 in
	0.3.2-r1|0.3.3-r1) printf '<\n' ;;
	0.3.3-r2) printf '=\n' ;;
	0.3.3-r3|0.4.0-r1) printf '>\n' ;;
	*) exit 1 ;;
	esac
	exit 0
fi
if [ "$1" = info ] && [ "$2" = --exists ]; then
	case $3 in
	nftables) printf 'nftables-json\n'; exit 0 ;;
	smartdns) printf 'smartdns\n'; exit 0 ;;
	esac
	case " ${TEST_APK_EXIST_OK:-} " in *" $3 "*) printf '%s\n' "$3"; exit 0 ;; esac
	exit "${TEST_APK_EXIST_STATUS:-1}"
fi
if [ "$1" = list ]; then
	printf '%s\n' 'musl 1.2.5-r0' 'base-files 1696~b21cfa8f8c' 'smartdns 46.1-r1'
	if [ "${TEST_UPGRADE_MODE:-0}" = 1 ] && [ ! -f "$state/phase2-done" ]; then
		printf 'routepolicy %s\nluci-app-routepolicy %s\n' "${TEST_OLD_VERSION:-0.3.2-r1}" "${TEST_OLD_LUCI_VERSION:-${TEST_OLD_VERSION:-0.3.2-r1}}"
	fi
	if [ -f "$state/phase2-done" ]; then
		printf '%s\n' 'routepolicy 0.3.3-r2' 'luci-app-routepolicy 0.3.3-r2'
	fi
	[ ! -f "$state/world-extra" ] || cat "$state/world-extra"
	exit 0
fi
printf '%s\n' "$*" >>"${TEST_APK_LOG:?}"
prev=
for stub_arg in "$@"; do
	if [ "$prev" = --repositories-file ] && [ "$stub_arg" != /dev/null ]; then
		cp "$stub_arg" "$state/repositories-used" 2>/dev/null || :
	fi
	prev=$stub_arg
done
case " $* " in
*' --simulate '*)
	if printf '%s' "$*" | grep -q -- '--allow-untrusted'; then
		# 阶段二 simulate：apk-tools 3.0.5 实测动作行（含左补空格与 Replacing）。
		if [ -n "${TEST_APK_SIM_OUTPUT:-}" ]; then
			printf '%s\n' "$TEST_APK_SIM_OUTPUT"
		else
			printf '%s\n' '( 1/2) Installing routepolicy (0.3.3-r2)' '(2/2) Replacing luci-app-routepolicy (0.3.3-r1 -> 0.3.3-r2)'
		fi
		exit "${TEST_APK_SIM_STATUS:-0}"
	fi
	# 阶段一 simulate：默认无动作行；TEST_APK_DEP_SIM_OUTPUT 注入外来动作。
	[ -n "${TEST_APK_DEP_SIM_OUTPUT:-}" ] && printf '%s\n' "$TEST_APK_DEP_SIM_OUTPUT"
	exit "${TEST_APK_DEP_SIM_STATUS:-0}"
	;;
esac
case " $* " in
*' --allow-untrusted '*)
	if printf '%s' "$*" | grep -q -- '--simulate'; then
		:
	else
		[ "${TEST_APK_NO_LANDING:-0}" = 1 ] || : >"$state/phase2-done"
		[ "${TEST_APK_WORLD_DRIFT:-0}" = 1 ] && printf 'routepolicy-extra 1.0-r0\nroutepolicy-2foo 1696~b21cfa8f8c\n' >"$state/world-extra"
	fi
	;;
esac
exit "${TEST_APK_ADD_STATUS:-0}"
STUB
cat >"$bin_dir/routepolicyctl" <<'STUB'
#!/bin/sh
[ -n "${TEST_VALIDATE_FAIL:-}" ] && exit 1
exit 0
STUB
cat >"$bin_dir/ubus" <<'STUB'
#!/bin/sh
[ "${TEST_UBUS_FAIL:-0}" = 1 ] && exit 1
if [ "$1" = list ]; then printf 'routepolicy\n'; exit 0; fi
if [ "$1" = call ]; then printf '{"ok":true}\n'; exit 0; fi
exit 1
STUB
cat >"$bin_dir/uci" <<'STUB'
#!/bin/sh
case " $* " in
*' changes routepolicy '*)
	printf '%s' "${TEST_CONFIG_PENDING:-}"
	exit "${TEST_CONFIG_CHANGES_STATUS:-0}" ;;
*' get routepolicy.main.config_schema '*)
	[ -n "${TEST_CONFIG_SCHEMA:-}" ] || exit 1
	printf '%s\n' "$TEST_CONFIG_SCHEMA"; exit 0 ;;
*' get network.lan.ipaddr '*)
	if [ -n "${TEST_LAN_IP:-}" ]; then printf '%s\n' "$TEST_LAN_IP"; else printf '192.168.1.1/24\n'; fi
	exit 0 ;;
*' get routepolicy.main.enabled '*)
	[ -n "${TEST_ENABLED_UNSET:-}" ] && exit 1
	[ -z "${TEST_ENABLED_STATE:-}" ] || printf '%s\n' "$TEST_ENABLED_STATE"
	exit 0 ;;
esac
exit 0
STUB
chmod +x "$bin_dir"/*

export TEST_APK_STATE_DIR=$work
export TEST_APK_LOG=$work/apk.log

make_root() {
	rm -rf "$work/root"
	mkdir -p "$work/root/etc/apk/repositories.d"
	printf "DISTRIB_ID='%s'\nDISTRIB_RELEASE='%s'\n" "$1" "$2" >"$work/root/etc/openwrt_release"
	# 真实 25.12.1 distfeeds 结构（含 kernel/kmods），另含应被跳过的自定义源与错误发行版源。
	{
		printf 'https://downloads.openwrt.org/releases/%s/targets/x86/64/packages/packages.adb\n' "$2"
		printf 'https://downloads.openwrt.org/releases/%s/packages/x86_64/base/packages.adb\n' "$2"
		printf 'https://downloads.openwrt.org/releases/%s/targets/x86/64/kmods/6.12.74-1-dad96e0b324e75e311f44d061391d208/packages.adb\n' "$2"
		printf 'https://downloads.openwrt.org/releases/%s/packages/x86_64/luci/packages.adb\n' "$2"
		printf 'https://downloads.openwrt.org/releases/%s/packages/x86_64/routing/packages.adb\n' "$2"
		printf 'https://downloads.openwrt.org/releases/%s/packages/x86_64/telephony/packages.adb\n' "$2"
		printf 'https://downloads.openwrt.org/releases/%s/packages/x86_64/video/packages.adb\n' "$2"
		printf 'https://example.com/custom/packages.adb\n'
		printf 'https://downloads.openwrt.org/releases/24.10.0/packages/x86_64/base/packages.adb\n'
	} >"$work/root/etc/apk/repositories.d/distfeeds.list"
}

# build_media：介质 APK 内容为占位字节；元数据来自桩读取的 adbdump 文件
# （默认为仓库内真实 SDK 夹具，场景可覆写 $work/dumps）。
build_media() {
	rm -rf "${work:?}/media" "${work:?}/dumps"
	mkdir -p "$work/media" "$work/dumps"
	cp "$ROOT/scripts/install.sh" "$work/media/install.sh"
	cp "$fixture_dir/core-adbdump.txt" "$work/dumps/routepolicy-0.3.3-r2.apk.adbdump"
	cp "$fixture_dir/luci-adbdump.txt" "$work/dumps/luci-app-routepolicy-0.3.3-r2.apk.adbdump"
	printf 'core placeholder\n' >"$work/media/routepolicy-0.3.3-r2.apk"
	printf 'luci placeholder\n' >"$work/media/luci-app-routepolicy-0.3.3-r2.apk"
	printf 'install notes\n' >"$work/media/INSTALL.txt"
	( cd "$work/media" && sha256sum install.sh routepolicy-0.3.3-r2.apk luci-app-routepolicy-0.3.3-r2.apk INSTALL.txt >SHA256SUMS )
	rm -f "$work/apk.log" "$work/world-extra" "$work/phase2-done"
	make_root OpenWrt 25.12.1
}

run_case() {
	env PATH="$bin_dir:$PATH" RP_ROOT="$work/root" TEST_DUMP_DIR="$work/dumps" \
		sh "$work/media/install.sh" "$@" >"$work/stdout.txt" 2>"$work/stderr.txt"
}

run_env_case() {
	env PATH="$bin_dir:$PATH" RP_ROOT="$work/root" TEST_DUMP_DIR="$work/dumps" "$@" \
		>"$work/stdout.txt" 2>"$work/stderr.txt"
}

expect_fail() {
	label=$1
	shift
	rc=0
	run_case "$@" || rc=$?
	[ "$rc" -ne 0 ] || fail "$label 应失败但成功"
}

expect_no_apk_add() {
	if [ -f "$work/apk.log" ] && grep -q '^add' "$work/apk.log"; then
		fail '预检失败时不应调用 apk add'
	fi
}

no_add_without_simulate() {
	if [ -f "$work/apk.log" ] && grep '^add' "$work/apk.log" | grep -F -- '--allow-untrusted' | grep -vq -- '--simulate'; then
		fail 'simulate 拒绝后不应执行真实离线安装'
	fi
}

# 1. 正常路径：已安装 smartdns 被保留（阶段一只装缺失依赖），离线 simulate
#    接受实测格式（左补空格、Replacing 自身）
build_media
run_case --allow-local-unsigned || { cat "$work/stderr.txt" >&2; fail '正常安装应成功'; }
[ "$(grep -c '^add' "$work/apk.log")" = 4 ] || fail '应恰好四次 apk add（依赖 simulate/安装、离线 simulate/安装）'
phase1_sim=$(sed -n '1p' "$work/apk.log")
phase1_real=$(sed -n '2p' "$work/apk.log")
printf '%s\n' "$phase1_sim $phase1_real" | grep -Fq -- '--repositories-file' || fail '阶段一必须使用临时官方源'
printf '%s\n' "$phase1_sim $phase1_real" | grep -Fq 'smartdns' && fail '阶段一不得触碰已满足的 smartdns'
printf '%s\n' "$phase1_sim $phase1_real" | grep -Fq 'nftables' && fail '阶段一不得重写已由 nftables-json 提供的虚拟依赖'
printf '%s\n' "$phase1_sim $phase1_real" | grep -Fq 'bind-dig' || fail '阶段一应安装缺失依赖 bind-dig'
[ -f "$work/repositories-used" ] || fail '应捕获阶段一实际使用的源文件'
grep -Fq 'targets/x86/64/kmods/6.12.74-1-dad96e0b324e75e311f44d061391d208/packages.adb' "$work/repositories-used" || fail "必须保留 kernel/kmods 官方源；实际源文件：$(cat "$work/repositories-used")"
grep -Fq 'packages/x86_64/base/packages.adb' "$work/repositories-used" || fail '必须包含 base 官方源'
grep -Fq 'example.com' "$work/repositories-used" && fail '不得继承自定义源'
grep -Fq 'releases/24.10.0' "$work/repositories-used" && fail '不得包含其他发行版源'
sed -n '3p' "$work/apk.log" | grep -Fq -- '--simulate --allow-untrusted --network=no --repositories-file /dev/null' || fail '阶段二应先离线 simulate'
[ "$(sed -n '4p' "$work/apk.log")" = 'add --allow-untrusted --network=no --repositories-file /dev/null ./routepolicy-0.3.3-r2.apk ./luci-app-routepolicy-0.3.3-r2.apk' ] || fail '阶段二应离线仅装本地双包'
grep -Fq 'http://192.168.1.1/cgi-bin/luci' "$work/stdout.txt" || fail '成功输出应提示去 CIDR 后的 LuCI 管理地址'
grep -Fq '向导' "$work/stdout.txt" || fail '未初始化设备应包含向导提示'
grep -Fq '状态未知' "$work/stdout.txt" || fail '未设置 enabled 应报告状态未知'

# 1b. 多地址取首个 IPv4；非法地址回退通用提示
build_media
rc=0
run_env_case TEST_LAN_IP="$(printf '192.168.1.5/24\n10.0.0.5/24')" sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" = 0 ] || fail '多地址场景应成功'
grep -Fq 'http://192.168.1.5/cgi-bin/luci' "$work/stdout.txt" || fail '多地址应取首个 IPv4 条目'
grep -Fq 'http://10.0.0.5' "$work/stdout.txt" && fail '不得展示第二个地址'
build_media
rc=0
run_env_case TEST_LAN_IP='not-an-ip' sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" = 0 ] || fail '非法 LAN 地址不应导致安装失败'
grep -Fq '<设备地址>' "$work/stdout.txt" || fail '非法地址应回退通用设备地址提示'
grep -Fq 'http://192' "$work/stdout.txt" && fail '非法地址不得拼出错误 URL'

# 2. 未显式确认未签名例外
build_media
expect_fail '缺少 --allow-local-unsigned'
expect_no_apk_add

# 3. 非 root / ubus 失败
build_media
rc=0
run_env_case TEST_ID_UID=1000 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail '非 root 应被拒绝'
expect_no_apk_add
build_media
rc=0
run_env_case TEST_UBUS_FAIL=1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail 'ubus 失败应如实报告'

# 4. 不支持的版本 / 发行标识 / 架构
build_media
make_root OpenWrt 24.10.0
expect_fail '不支持版本应被拒绝'
expect_no_apk_add
build_media
make_root Debian 25.12.1
expect_fail '非 OpenWrt 应被拒绝'
expect_no_apk_add
build_media
rc=0
run_env_case TEST_APK_ARCH=aarch64 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail '不支持架构应被拒绝'
expect_no_apk_add

# 5. 介质损坏 / 重复 / 混杂 / 清单结构问题（含 GNU sha256sum -c 会忽略的坏行）
build_media
printf 'corruption' >>"$work/media/routepolicy-0.3.3-r2.apk"
expect_fail '损坏 APK 应被 SHA256SUMS 拒绝'
expect_no_apk_add
build_media
cp "$work/media/routepolicy-0.3.3-r2.apk" "$work/media/routepolicy-9.9.9-r1.apk"
expect_fail '重复 APK 应被拒绝'
expect_no_apk_add
build_media
rm "$work/media/luci-app-routepolicy-0.3.3-r2.apk"
printf 'luci placeholder\n' >"$work/media/luci-app-routepolicy-0.3.4-r1.apk"
cp "$work/dumps/luci-app-routepolicy-0.3.3-r2.apk.adbdump" "$work/dumps/luci-app-routepolicy-0.3.4-r1.apk.adbdump"
( cd "$work/media" && sha256sum install.sh routepolicy-0.3.3-r2.apk luci-app-routepolicy-0.3.4-r1.apk INSTALL.txt >SHA256SUMS )
expect_fail '版本混杂介质应被拒绝'
expect_no_apk_add
build_media
( cd "$work/media" && sha256sum routepolicy-0.3.3-r2.apk luci-app-routepolicy-0.3.3-r2.apk INSTALL.txt >SHA256SUMS )
expect_fail '缺少 install.sh 记录应被拒绝'
expect_no_apk_add
build_media
( cd "$work/media" && tail -n 1 SHA256SUMS >>SHA256SUMS )
expect_fail '重复 SHA256SUMS 记录应被拒绝'
expect_no_apk_add
build_media
rm "$work/media/INSTALL.txt"
expect_fail '清单内文件缺失应被拒绝'
expect_no_apk_add
build_media
printf 'deadbeef  extra.txt\n' >>"$work/media/SHA256SUMS"
expect_fail '非 64 位 hex 摘要行应被结构校验拒绝'
expect_no_apk_add
build_media
printf '%s-extra.txt\n' "$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0)" >>"$work/media/SHA256SUMS"
expect_fail '坏分隔符行应被结构校验拒绝'
expect_no_apk_add

# 6. 元数据异常（修改 adbdump 夹具）
build_media
sed 's/^  name: routepolicy$/  name: wrong-package/' "$fixture_dir/core-adbdump.txt" >"$work/dumps/routepolicy-0.3.3-r2.apk.adbdump"
expect_fail '元数据包名与文件名不符应被拒绝'
expect_no_apk_add
build_media
sed 's/^  version: 0.3.3-r2$/  version: 0.3.3-r1/' "$fixture_dir/core-adbdump.txt" >"$work/dumps/routepolicy-0.3.3-r2.apk.adbdump"
expect_fail '元数据版本与文件名不符应被拒绝'
expect_no_apk_add
build_media
sed 's/^  arch: x86_64$/  arch: aarch64/' "$fixture_dir/core-adbdump.txt" >"$work/dumps/routepolicy-0.3.3-r2.apk.adbdump"
expect_fail '元数据架构不符应被拒绝'
expect_no_apk_add
build_media
sed 's/^    - curl$/    - --purge/' "$fixture_dir/core-adbdump.txt" >"$work/dumps/routepolicy-0.3.3-r2.apk.adbdump"
expect_fail '依赖 token 注入选项应被拒绝'
expect_no_apk_add
build_media
sed 's/^    - curl$/    - bad dep/' "$fixture_dir/core-adbdump.txt" >"$work/dumps/routepolicy-0.3.3-r2.apk.adbdump"
expect_fail '畸形依赖行（含空格）应被拒绝'
expect_no_apk_add
build_media
rc=0
run_env_case TEST_DUMP_STATUS=1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail 'adbdump 非零退出应被拒绝'
expect_no_apk_add

build_media
rm "$work/root/etc/apk/repositories.d/distfeeds.list"
expect_fail '缺少官方 distfeeds 文件应被拒绝'
expect_no_apk_add
build_media
: >"$work/root/etc/apk/repositories.d/distfeeds.list"
expect_fail 'distfeeds 无当前发行版源应被拒绝'
expect_no_apk_add

build_media
sed 's|^    - curl$|    - so:libc.musl-x86_64.so.1|' "$fixture_dir/core-adbdump.txt" >"$work/dumps/routepolicy-0.3.3-r2.apk.adbdump"
expect_fail '复杂依赖 token 应显式拒绝'
expect_no_apk_add
build_media
rc=0
run_env_case TEST_APK_EXIST_STATUS=2 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail 'apk info --exists 异常退出码应被拒绝'
expect_no_apk_add

# 7. 阶段一失败与已安装包保护
build_media
rc=0
run_env_case TEST_APK_ADD_STATUS=3 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" = 3 ] || fail "阶段一 apk 失败应透传退出码 3，实际 $rc"
build_media
rc=0
run_env_case TEST_APK_DEP_SIM_STATUS=1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail '阶段一 simulate 失败应被拒绝'
no_add_without_simulate
build_media
rc=0
run_env_case TEST_APK_DEP_SIM_OUTPUT='(1/1) Upgrading smartdns (46.1-r1 -> 46.1-r2)' sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail '阶段一升级已安装 smartdns 应被拒绝'
no_add_without_simulate

# 8. 阶段二 simulate：外来包 / 未知动作在安装前拒绝
build_media
rc=0
run_env_case TEST_APK_SIM_STATUS=1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail 'simulate 失败应被拒绝'
no_add_without_simulate
build_media
rc=0
run_env_case TEST_APK_SIM_OUTPUT='(1/1) Installing otherpkg (1.0-r0)' sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail 'simulate 安装外来包应被拒绝'
grep -Fq '预检' "$work/stderr.txt" || fail '预检拒绝应如实报告'
no_add_without_simulate
build_media
rc=0
run_env_case TEST_APK_SIM_OUTPUT='(1/1) Pinning curl (8.11.1-r0)' sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail 'simulate 未知动作应被拒绝'
no_add_without_simulate

# 9. 离线安装后 world 漂移（含 routepolicy-extra 前缀包必须被精确识别）必须报告
build_media
rc=0
run_env_case TEST_APK_WORLD_DRIFT=1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail '离线安装漂移应失败'
grep -Fq '离线安装' "$work/stderr.txt" || fail '漂移错误应如实报告'
grep -Fq 'routepolicy-extra 1.0-r0' "$work/stderr.txt" || fail '前缀同名包漂移不得被误过滤'
grep -Fq 'routepolicy-2foo 1696~b21cfa8f8c' "$work/stderr.txt" || fail '同名前缀包（含 ~ 版本）漂移必须被精确识别'

# 9b. 真实 add 成功但 manifest 未落地新双包：旧 RPC 不足以证明落地
build_media
rc=0
run_env_case TEST_APK_NO_LANDING=1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail 'manifest 未精确出现介质双包应被拒绝'
grep -Fq '未精确出现' "$work/stderr.txt" || fail '落地失败应如实报告'

# 10. 升级（安装前 manifest 已有核心包）：只报告观察到的 enabled 状态
build_media
rc=0
run_env_case TEST_UPGRADE_MODE=1 TEST_ENABLED_STATE=1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" = 0 ] || fail '升级安装应成功'
grep -Fq '观察到 routepolicy.main.enabled=1' "$work/stdout.txt" || fail '升级应报告观察到的 enabled 状态'
grep -Fq '待向导配置' "$work/stdout.txt" && fail '升级不得使用新装向导提示'
grep -Fq '默认禁用' "$work/stdout.txt" && fail '不得宣称默认禁用'
grep -Fq '未接管' "$work/stdout.txt" && fail '不得宣称未改变接管'
grep -Fq '未改变' "$work/stdout.txt" && fail '不得宣称未改变状态'
build_media
rc=0
run_env_case TEST_UPGRADE_MODE=1 TEST_ENABLED_STATE=1 TEST_VALIDATE_FAIL=1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" -ne 0 ] || fail '升级且 enabled=1 时 validate 失败应真实报错'
build_media
rc=0
run_env_case TEST_UPGRADE_MODE=1 TEST_ENABLED_STATE=0 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" = 0 ] || fail '升级且 enabled=0 应成功'
grep -Fq '观察到 routepolicy.main.enabled=0' "$work/stdout.txt" || fail '升级应报告观察到的 enabled=0'
build_media
rc=0
run_env_case TEST_UPGRADE_MODE=1 TEST_ENABLED_UNSET=1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" = 0 ] || fail '升级且 enabled 未知不应失败'
grep -Fq '状态未知' "$work/stdout.txt" || fail 'enabled 读取失败应报告状态未知'
grep -Fq '验证完成' "$work/stdout.txt" && fail 'enabled 未知时不得宣称验证完成'

# 版本/schema 不兼容须在缺失依赖和双包的首个写入前拒绝。
for old_version in 0.3.3-r3 0.4.0-r1; do
	build_media
	rc=0
	run_env_case TEST_UPGRADE_MODE=1 TEST_OLD_VERSION="$old_version" TEST_ENABLED_STATE=0 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
	[ "$rc" != 0 ] && [ ! -s "$work/apk.log" ] || fail '停用实例的降级必须零 APK 写入拒绝'
	grep -Fq '不支持降级' "$work/stderr.txt" || fail '降级拒绝原因缺失'
done
build_media
rc=0
run_env_case TEST_UPGRADE_MODE=1 TEST_OLD_LUCI_VERSION=0.4.0-r1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" != 0 ] && [ ! -s "$work/apk.log" ] || fail 'LuCI 单独降级也必须提前拒绝'
build_media
mkdir -p "$work/root/etc/config"
printf 'config main main\n' >"$work/root/etc/config/routepolicy"
rc=0
run_env_case TEST_CONFIG_SCHEMA=2 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
[ "$rc" != 0 ] && [ ! -s "$work/apk.log" ] || fail '固件重装只剩高 schema 配置时必须零 APK 写入拒绝'
grep -Fq 'schema' "$work/stderr.txt" || fail 'schema 拒绝原因缺失'
for pending_case in masked-schema query-failed; do
	build_media
	mkdir -p "$work/root/etc/config"
	printf "config main main\n option config_schema '2'\n" >"$work/root/etc/config/routepolicy"
	rc=0
	if [ "$pending_case" = masked-schema ]; then
		run_env_case TEST_CONFIG_SCHEMA=1 TEST_CONFIG_PENDING="routepolicy.main.config_schema='1'" sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
	else
		run_env_case TEST_CONFIG_CHANGES_STATUS=1 sh "$work/media/install.sh" --allow-local-unsigned || rc=$?
	fi
	[ "$rc" != 0 ] && [ ! -s "$work/apk.log" ] || fail '已有暂存或无法核对暂存时必须零 APK 写入拒绝'
	grep -Fq '未安装任何内容' "$work/stderr.txt" || fail '暂存拒绝原因缺失'
done
for old_version in 0.3.3-r1 0.3.3-r2; do
	build_media
	run_env_case TEST_UPGRADE_MODE=1 TEST_OLD_VERSION="$old_version" sh "$work/media/install.sh" --allow-local-unsigned || fail 'r1 升 r2 和同版本重装应保持支持'
done

printf 'install.sh 功能契约测试通过。\n'
