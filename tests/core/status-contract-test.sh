#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-status-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/state" "$tmp/etc/smartdns/conf.d" "$tmp/proc/sys/kernel/random"
: >"$tmp/etc/config/routepolicy"; : >"$tmp/etc/smartdns/conf.d/90-routepolicy.conf"
printf '00000000-0000-4000-8000-000000000001\n' >"$tmp/proc/sys/kernel/random/boot_id"
printf 'boot_id=00000000-0000-4000-8000-000000000001\npolicy_interface=usbwan\n' >"$tmp/etc/routepolicy/state/applied"
PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	ROUTEPOLICY_OUTPUT=json "$ROOT/routepolicy/files/usr/libexec/routepolicy/status" >"$tmp/status.json"
for fragment in \
	'"versions":{"luci_app_routepolicy":"0.3.1-r1","smartdns":"46.1-r2"}' \
	'"service":{"running":true,"applied":true,"enabled":true}' \
	'"routing":{"real_default":true,"blackhole":true' \
	'"smartdns":{"running":true,"fragment_loaded":false}' \
	'"interfaces":{"lan":{"name":"lan","device":"br-test","address":"192.0.2.1","online":true' \
	'"sets":{"domain_policy4":2'; do
	grep -Fq "$fragment" "$tmp/status.json" || { printf 'missing status contract fragment: %s\n' "$fragment" >&2; cat "$tmp/status.json" >&2; exit 1; }
done
mkdir -p "$tmp/var/etc/smartdns"
printf '%s\n' 'conf-file /etc/smartdns/conf.d/90-routepolicy.conf' >"$tmp/var/etc/smartdns/smartdns.conf"
PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	ROUTEPOLICY_OUTPUT=json "$ROOT/routepolicy/files/usr/libexec/routepolicy/status" >"$tmp/status-loaded.json"
grep -Fq '"smartdns":{"running":true,"fragment_loaded":true}' "$tmp/status-loaded.json" || {
	printf '%s\n' 'generated SmartDNS configuration did not prove fragment loading' >&2
	cat "$tmp/status-loaded.json" >&2
	exit 1
}
TEST_BAD_CONFIG=1 PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	ROUTEPOLICY_OUTPUT=json "$ROOT/routepolicy/files/usr/libexec/routepolicy/status" >"$tmp/status-bad.json"
grep -Fq '"enabled":false' "$tmp/status-bad.json" || { cat "$tmp/status-bad.json" >&2; exit 1; }
grep -Fq '"table":200' "$tmp/status-bad.json" || { cat "$tmp/status-bad.json" >&2; exit 1; }
printf 'source_bootstrap=1\n' >>"$tmp/etc/routepolicy/state/applied"
PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	ROUTEPOLICY_OUTPUT=json "$ROOT/routepolicy/files/usr/libexec/routepolicy/status" >"$tmp/status-bootstrap.json"
grep -Fq '"source_bootstrap":true' "$tmp/status-bootstrap.json"
grep -Fq '"applied":false' "$tmp/status-bootstrap.json"
printf 'boot_id=00000000-0000-4000-8000-000000000001\npolicy_interface=usbwan\n' >"$tmp/etc/routepolicy/state/applied"
printf '00000000-0000-4000-8000-000000000002\n' >"$tmp/proc/sys/kernel/random/boot_id"
PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
	ROUTEPOLICY_OUTPUT=json "$ROOT/routepolicy/files/usr/libexec/routepolicy/status" >"$tmp/status-stale.json"
grep -Fq '"applied":false' "$tmp/status-stale.json" || { printf 'stale boot receipt was reported applied\n' >&2; exit 1; }
# --- source-bootstrap 共享状态契约（PR #24 P2）---
# 回执权威：bootstrap 运行回执始终视为未确认引导；WAL marker 仅在事务未终态时生效。
# 终态 = rolled_back/confirmed/exited；expired 只在 prepared 阶段写入，按未知保守。
# link-phase 依赖真实符号链接，仅 Linux 完整覆盖（Windows 退化为未知内容同样保守）。
BOOT=00000000-0000-4000-8000-000000000003
wal=$tmp/etc/routepolicy/state/init-transaction/current
run_status_json() {
	PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
		ROUTEPOLICY_OUTPUT=json "$ROOT/routepolicy/files/usr/libexec/routepolicy/status"
}
run_diagnose_text() {
	PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
		ROUTEPOLICY_OUTPUT=text "$ROOT/routepolicy/files/usr/libexec/routepolicy/diagnose" 2>&1 || :
}
set_wal() {
	rm -rf "$wal"
	[ -n "${1:-}" ] || return 0
	mkdir -p "$wal"
	[ "$1" = missing-phase ] || printf '%s\n' "$1" >"$wal/phase"
	if [ "$1" = link-phase ]; then rm -f "$wal/phase"; ln -s damaged "$wal/phase"; fi
	printf '1111111111111111111111111111111\n' >"$wal/source-bootstrap"
}
set_receipt() {
	printf 'boot_id=%s\npolicy_interface=usbwan\nsource_bootstrap=%s\n' "$BOOT" "$1" >"$tmp/etc/routepolicy/state/applied"
	printf '%s\n' "$BOOT" >"$tmp/proc/sys/kernel/random/boot_id"
}

# 复现：失败初始化回滚后保留 marker，随后普通 apply 成功（非 bootstrap 回执）。
set_wal rolled_back; set_receipt 0
run_status_json >"$tmp/s-repro.json"
grep -Fq '"source_bootstrap":false' "$tmp/s-repro.json" || { printf '终态 rolled_back 的陈旧 marker 被误报为引导中\n' >&2; cat "$tmp/s-repro.json" >&2; exit 1; }
grep -Fq '"applied":true' "$tmp/s-repro.json" || { printf '普通 apply 成功后被陈旧 marker 压为未应用\n' >&2; cat "$tmp/s-repro.json" >&2; exit 1; }
run_diagnose_text >"$tmp/d-repro.txt"
! grep -q 'source-bootstrap:' "$tmp/d-repro.txt" || { printf 'diagnose 对终态陈旧 marker 假报引导未确认\n' >&2; grep 'source-bootstrap:' "$tmp/d-repro.txt" >&2; exit 1; }

# 回执权威：终态也不得把仍是 bootstrap 的运行回执报为成功。
for phase in rolled_back confirmed exited; do
	set_wal "$phase"; set_receipt 1
	run_status_json >"$tmp/s-$phase-r1.json"
	grep -Fq '"source_bootstrap":true' "$tmp/s-$phase-r1.json" || { printf '终态 %s 不得弱化 bootstrap 回执\n' "$phase" >&2; cat "$tmp/s-$phase-r1.json" >&2; exit 1; }
	grep -Fq '"applied":false' "$tmp/s-$phase-r1.json" || { printf '终态 %s 的 bootstrap 回执不得视为已应用\n' "$phase" >&2; exit 1; }
done

# 终态 + 普通回执：陈旧 marker 是恢复证据，不再视为引导窗口。
for phase in rolled_back confirmed exited; do
	set_wal "$phase"; set_receipt 0
	run_status_json >"$tmp/s-$phase-r0.json"
	grep -Fq '"source_bootstrap":false' "$tmp/s-$phase-r0.json" || { printf '终态 %s 的陈旧 marker 被误报为引导中\n' "$phase" >&2; cat "$tmp/s-$phase-r0.json" >&2; exit 1; }
	grep -Fq '"applied":true' "$tmp/s-$phase-r0.json" || { printf '终态 %s 后普通 apply 应视为已应用\n' "$phase" >&2; exit 1; }
done

# 未完成/冲突/未知/损坏阶段用普通回执，确保 phase 检测真正被覆盖，且保持保守。
for phase in applying pending rolling_back confirming conflict prepared expired unknown missing-phase link-phase; do
	set_wal "$phase"; set_receipt 0
	run_status_json >"$tmp/s-$phase.json"
	grep -Fq '"source_bootstrap":true' "$tmp/s-$phase.json" || { printf '阶段 %s 应保守视为未确认引导\n' "$phase" >&2; cat "$tmp/s-$phase.json" >&2; exit 1; }
	grep -Fq '"applied":false' "$tmp/s-$phase.json" || { printf '阶段 %s 不得视为已应用\n' "$phase" >&2; exit 1; }
done

# 真实未确认引导：pending + bootstrap 回执，diagnose 保留失败项。
set_wal pending; set_receipt 1
run_status_json >"$tmp/s-pending.json"
grep -Fq '"source_bootstrap":true' "$tmp/s-pending.json" || { printf 'pending 引导应报告 source_bootstrap=true\n' >&2; exit 1; }
grep -Fq '"applied":false' "$tmp/s-pending.json" || { printf '未确认引导不得视为已应用\n' >&2; exit 1; }
run_diagnose_text >"$tmp/d-pending.txt"
grep -q '\[fail\] source-bootstrap:' "$tmp/d-pending.txt" || { printf 'diagnose 应保留未确认引导失败项\n' >&2; exit 1; }

# 无 WAL：仅 bootstrap 回执时保持保守（旧契约不变）。
set_wal ''; set_receipt 1
run_status_json >"$tmp/s-nowal.json"
grep -Fq '"source_bootstrap":true' "$tmp/s-nowal.json" || { printf '无 WAL 的 bootstrap 回执应保守视为未确认引导\n' >&2; exit 1; }
grep -Fq '"applied":false' "$tmp/s-nowal.json" || { printf '无 WAL 的 bootstrap 回执不得视为已应用\n' >&2; exit 1; }

printf '%s\n' 'source-bootstrap shared state contract tests: passed'
printf 'status contract tests: passed\n'
