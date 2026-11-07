#!/bin/sh
# 受支持卸载入口的行为测试：rpcd 快照门禁、apk 结果诚实性、删除后核验、
# 以及脚本自删除后仍能完成核验。复用 lifecycle-test.sh 的沙箱/锁模式，
# 需要真实 flock 与 /proc（CI Linux 或 WSL 运行，不注入假锁）。
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-uninstall.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

libexec="$tmp/libexec"
root="$tmp/root"
mkdir -p "$libexec" "$tmp/bin" "$root/etc/config" "$root/etc/routepolicy/user.d" \
	"$root/usr/sbin" "$root/usr/share/rpcd/ucode" "$root/var/run/rpcd" \
	"$root/proc/sys/kernel/random"
printf '44444444-4444-4444-8444-444444444444\n' >"$root/proc/sys/kernel/random/boot_id"
cp "$ROOT/routepolicy/files/usr/libexec/routepolicy/lifecycle" "$libexec/lifecycle"
cp "$ROOT/routepolicy/files/usr/libexec/routepolicy/common" "$libexec/common"
chmod +x "$libexec/lifecycle"

# 供假 apk “删除”的已安装负载。
printf '#!/bin/sh\nroutepolicyctl fixture\n' >"$root/usr/sbin/routepolicyctl"
printf 'return {}\n' >"$root/usr/share/rpcd/ucode/routepolicy"
for package in routepolicy network dhcp firewall smartdns; do
	printf 'unchanged %s\n' "$package" >"$root/etc/config/$package"
done

cat >"$tmp/bin/uci" <<'SH'
#!/bin/sh
while [ $# -gt 0 ]; do
	case "$1" in
		-c|-t) shift ;;
		-q) ;;
		-*) ;;
		*) break ;;
	esac
	shift
done
case "${1:-}" in
	changes)
		if [ "${ROUTEPOLICY_TEST_UCI_PENDING:-0}" = 1 ]; then
			printf 'routepolicy.main.enabled=0\n'
		fi
		;;
	get) exit 1 ;;
esac
exit 0
SH
cat >"$tmp/bin/ubus" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$UBUS_LOG"
case "$*" in
*' call uci configs')
	if [ "${UBUS_CONFIGS_EXIT:-0}" -ne 0 ]; then
		echo 'Connection error' >&2
		exit "${UBUS_CONFIGS_EXIT}"
	fi
	printf '{"configs":["dhcp","network"]}\n'
	exit 0
	;;
list|*' list')
	if [ "${UBUS_LIST_EXIT:-0}" -ne 0 ]; then
		echo 'Connection error' >&2
		exit "${UBUS_LIST_EXIT}"
	fi
	for object in ${UBUS_OBJECTS:-rc uci}; do printf '%s\n' "$object"; done
	exit 0
	;;
esac
exit 1
SH
cat >"$tmp/bin/apk" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$APK_LOG"
[ "${APK_EXIT:-0}" -eq 0 ] || exit "${APK_EXIT}"
if [ "${APK_LEAVE_CLI:-0}" != 1 ]; then rm -f "$ROUTEPOLICY_ROOT/usr/sbin/routepolicyctl"; fi
if [ "${APK_LEAVE_UCODE:-0}" != 1 ]; then rm -f "$ROUTEPOLICY_ROOT/usr/share/rpcd/ucode/routepolicy"; fi
if [ "${APK_SELF_DELETE:-0}" = 1 ]; then rm -f "$ROUTEPOLICY_LIBEXEC/lifecycle" "$ROUTEPOLICY_LIBEXEC/common"; fi
exit 0
SH
chmod +x "$tmp/bin/uci" "$tmp/bin/ubus" "$tmp/bin/apk"

export ROUTEPOLICY_ROOT="$root" ROUTEPOLICY_LIBEXEC="$libexec" ROUTEPOLICY_OUTPUT=json
export APK_LOG="$tmp/apk.log" UBUS_LOG="$tmp/ubus.log"
export PATH="$tmp/bin:$PATH"

restore_fixture() {
	printf '#!/bin/sh\nroutepolicyctl fixture\n' >"$root/usr/sbin/routepolicyctl"
	printf 'return {}\n' >"$root/usr/share/rpcd/ucode/routepolicy"
	# 自删除场景会连脚本与 common 一起删，每次运行前恢复完整 fixture。
	cp "$ROOT/routepolicy/files/usr/libexec/routepolicy/lifecycle" "$libexec/lifecycle"
	cp "$ROOT/routepolicy/files/usr/libexec/routepolicy/common" "$libexec/common"
}

run_uninstall() {
	rm -f "$APK_LOG" "$UBUS_LOG"
	status=0
	printf 'CONFIRM-REMOVE-ROUTEPOLICY\n' | env "$@" sh "$libexec/lifecycle" uninstall >"$tmp/output" 2>&1 || status=$?
}

assert_config_unchanged() {
	for package in routepolicy network dhcp firewall smartdns; do
		[ "$(cat "$root/etc/config/$package")" = "unchanged $package" ] || {
			printf '配置 %s 被卸载流程修改\n' "$package" >&2; exit 1; }
	done
}

# 1. 未提交配置仍在调用 apk 前阻止。
run_uninstall ROUTEPOLICY_TEST_UCI_PENDING=1
[ "$status" -ne 0 ] || { printf '未提交配置应阻止卸载\n' >&2; exit 1; }
[ ! -f "$APK_LOG" ] || { printf '未提交配置时不得调用 apk\n' >&2; exit 1; }
grep -Fq '未提交配置' "$tmp/output" || { printf '缺少未提交配置提示\n' >&2; exit 1; }

# 2. 待确认或遗留快照阻止卸载：不调用 apk、不查询 ubus、不清理任何快照。
for form in dir empty file link; do
	rm -rf "$root/var/run/rpcd/snapshot-files" "$root/var/run/rpcd/snapshot-delta"
	skip=0
	case "$form" in
		dir)
			mkdir "$root/var/run/rpcd/snapshot-files"
			printf 'pending\n' >"$root/var/run/rpcd/snapshot-files/delta"
			;;
		empty) mkdir "$root/var/run/rpcd/snapshot-files" ;;
		file) printf 'leftover\n' >"$root/var/run/rpcd/snapshot-delta" ;;
		link)
			ln -s deleted-target "$root/var/run/rpcd/snapshot-files" 2>/dev/null || true
			[ -L "$root/var/run/rpcd/snapshot-files" ] || { rm -f "$root/var/run/rpcd/snapshot-files"; skip=1; }
			;;
	esac
	[ "$skip" = 0 ] || continue
	run_uninstall
	[ "$status" -ne 0 ] || { printf '快照 %s 应阻止卸载\n' "$form" >&2; exit 1; }
	[ ! -f "$APK_LOG" ] || { printf '快照 %s 存在时不得调用 apk\n' "$form" >&2; exit 1; }
	[ ! -f "$UBUS_LOG" ] || { printf '快照 %s 存在时不得查询 ubus\n' "$form" >&2; exit 1; }
	grep -Fq 'rpcd 快照' "$tmp/output" || { printf '快照 %s 缺少明确提示\n' "$form" >&2; exit 1; }
	case "$form" in
		dir) [ "$(cat "$root/var/run/rpcd/snapshot-files/delta")" = 'pending' ] || { printf '快照负载被修改\n' >&2; exit 1; } ;;
		empty) [ -d "$root/var/run/rpcd/snapshot-files" ] || { printf '空快照目录被清理\n' >&2; exit 1; } ;;
		file) [ -f "$root/var/run/rpcd/snapshot-delta" ] || { printf '快照文件被清理\n' >&2; exit 1; } ;;
		link) [ -L "$root/var/run/rpcd/snapshot-files" ] || { printf '快照链接被清理\n' >&2; exit 1; } ;;
	esac
	assert_config_unchanged
done
rm -rf "$root/var/run/rpcd/snapshot-files" "$root/var/run/rpcd/snapshot-delta"

# 3. apk 失败必须显式失败，不得假装成功。
run_uninstall APK_EXIT=3
[ "$status" -ne 0 ] || { printf 'apk 失败必须返回非零\n' >&2; exit 1; }
grep -Fq 'apk 删除未成功' "$tmp/output" || { printf '缺少 apk 失败提示\n' >&2; exit 1; }
[ -f "$root/usr/sbin/routepolicyctl" ] || { printf 'apk 失败时不得假装文件已删\n' >&2; exit 1; }

# 4. apk 返回 0 但对象残留：明确“可能已移除但收尾未完成”。
run_uninstall UBUS_OBJECTS='rc uci routepolicy'
[ "$status" -ne 0 ] || { printf '对象残留必须返回非零\n' >&2; exit 1; }
grep -Fq '收尾未完成' "$tmp/output" || { printf '缺少收尾未完成提示\n' >&2; exit 1; }
grep -Fq 'del luci-app-routepolicy routepolicy' "$APK_LOG" || { printf 'apk 调用参数不符\n' >&2; exit 1; }

# 5. apk 返回 0 但卸载后查询失败：同样不得假成功。
run_uninstall UBUS_LIST_EXIT=1
[ "$status" -ne 0 ] || { printf '对象列表失败必须返回非零\n' >&2; exit 1; }
grep -Fq '收尾未完成' "$tmp/output" || { printf '列表失败缺少收尾提示\n' >&2; exit 1; }
run_uninstall UBUS_CONFIGS_EXIT=1
[ "$status" -ne 0 ] || { printf '健康检查失败必须返回非零\n' >&2; exit 1; }
grep -Fq '收尾未完成' "$tmp/output" || { printf '健康检查失败缺少收尾提示\n' >&2; exit 1; }

# 6. apk 返回 0 但确切文件仍存在：按路径核验，不依赖 command -v 缓存。
restore_fixture
run_uninstall APK_LEAVE_UCODE=1
[ "$status" -ne 0 ] || { printf 'RPC 插件残留必须返回非零\n' >&2; exit 1; }
grep -Fq '/usr/share/rpcd/ucode/routepolicy' "$tmp/output" || { printf '缺少插件残留提示\n' >&2; exit 1; }
restore_fixture
run_uninstall APK_LEAVE_CLI=1
[ "$status" -ne 0 ] || { printf 'CLI 残留必须返回非零\n' >&2; exit 1; }
grep -Fq '/usr/sbin/routepolicyctl' "$tmp/output" || { printf '缺少 CLI 残留提示\n' >&2; exit 1; }

# 7. 健康卸载：apk 删除脚本自身后仍完成全部核验并输出成功。
restore_fixture
run_uninstall APK_SELF_DELETE=1
[ "$status" -eq 0 ] || { printf '健康卸载应成功：%s\n' "$(cat "$tmp/output")" >&2; exit 1; }
[ ! -e "$libexec/lifecycle" ] || { printf '自删除 fixture 未生效\n' >&2; exit 1; }
grep -Fq '"ok":true' "$tmp/output" || { printf '缺少成功 JSON\n' >&2; exit 1; }
[ ! -e "$root/usr/sbin/routepolicyctl" ] && [ ! -e "$root/usr/share/rpcd/ucode/routepolicy" ] || { printf 'fixture 文件应已删除\n' >&2; exit 1; }
grep -Fq 'call uci configs' "$UBUS_LOG" || { printf '缺少卸载后健康检查\n' >&2; exit 1; }
grep -Fqx -- '-t 2 list' "$UBUS_LOG" || { printf '缺少卸载后对象列表检查\n' >&2; exit 1; }
assert_config_unchanged

# 8. 失败核验同样要在自删除后完成并明确报错。
restore_fixture
run_uninstall APK_SELF_DELETE=1 UBUS_OBJECTS='rc uci routepolicy'
[ "$status" -ne 0 ] || { printf '自删除后的残留核验必须失败\n' >&2; exit 1; }
[ ! -e "$libexec/lifecycle" ] || { printf '自删除 fixture 未生效\n' >&2; exit 1; }
grep -Fq '收尾未完成' "$tmp/output" || { printf '自删除后缺少失败提示\n' >&2; exit 1; }
assert_config_unchanged

printf '%s\n' 'uninstall lifecycle 行为测试通过。'
