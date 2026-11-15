#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
REAL_LIB="${TEST_INIT_LIBEXEC:-$ROOT/routepolicy/files/usr/libexec/routepolicy}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-dns.XXXXXX")
cleanup() {
	[ -z "${guard_pid:-}" ] || kill "$guard_pid" 2>/dev/null || true
	if [ "${TEST_KEEP_INIT_DNS:-0}" = 1 ]; then printf 'init DNS evidence: %s\n' "$tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT HUP INT TERM
export TEST_DNS_TMP=$tmp ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$tmp/lib" ROUTEPOLICY_OUTPUT=json
export TEST_DNS_REAL_APPLY="$REAL_LIB/apply"
export TEST_DNS_REAL_INIT="$ROOT/routepolicy/files/etc/init.d/routepolicy"
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/root/etc/config" "$tmp/root/etc/init.d" "$tmp/root/usr/sbin"
cp "$REAL_LIB/common" "$REAL_LIB/init-dns" "$REAL_LIB/init-transaction" "$tmp/lib/"
cp -R "$REAL_LIB/converters" "$tmp/lib/"
chmod +x "$tmp/lib/"*
cp "$ROOT/tests/core/stubs/smartdns-forward.sh" "$tmp/native-forward"
# The parser must preserve anonymous roots, list ordering, spaces and quotes.
. "$tmp/lib/common"
. "$tmp/lib/init-dns"
printf "config smartdns\n\tlist conf_files '/etc/one'\n\tlist conf_files 'two words'\n" >"$tmp/list.uci"
[ "$(rp_uci_field_data '@smartdns[0]' conf_files <"$tmp/list.uci")" = "$(printf 'list\t/etc/one|two words')" ]
printf "config smartdns 'root'\n\toption label 'can'\\\\''t'\n" >"$tmp/quote.uci"
[ "$(rp_uci_field_data root label <"$tmp/quote.uci")" = "$(printf "scalar\tcan't")" ]
printf "config smartdns\n\tlist conf_files 'ambiguous|value'\n" >"$tmp/bad.uci"
if rp_uci_field_data '@smartdns[0]' conf_files <"$tmp/bad.uci"; then exit 1; fi

# Refuse only native cache/cron side effects; do not edit either user resource.
get() { awk -F '\t' -v key="$1" '$1==key{value=$2;found=1}END{if(found)print value}' "$tmp/native-options"; }
fail() { rp_err "$*"; exit 1; }
native_reject() {
	if (init_dns_native_side_effects main "$1") >"$tmp/native-rejected" 2>&1; then exit 1; fi
	grep -Fq "$2" "$tmp/native-rejected"
}
: >"$tmp/native-options"
init_dns_native_side_effects main 1
mkdir -p "$tmp/root/etc/smartdns" "$tmp/root/etc/crontabs"
printf USER-CACHE >"$tmp/root/etc/smartdns/smartdns.cache"
native_reject 1 '原生回滚启动会删除'
init_dns_native_side_effects main 0
printf 'smartdns.main.cache_file\t/etc/smartdns/custom.cache\n' >"$tmp/native-options"
printf CUSTOM-CACHE >"$tmp/root/etc/smartdns/custom.cache"
for value in 0 off false no disabled invalid; do
	printf 'smartdns.main.cache_persist\t%s\n' "$value" >>"$tmp/native-options"
	native_reject 1 '原生回滚启动会删除'
done
for value in 1 on true yes enabled; do
	printf 'smartdns.main.cache_persist\t%s\n' "$value" >"$tmp/native-options"
	init_dns_native_side_effects main 1
	printf 'smartdns.main.enable_auto_update\t%s\n' "$value" >>"$tmp/native-options"
	native_reject 0 'enable_auto_update 已开启'
done
: >"$tmp/native-options"
for line in '0 5 * * * /etc/init.d/smartdns updatefiles' '# old /etc/initXd/smartdns updatefiles --unused'; do
	printf '%s\n' "$line" >"$tmp/root/etc/crontabs/root"
	cp "$tmp/root/etc/crontabs/root" "$tmp/cron-before"
	native_reject 0 '原生 SmartDNS 自动更新匹配项'
	cmp "$tmp/cron-before" "$tmp/root/etc/crontabs/root"
done
printf '0 5 * * * /usr/bin/other-update\n# smartdns updatefiles\n' >"$tmp/root/etc/crontabs/root"
cp "$tmp/root/etc/crontabs/root" "$tmp/cron-before"
init_dns_native_side_effects main 0
cmp "$tmp/cron-before" "$tmp/root/etc/crontabs/root"
[ "$(cat "$tmp/root/etc/smartdns/smartdns.cache")" = USER-CACHE ]
[ "$(cat "$tmp/root/etc/smartdns/custom.cache")" = CUSTOM-CACHE ]
rm -f "$tmp/root/etc/smartdns/smartdns.cache" "$tmp/root/etc/smartdns/custom.cache" "$tmp/root/etc/crontabs/root"
printf '%s\n' 'init DNS native cache/cron preflight: passed'
if [ "${1:-}" = --native-side-effects ]; then exit 0; fi

# Run the real retirement and admission functions without native UCI or services.
(
	# Dispatcher-created private directories must not alter the later native fixture.
	export ROUTEPOLICY_ROOT="$tmp/control-root"
	awk '/^operation=/{exit} {print}' "$REAL_LIB/init-transaction" >"$tmp/transaction-functions"
	# shellcheck disable=SC1091
	. "$tmp/transaction-functions"
	sync() { :; }
	retire_reset() {
		rm -rf "$TX"
		retire_token=11111111111111111111111111111111
		retire_record="$TX/confirmed/$retire_token"
		mkdir -p "$WAL/fields/1" "$WAL/fields/2" "$retire_record"
		printf '%s\n' "$retire_token" >"$WAL/token"
		printf 'confirmed\n' >"$WAL/phase"
		printf '2\n' >"$WAL/count"
		printf 'set\tsmartdns.main.port\t53\nset\tnetwork.lan.ipaddr\t192.0.2.2\n' >"$WAL/candidate"
		for row in 1 2; do
			entry="$WAL/fields/$row"
			if [ "$row" = 1 ]; then key=smartdns.main.port; value=53; old=6053
			else key=network.lan.ipaddr; value=192.0.2.2; old=192.0.2.1; fi
			printf '%s\n' "$key" >"$entry/key"; printf '%s' "$value" >"$entry/expected"
			printf '%s' "$old" >"$entry/old"; printf 1 >"$entry/existed"
			printf scalar >"$entry/type"; printf scalar >"$entry/expected-type"; : >"$entry/attempted"
		done
		cp -R "$WAL/." "$retire_record/"
		mkdir "$retire_record/origin"
		cp -R "$WAL/fields" "$WAL/count" "$retire_record/origin/"
		printf '1\n' >"$retire_record/origin/schema"
		printf '%s\n' "$retire_token" >"$TX/active"; cp "$TX/active" "$TX/source"
	}
	retire_bad() { if confirmed_fields_retire; then printf 'retired unsafe journal: %s\n' "$1" >&2; exit 1; fi; }
	retire_reset
	cp -R "$retire_record" "$tmp/retire-authority"
	confirmed_fields_retire
	[ ! -e "$WAL/fields" ] && [ -d "$WAL/fields-retired" ] && [ -z "$(find "$WAL/fields-retired" -mindepth 1)" ]
	init_dns_applied_record smartdns.main.port 53
	confirmed_fields_retire
	diff -r "$retire_record" "$tmp/retire-authority"
	retire_reset
	printf 'confirming\n' >"$WAL/phase"; rm "$TX/active" "$TX/source"
	active_publish
	[ "$(read_phase)" = confirmed ] && [ ! -e "$WAL/fields" ] && [ -d "$WAL/fields-retired" ]
	init_dns_applied_record smartdns.main.port 53
	for broken in value missing extra symlink token candidate count phase origin; do
		retire_reset
		case "$broken" in
			value) printf 54 >"$WAL/fields/1/expected" ;;
			missing) rm "$WAL/fields/1/old" ;;
			extra) : >"$WAL/fields/foreign" ;;
			symlink) rm "$WAL/fields/1/old"; ln -s "$retire_record/fields/1/old" "$WAL/fields/1/old" ;;
			token) printf '22222222222222222222222222222222\n' >"$WAL/token" ;;
			candidate) printf 'set\tsmartdns.main.port\t54\n' >"$WAL/candidate" ;;
			count) printf '1\n' >"$WAL/count" ;;
			phase) printf 'pending\n' >"$WAL/phase" ;;
			origin) rm "$retire_record/origin/fields/1/old" ;;
		esac
		retire_bad "$broken"
		[ -d "$WAL/fields" ] && [ ! -e "$WAL/fields-retired" ]
	done
	# A sync failure after rename leaves the durable retry identity and original files.
	retire_reset
	sync() { return 1; }
	retire_bad rename-sync
	[ -d "$WAL/fields-retired/1" ] && [ ! -e "$WAL/fields" ]
	init_dns_applied_record smartdns.main.port 53
	sync() { :; }
	printf changed >"$WAL/fields-retired/1/old"
	retire_bad changed-leftover
	[ "$(cat "$WAL/fields-retired/1/old")" = changed ]
	cp "$retire_record/fields/1/old" "$WAL/fields-retired/1/old"
	rm "$WAL/fields-retired/1/old"
	rm -rf "$WAL/fields-retired/2"
	confirmed_fields_retire
	[ -z "$(find "$WAL/fields-retired" -mindepth 1)" ]
	# A retirement marker never authorizes another phase, generation or candidate.
	for broken in phase token candidate count both marker-link foreign-leftover; do
		retire_reset
		confirmed_fields_retire
		case "$broken" in
			phase) printf 'prepared\n' >"$WAL/phase" ;;
			token) printf '22222222222222222222222222222222\n' >"$WAL/token" ;;
			candidate) printf 'set\tsmartdns.main.port\t54\n' >"$WAL/candidate" ;;
			count) printf '1\n' >"$WAL/count" ;;
			both) mkdir "$WAL/fields" ;;
			marker-link) rmdir "$WAL/fields-retired"; ln -s "$tmp" "$WAL/fields-retired" ;;
			foreign-leftover) printf foreign >"$WAL/fields-retired/user.keep" ;;
		esac
		retire_bad "$broken"
		if [ "$broken" = phase ]; then
			# shellcheck disable=SC2034
			operation=recover
			if prepared_finish_locked; then printf 'expired retired prepared journal\n' >&2; exit 1; fi
			[ "$(read_phase)" = prepared ]
		fi
		if [ "$broken" != foreign-leftover ]; then
			if init_dns_applied_record smartdns.main.port 53; then printf 'admitted unsafe retired journal: %s\n' "$broken" >&2; exit 1; fi
		else [ "$(cat "$WAL/fields-retired/user.keep")" = foreign ]; fi
	done
	retire_reset
	rm -rf "$retire_record/origin"
	confirmed_fields_retire
	[ -d "$WAL/fields" ] && [ ! -e "$WAL/fields-retired" ]
	init_dns_applied_record smartdns.main.port 53
	# Every traversal failure must propagate, even after producing a plausible listing.
	find() (
		calls=$(cat "$tmp/retire-find-count"); calls=$((calls+1))
		printf '%s\n' "$calls" >"$tmp/retire-find-count"
		if [ "$calls" = "$find_fail" ]; then
			[ "$find_error_output" != partial ] || command find "$@"
			return 87
		fi
		command find "$@"
	)
	for find_layout in fresh empty-retired partial-retired; do
		retire_reset
		case "$find_layout" in
			empty-retired) rm -rf "$WAL/fields"; mkdir "$WAL/fields-retired" ;;
			partial-retired) mv "$WAL/fields" "$WAL/fields-retired"; rm "$WAL/fields-retired/1/old" ;;
		esac
		printf '0\n' >"$tmp/retire-find-count"; find_fail=0; find_error_output=empty
		confirmed_fields_retire
		find_total=$(cat "$tmp/retire-find-count")
		for find_error_output in empty partial; do
			find_fail=1
			while [ "$find_fail" -le "$find_total" ]; do
				retire_reset
				case "$find_layout" in
					empty-retired) rm -rf "$WAL/fields"; mkdir "$WAL/fields-retired" ;;
					partial-retired) mv "$WAL/fields" "$WAL/fields-retired"; rm "$WAL/fields-retired/1/old" ;;
				esac
				printf '0\n' >"$tmp/retire-find-count"
				retire_bad "$find_layout/$find_error_output/find-$find_fail"
				[ "$(cat "$tmp/retire-find-count")" = "$find_fail" ]
				diff -r "$retire_record" "$tmp/retire-authority"
				find_fail=$((find_fail+1))
			done
		done
	done
	unset -f find
	# Exercise lock's actual early-boot ordering with a bounded service stand-in.
	(
		writer_lock() { :; }
		init_dns_managed() { return 0; }
		early_dns_boot_ready() { return 1; }
		init_dns_coordinate() {
			[ "$1" = quarantine-boot ] || return 1
			if [ "$retire_boot_case" = full ]; then
				[ -d "$WAL/fields-retired" ] && [ ! -e "$WAL/fields" ] && [ -z "$(find "$WAL/fields-retired" -mindepth 1)" ] || return 1
			fi
			printf 'isolated\n' >"$tmp/retire-quarantine"
		}
		# shellcheck disable=SC2034
		operation=recover-early
		retire_boot_case=full
		retire_reset
		lock
		grep -Fxq isolated "$tmp/retire-quarantine"
		[ -d "$WAL/fields-retired" ] && [ ! -e "$WAL/fields" ]
		retire_boot_case=corrupt
		retire_reset
		rm "$tmp/retire-quarantine"
		printf changed >"$WAL/fields/2/old"
		if (lock) >"$tmp/retire-lock-error" 2>&1; then printf 'early boot ignored failed retirement\n' >&2; exit 1; fi
		grep -Fxq isolated "$tmp/retire-quarantine"
		grep -Fq '不能安全收敛确认字段副本' "$tmp/retire-lock-error"
		[ "$(cat "$WAL/fields/2/old")" = changed ] && [ ! -e "$WAL/fields-retired" ]
	)
	# On an already confirmed full filesystem, retirement precedes fresh pointer files.
	retire_reset
	sync() {
		[ ! -e "$TX/active.new" ] && [ ! -e "$WAL/phase.new" ] || return 1
		[ -d "$WAL/fields-retired" ] || return 1
		if [ -n "$(find "$WAL/fields-retired" -mindepth 1)" ]; then return 0; fi
		return 1
	}
	if active_publish; then printf 'expected interrupted post-retirement sync\n' >&2; exit 1; fi
	[ -d "$WAL/fields-retired" ] && [ -z "$(find "$WAL/fields-retired" -mindepth 1)" ]
	[ ! -e "$TX/active.new" ] && [ ! -e "$WAL/phase.new" ]
	printf '%s\n' 'confirmed field retirement: passed (exact provenance, durable rename, partial cleanup, legacy, admission, boot isolation, traversal errors and pre-allocation ordering)'
	# Keep the real dispatch, FD9 gate and boot coordinator; replace only native effects.
	mkdir "$tmp/cold-lib"
	cp "$REAL_LIB/common" "$REAL_LIB/init-dns" "$tmp/cold-lib/"
	cp "$tmp/transaction-functions" "$tmp/cold-entry"
	cat >>"$tmp/cold-entry" <<'EOF'
rp_config_admit() { :; }
load_args() { :; }
uci_layout() { :; }
no_pending() { :; }
rp_uci_get() { [ "$*" = 'main enabled 0' ] && printf '1\n'; }
init_dns_managed() { rp_writer_owned && [ "$ROUTEPOLICY_WRITER_KIND" = init ]; }
init_dns_managed_admit() { init_dns_managed; }
init_resolver_required() { :; }
init_resolver_prepare() { [ "$1" = boot ]; }
init_resolver_origin() { :; }
init_dns_stop() { :; }
uci_committed() { [ "$*" = 'get routepolicy.main.enabled' ] && printf '1\n'; }
init_dns_policy_adapter() { return 1; }
rp_smartdns_set_registration() { :; }
policy_verify_runtime() { [ -f "$TEST_DNS_TMP/cold-policy-ready" ]; }
init_dns_call() {
    if [ "$1:$2" = smartdns:start ]; then
        [ -f "$TEST_DNS_TMP/cold-policy-ready" ] || return 1
        printf 'dns-start\n' >>"$TEST_DNS_TMP/cold-trace"
    fi
}
init_resolver_install() {
    printf 'resolver-install\n' >>"$TEST_DNS_TMP/cold-trace"
    : >"$TEST_DNS_TMP/cold-resolver-ready"
}
init_dns_coordinate() {
    case "$1" in
        quarantine-boot)
            ! rp_smartdns_package_pending && rp_writer_owned || return 1
            printf 'quarantine\n' >>"$TEST_DNS_TMP/cold-trace" ;;
        verify)
            [ -f "$TEST_DNS_TMP/cold-resolver-ready" ] || return 1
            printf 'dns-verify\n' >>"$TEST_DNS_TMP/cold-trace" ;;
        *) return 1 ;;
    esac
}
init_dns_service_state() {
    [ "$1" = routepolicy ] || return 1
    [ ! -e "$TEST_DNS_TMP/cold-watch-query-fail" ] || return 1
    if [ -f "$TEST_DNS_TMP/cold-watch-running" ]; then printf 1; else printf 0; fi
}
status_json() { :; }
sync() { :; }
# Test-only entry for the real stop decision, before appending the dispatcher.
if [ "${1:-}" = test-guard-stop ]; then guard_stop_if_inactive; exit $?; fi
EOF
	awk 'found || /^operation=/ {found=1; print}' "$REAL_LIB/init-transaction" >>"$tmp/cold-entry"
	cat >"$tmp/cold-lib/apply" <<'EOF'
#!/bin/sh
set -eu
. "$ROUTEPOLICY_LIBEXEC/common"
if [ -z "${ROUTEPOLICY_WRITER_OWNER:-}" ]; then
    rp_writer_enter apply
    printf 'watch-apply\n' >>"$TEST_DNS_TMP/cold-trace"
    exit 0
fi
rp_writer_owned
[ "$ROUTEPOLICY_WRITER_KIND:$ROUTEPOLICY_DNS_DEFER" = init:1 ]
[ ! -e "$TEST_DNS_TMP/cold-policy-fail" ] || exit 1
printf 'policy\n' >>"$TEST_DNS_TMP/cold-trace"
: >"$TEST_DNS_TMP/cold-policy-ready"
EOF
	cat >"$tmp/cold-lib/smartdns-package" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = package-recover ] || [ "$1" = package-recover-early ]
[ ! -e "$TEST_DNS_TMP/cold-conflict" ] || exit 1
rm -rf "$ROUTEPOLICY_ROOT/etc/routepolicy/state/smartdns-package/current"
printf 'package-clear\n' >>"$TEST_DNS_TMP/cold-trace"
EOF
	mkdir -p "$tmp/cold-bin" "$RP_ROOT/etc/init.d"
	cat >"$tmp/cold-bin/ubus" <<'EOF'
#!/bin/sh
set -eu
[ "$*" = 'call service delete {"name":"routepolicy-initguard","instance":"guard"}' ]
printf 'guard-stop\n' >>"$TEST_DNS_TMP/cold-trace"
EOF
	cat >"$RP_ROOT/etc/init.d/routepolicy" <<'EOF'
#!/bin/sh
set -eu
# Keep the actual init preamble/start_service and model rc.common's lock order.
[ "$*" = start ]
[ -z "${ROUTEPOLICY_WRITER_OWNER:-}" ] && [ -z "${ROUTEPOLICY_WRITER_KIND:-}" ]
(exec 9>"$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/lock"; flock -n 9)
action=start
shift
ROUTEPOLICY_INIT_TRANSACTION="$TEST_DNS_TMP/cold-entry"
ROUTEPOLICY_CTL="$ROUTEPOLICY_LIBEXEC/apply"
config_load() { :; }
config_get_bool() { enabled=1; }
procd_open_instance() { :; }
procd_set_param() { :; }
procd_close_instance() {
    printf 'watch-register\n' >>"$TEST_DNS_TMP/cold-trace"
    if [ -e "$TEST_DNS_TMP/cold-watch-fail-once" ]; then
        rm "$TEST_DNS_TMP/cold-watch-fail-once"
        return 1
    fi
    : >"$TEST_DNS_TMP/cold-watch-running"
}
. "$TEST_DNS_REAL_INIT"
exec 8>"$TEST_DNS_TMP/cold-procd-lock"
flock -n 8
start_service
EOF
	chmod +x "$tmp/cold-bin/ubus" "$RP_ROOT/etc/init.d/routepolicy"
	PATH="$tmp/cold-bin:$PATH"; export PATH
	chmod +x "$tmp/cold-entry" "$tmp/cold-lib/apply" "$tmp/cold-lib/smartdns-package"
	cold_entry() { ROUTEPOLICY_LIBEXEC="$tmp/cold-lib" "$tmp/cold-entry" "$@"; }
	cold_reset() {
		retire_reset
		mkdir -p "$RP_ROOT/proc/sys/kernel/random"
		printf '11111111-1111-1111-1111-111111111111\n' >"$WAL/boot-id"
		cp "$WAL/boot-id" "$retire_record/boot-id"
		printf '22222222-2222-2222-2222-222222222222\n' >"$RP_ROOT/proc/sys/kernel/random/boot_id"
		rm -f "$tmp/cold-policy-ready" "$tmp/cold-resolver-ready" "$tmp/cold-policy-fail" "$tmp/cold-conflict"
		rm -f "$tmp/cold-watch-running" "$tmp/cold-watch-fail-once" "$tmp/cold-watch-query-fail"
		: >"$tmp/cold-trace"
	}
	cold_assert_order() {
		[ "$(grep -E '^(policy|dns-start|resolver-install|dns-verify)$' "$tmp/cold-trace")" = "$(printf 'policy\ndns-start\nresolver-install\ndns-verify')" ]
		cmp "$retire_record/dns-boot-ready" "$RP_ROOT/proc/sys/kernel/random/boot_id"
		[ ! -e "$retire_record/dns-boot-pending" ]
	}
	cold_reset
	mkdir -p "$RP_SMARTDNS_PACKAGE_STATE/current"
	: >"$tmp/cold-conflict"
	if cold_entry recover-early >"$tmp/cold-error" 2>&1; then exit 1; fi
	[ ! -e "$retire_record/dns-boot-pending" ] && [ ! -e "$retire_record/dns-boot-ready" ]
	# Until package recovery clears current, normal init admission remains closed.
	if cold_entry boot-dns >"$tmp/cold-error" 2>&1; then exit 1; fi
	if cold_entry recover-startup boot >"$tmp/cold-error" 2>&1; then exit 1; fi
	[ ! -s "$tmp/cold-trace" ]
	rm "$tmp/cold-conflict"
	cold_entry guard
	cold_assert_order
	[ ! -e "$RP_SMARTDNS_PACKAGE_STATE/current" ]
	[ -f "$tmp/cold-watch-running" ]
	[ "$(grep -Ec '^(dns-verify|watch-apply|watch-register)$' "$tmp/cold-trace")" = 3 ]
	[ "$(grep -E '^(dns-verify|watch-apply|watch-register)$' "$tmp/cold-trace")" = "$(printf 'dns-verify\nwatch-apply\nwatch-register')" ]
	# Model interruption after durable DNS ready but before service registration.
	cold_reset
	cold_entry boot-dns
	[ ! -e "$tmp/cold-watch-running" ]
	cold_entry guard-needed
	if cold_entry boot-pending; then exit 1; fi
	if cold_entry test-guard-stop; then exit 1; fi
	if grep -Fxq guard-stop "$tmp/cold-trace"; then exit 1; fi
	# An unreadable procd response must retain the handoff, not stop the guard.
	: >"$tmp/cold-watch-query-fail"
	cold_entry guard-needed
	if cold_entry test-guard-stop; then exit 1; fi
	rm "$tmp/cold-watch-query-fail"
	: >"$tmp/cold-watch-fail-once"
	cold_entry guard
	[ -f "$tmp/cold-watch-running" ]
	[ "$(grep -c '^watch-register$' "$tmp/cold-trace")" = 2 ]
	cold_assert_order
	: >"$tmp/cold-trace"
	cold_entry guard
	if grep -Eq '^watch-(apply|register)$' "$tmp/cold-trace"; then exit 1; fi
	if cold_entry guard-needed; then exit 1; fi
	# Model a killed guard after package cleanup but before publishing DNS pending.
	cold_reset
	cold_entry guard-needed
	cold_entry boot-pending
	cold_entry guard
	cold_assert_order
	# S95 also derives the missing handoff, and a failed policy never starts DNS.
	cold_reset
	[ "$(cold_entry recover-startup boot)" = boot-policy-coordinated ]
	[ -f "$retire_record/dns-boot-pending" ]
	: >"$tmp/cold-policy-fail"
	if cold_entry boot-dns >"$tmp/cold-error" 2>&1; then exit 1; fi
	if grep -Fqx dns-start "$tmp/cold-trace"; then exit 1; fi
	[ -f "$retire_record/dns-boot-pending" ]
	rm "$tmp/cold-policy-fail"
	cold_entry guard
	cold_assert_order
	: >"$tmp/cold-trace"
	if cold_entry guard-needed || cold_entry boot-pending; then exit 1; fi
	cold_entry boot-dns
	[ ! -s "$tmp/cold-trace" ]
	cold_reset
	cp "$RP_ROOT/proc/sys/kernel/random/boot_id" "$WAL/boot-id"
	cp "$WAL/boot-id" "$retire_record/boot-id"
	if cold_entry guard-needed || cold_entry boot-pending; then exit 1; fi
	cold_entry boot-dns
	[ ! -s "$tmp/cold-trace" ]
	rm -rf "$TX"
	printf '%s\n' 'cold package reentry: passed (early failure, real gate, lost wakeup, S94/S95, policy before DNS, resolver ordering, watch retry/lock order and same-boot no-op)'
)
[ ! -e "$tmp/root/tmp" ]
case "${1:-}" in --confirmed-fields|--cold-reentry) exit 0 ;; esac

if [ -n "${TEST_UCI_SDK_ROOT:-}" ]; then
	cat >"$tmp/bin/native-uci" <<'EOF'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/sbin/uci" "$@"
EOF
	cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/usr/bin/jsonfilter" "$@"
EOF
elif command -v uci >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
	ln -s "$(command -v uci)" "$tmp/bin/native-uci"
else
	printf '%s\n' 'init DNS parser: passed; native WAL/service matrix skipped (provide TEST_UCI_SDK_ROOT)'
	exit 0
fi
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
native-uci -c "$ROUTEPOLICY_ROOT/etc/config" -t "$TEST_DNS_TMP/external" "$@" || exit $?
if [ -n "${TEST_EXIT_UCI_TRACE:-}" ]; then
	printf '%s\n' "$*" >>"$TEST_EXIT_UCI_TRACE"
	case " $* " in *' export '*_smartdns' ')
		if [ -f "$TEST_DNS_TMP/exit-origin-change" ]; then
			mode=$(cat "$TEST_DNS_TMP/exit-origin-change")
			rm "$TEST_DNS_TMP/exit-origin-change"
			case "$mode" in
				missing) rm "$TEST_EXIT_ORIGIN_FIELD/expected" ;;
				tab) printf 'scalar\t1' >"$TEST_EXIT_ORIGIN_FIELD/expected-type" ;;
				key) printf 'firewall.rp_init_dns.src' >"$TEST_EXIT_ORIGIN_FIELD/key" ;;
			esac
		fi
		if [ -f "$TEST_DNS_TMP/exit-uci-change" ]; then
			mode=$(cat "$TEST_DNS_TMP/exit-uci-change")
			rm "$TEST_DNS_TMP/exit-uci-change"
			native-uci -c "$ROUTEPOLICY_ROOT/etc/config" -t "$TEST_DNS_TMP/external" set routepolicy.main.user_note=EXTERNAL || exit 1
			if [ "$mode" = committed ]; then native-uci -c "$ROUTEPOLICY_ROOT/etc/config" -t "$TEST_DNS_TMP/external" commit routepolicy || exit 1; fi
		fi ;;
	esac
fi
case " $* " in *' commit '*)
	if [ -f "$TEST_DNS_TMP/kill-stage" ] && [ "$(cat "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/stage")" = "$(cat "$TEST_DNS_TMP/kill-stage")" ]; then
		rm "$TEST_DNS_TMP/kill-stage"; kill -KILL "$PPID"
	fi ;;
esac
case "$(cat "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/stage" 2>/dev/null)" in
	commit:*)
		if [ "$(cat "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current/phase")" = applying ] && [ ! -f "$TEST_DNS_TMP/svc/smartdns.absent" ]; then
			printf 'native SmartDNS writer still registered during candidate commit\n' >&2; exit 1
		fi ;;
esac
EOF
cat >"$tmp/bin/sync" <<'EOF'
#!/bin/sh
wal="$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current"
if [ -f "$TEST_DNS_TMP/kill-confirm" ] && [ "$(cat "$wal/phase" 2>/dev/null)" = confirming ]; then
	point=$(cat "$TEST_DNS_TMP/kill-confirm")
	if [ "$point" = intent ] || { [ "$point" = pointer ] && [ "$(cat "${wal%/current}/active" 2>/dev/null)" = "$(cat "$wal/token")" ]; }; then
		rm "$TEST_DNS_TMP/kill-confirm"; kill -KILL "$PPID"
	fi
fi
if [ -f "$TEST_DNS_TMP/kill-exit-identity" ]; then
	for stage in "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/"exit-preparing.*; do
		if [ "$(cat "$stage/token" 2>/dev/null)" = "${TEST_EXIT_TOKEN:-}" ] && [ "$(cat "$stage/kind" 2>/dev/null)" = exit ]; then
			rm "$TEST_DNS_TMP/kill-exit-identity"; kill -KILL "$PPID"
		fi
	done
fi
for interrupted_phase in preparing installed; do
	if [ -f "$TEST_DNS_TMP/kill-$interrupted_phase" ] && [ "$(cat "${wal%/current}/declarations/phase" 2>/dev/null)" = "$interrupted_phase" ]; then
		rm "$TEST_DNS_TMP/kill-$interrupted_phase"; kill -KILL "$PPID"
	fi
done
if [ -f "$TEST_DNS_TMP/fail-managed-sync" ] &&
	grep -Fq 'smartdns90:address /firmware-local.lab19.test/' "$ROUTEPOLICY_ROOT/etc/routepolicy/state/applied" 2>/dev/null; then
	rm "$TEST_DNS_TMP/fail-managed-sync"; exit 1
fi
for candidate in "$ROUTEPOLICY_ROOT/tmp/routepolicy/"smartdns-apply.*/applied.candidate; do
	[ -f "$candidate" ] || continue
	if [ -f "$TEST_DNS_TMP/change-managed-receipt" ]; then
		rm "$TEST_DNS_TMP/change-managed-receipt"
		printf 'external_owner=keep\n' >>"$ROUTEPOLICY_ROOT/etc/routepolicy/state/applied"
	fi
	if [ -f "$TEST_DNS_TMP/change-managed-file" ]; then
		rm "$TEST_DNS_TMP/change-managed-file"
		printf 'address /external-during-publish.test/203.0.114.99\n' >>"$ROUTEPOLICY_ROOT/etc/smartdns/conf.d/90-routepolicy.conf"
	fi
done
exit 0
EOF
# Keep the real planner ownership decision at the transaction/service fixture seam.
sed -n '/^own_section() {/,/^}/p' "$REAL_LIB/init-topology" >"$tmp/ownership"
cat >"$tmp/lib/init-topology" <<'EOF'
#!/bin/sh
set -eu
. "$ROUTEPOLICY_LIBEXEC/common"
. "$ROUTEPOLICY_LIBEXEC/init-dns"
get() { uci -q get "$1" 2>/dev/null || true; }
sections() { uci -q show "$1" | sed -n "s/^$1\.\([^.=]*\)=$2$/\1/p"; }
field() { printf '%s\n' "$1" | jsonfilter -e "$2"; }
ident() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; }
fail() { rp_err "$*"; exit 1; }
set_value() { printf 'set\t%s\t%s\n' "$1" "$2"; }
. "$TEST_DNS_TMP/ownership"
operation=$1
access=lan default_if=wan policy=wan2 access_device=br-lan default_device=eth1 policy_device=eth2
[ ! -f "$TEST_DNS_TMP/source-new-policy" ] || policy=rp_init_policy
dns_default=${13:--} dns_policy=${14:--}
case "$1" in
	plan)
		own_section firewall.rp_init_dns
		set_value firewall.rp_init_dns rule
		set_value firewall.rp_init_dns.name routepolicy-init-dns
		set_value firewall.rp_init_dns.src lan
		set_value firewall.rp_init_dns.target ACCEPT
		set_value firewall.rp_init_dns.dest_port 53
		set_value routepolicy.main.enabled 1
		set_value routepolicy.main.policy_interface "$policy"
		if [ -f "$TEST_DNS_TMP/source-new-policy" ]; then
			set_value network.rp_init_policy interface
			set_value network.rp_init_policy.proto static
			set_value network.rp_init_policy.device eth2
			set_value network.rp_init_policy.ipaddr 198.51.100.2
			set_value network.rp_init_policy.netmask 255.255.255.0
			set_value network.rp_init_policy.gateway 198.51.100.1
		fi
		init_ipv4_plan
		init_dns_plan ;;
	link-plan) printf 'required\t0\n' ;;
	management-address) [ ! -f "$TEST_DNS_TMP/policy-down" ] || exit 1; uci -q get network.lan.ipaddr ;;
	verify)
		own_section firewall.rp_init_dns
		printf '{"ok":true,"operation":"verify","management_address":"192.0.2.1","default_egress":"verified"}\n' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
case "$2:${3:-}" in
	service:list)
		service=$(printf '%s' "${4:-}" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
		[ "$service" != routepolicy-initguard ] || { printf '{"routepolicy-initguard":{"instances":{"guard":{"running":true}}}}'; exit 0; }
		[ -n "$service" ] || exit 1
		[ ! -f "$TEST_DNS_TMP/list-fail" ] || exit 1
		if [ "$service" = smartdns ] && [ -f "$TEST_DNS_TMP/svc/smartdns.absent" ]; then printf '{}\n'; exit 0; fi
		running=false; [ "$(cat "$TEST_DNS_TMP/svc/$service.running")" != 1 ] || running=true
		pid=
		if [ "$service:$running" = smartdns:true ]; then pid=$(printf ',"pid":%s' "$(cat "$TEST_DNS_TMP/svc/smartdns.pid")"); fi
		printf '{"%s":{"instances":{"main":{"running":%s%s}}}}\n' "$service" "$running" "$pid" ;;
	service:delete)
		case "${4:-}" in *routepolicy-initguard*) exit 0 ;; esac
		[ ! -f "$TEST_DNS_TMP/delete-fail" ] || exit 1
		[ ! -f "$TEST_DNS_TMP/svc/smartdns.absent" ] || exit 4
		printf 0 >"$TEST_DNS_TMP/svc/smartdns.running"
		: >"$TEST_DNS_TMP/svc/smartdns.absent"
		if [ -f "$TEST_DNS_TMP/delete-race" ]; then rm "$TEST_DNS_TMP/delete-race"; exit 4; fi
		if [ -f "$TEST_DNS_TMP/quiesce-fault" ]; then
			wal="$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current"
			rm "$TEST_DNS_TMP/quiesce-fault" "$wal/dns-file-new"; mkdir "$wal/dns-file-new"
		fi ;;
	network.interface.rp_init_policy:status)
		[ "$(uci -q get network.rp_init_policy.proto 2>/dev/null)" = static ] || { printf '{"up":false}\n'; exit 0; }
		printf '{"up":true,"l3_device":"eth2","dns-server":["198.51.100.53"],"route":[{"target":"0.0.0.0","nexthop":"198.51.100.1"}]}\n' ;;
	network.interface.wan:status|network.interface.wan2:status)
		if [ "$2" = network.interface.wan2 ] && [ -f "$TEST_DNS_TMP/policy-down" ]; then printf '{"up":false}\n'; exit 0; fi
		device=eth1; [ "$2" != network.interface.wan2 ] || device=eth2
		printf '{"up":true,"l3_device":"%s","dns-server":["192.0.2.53"],"route":[{"target":"0.0.0.0","nexthop":"198.51.100.1"}]}\n' "$device" ;;
	network.interface.lan:status)
		printf '{"up":true,"l3_device":"br-lan","ipv4-address":[{"address":"192.0.2.1","mask":24}]}\n' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/netstat" <<'EOF'
#!/bin/sh
[ ! -f "$TEST_DNS_TMP/netstat-fail" ] || exit 1
for service in smartdns dnsmasq; do
	[ "$(cat "$TEST_DNS_TMP/svc/$service.running")" = 1 ] || continue
	port=$(cat "$TEST_DNS_TMP/svc/$service.port")
	[ "$port" != 0 ] || continue
	owner="101/$service"
	if [ "$service" = smartdns ]; then
		owner="$(cat "$TEST_DNS_TMP/svc/smartdns.pid")/smartdns"
		case "$(cat "$TEST_DNS_TMP/svc/listener-fault" 2>/dev/null)" in
			reload-pending) continue ;;
			reload-foreign) owner=999/foreign ;;
		esac
	fi
	printf 'tcp 0 0 0.0.0.0:%s 0.0.0.0:* LISTEN %s\nudp 0 0 0.0.0.0:%s 0.0.0.0:* %s\n' "$port" "$owner" "$port" "$owner"
	if [ "$service" = smartdns ] && [ "$(cat "$TEST_DNS_TMP/svc/compensation-fault" 2>/dev/null)" = reload-partial ] &&
		[ ! -f "$TEST_DNS_TMP/svc/listener-fault" ]; then
		# Distinct device-bound sockets can display the same tuple in netstat.
		printf 'tcp 0 0 0.0.0.0:%s 0.0.0.0:* LISTEN %s\n' "$port" "$owner"
	fi
	if [ "$service" = dnsmasq ] && [ "${TEST_DNS_IPV6:-0}" = 1 ]; then
		printf 'tcp6 0 0 :::%s :::* LISTEN 101/dnsmasq\nudp6 0 0 :::%s :::* 101/dnsmasq\n' "$port" "$port"
	fi
done
EOF
cat >"$tmp/bin/dig" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_DNS_TMP/queries"
port=53; previous=
for argument do [ "$previous" != -p ] || port=$argument; previous=$argument; done
found=0
for service in smartdns dnsmasq; do
	[ "$(cat "$TEST_DNS_TMP/svc/$service.running")" != 1 ] || [ "$(cat "$TEST_DNS_TMP/svc/$service.port")" != "$port" ] || found=1
done
[ "$found" = 1 ] || exit 9
case "$*" in *routepolicy-init-resolver.test*)
	grep -Fxq 'address /routepolicy-init-resolver.test/127.0.0.1' "$ROUTEPOLICY_ROOT/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf" || exit 12
	case "$*" in *@127.0.0.1*) ;; *) [ "$(readlink "$ROUTEPOLICY_ROOT/tmp/resolv.conf")" = /tmp/resolv.conf.d/routepolicy.conf ] || exit 10 ;; esac
	[ "$(cat "$TEST_DNS_TMP/svc/smartdns.running")$(cat "$TEST_DNS_TMP/svc/smartdns.port")" = 153 ] || exit 11
	printf '127.0.0.1\n'; exit 0 ;;
esac
if [ -f "$TEST_DNS_TMP/query-fail" ] && [ "$*" != "${*%routepolicy-init-restore.test*}" ]; then printf ';; ->>HEADER<<- status: NOERROR, id: 1\n'
elif [ -f "$TEST_DNS_TMP/query-fail" ]; then printf ';; ->>HEADER<<- status: SERVFAIL, id: 1\n'
else printf ';; ->>HEADER<<- status: NOERROR, id: 1\n'; fi
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
if [ "$1:${2:-}" = list:tables ]; then [ ! -f "$TEST_DNS_TMP/policy-running" ] || printf 'table inet routepolicy\n'; exit 0; fi
[ -f "$TEST_DNS_TMP/policy-running" ] || exit 1
if [ "$1" = -t ]; then
	printf 'table inet routepolicy {\n\tchain classify {\n\t}\n\tset domain_policy4 {\n\t}\n\tset domain_default4 {\n\t}\n\tset static_policy4 {\n\t}\n'
	[ -f "$TEST_DNS_TMP/nft-missing-set" ] || printf '\tset static_default4 {\n\t}\n'
	printf '}\n'
fi
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
printf 'default via 198.51.100.1 dev eth2 metric 10\n'
EOF
cat >"$tmp/bin/fw4" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/lib/apply" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in event|reconcile-event) exec "$TEST_DNS_REAL_APPLY" "$@" ;; esac
LIBEXEC=$ROUTEPOLICY_LIBEXEC
. "$ROUTEPOLICY_LIBEXEC/common"
rp_writer_enter apply
rp_local_lock "$RP_RUN_DIR/apply.lock" || exit 1
trap 'rp_local_unlock "$RP_RUN_DIR/apply.lock"' EXIT
if [ -f "$TEST_DNS_TMP/kill-policy" ]; then rm "$TEST_DNS_TMP/kill-policy"; kill -KILL "$$"; fi
[ ! -f "$TEST_DNS_TMP/policy-fail" ] || exit 1
if [ -f "$TEST_DNS_TMP/policy-fail-once" ] && [ "${ROUTEPOLICY_SOURCE_BOOTSTRAP:-0}" != 1 ]; then rm "$TEST_DNS_TMP/policy-fail-once"; exit 1; fi
if [ "${1:-}" = teardown ]; then
	[ "${ROUTEPOLICY_INIT_RESTORE:-0}" = 1 ] || [ "$(uci -q get routepolicy.main.enabled)" = 0 ]
	rm -f "$TEST_DNS_TMP/policy-running" "$RP_STATE_DIR/applied"
	rm -rf "$RP_ACTIVE_DIR"
	exit 0
fi
mkdir -p "$RP_ACTIVE_DIR"
: >"$RP_ACTIVE_DIR/domain-default.list"; : >"$RP_ACTIVE_DIR/domain-policy.list"
printf '%s\n' "${ROUTEPOLICY_INIT_GENERATION:-boot}" >"$RP_ACTIVE_DIR/generation"
adapter=$(rp_uci_get main smartdns_enabled 1)
if [ "$adapter" = 1 ]; then rp_render_smartdns90 "$RP_SMARTDNS_FILE"
else rm -f "$RP_SMARTDNS_FILE"; fi
[ "${ROUTEPOLICY_DNS_DEFER:-0}" = 1 ] || rp_smartdns_set_registration "$RP_SMARTDNS_FILE" "$adapter"
printf 'policy_interface=%s\npolicy_device=eth2\nroute_table=200\n' "$(uci -q get routepolicy.main.policy_interface)" >"$RP_STATE_DIR/applied"
: >"$TEST_DNS_TMP/policy-running"
[ "${ROUTEPOLICY_DNS_DEFER:-0}" = 1 ] || rp_native_service smartdns reload
if [ "${ROUTEPOLICY_SOURCE_BOOTSTRAP:-0}" = 1 ] && [ -f "$TEST_DNS_TMP/source-bootstrap-clock" ]; then
	cat "$TEST_DNS_TMP/source-bootstrap-clock" >"$ROUTEPOLICY_ROOT/proc/uptime"; rm "$TEST_DNS_TMP/source-bootstrap-clock"
fi
EOF
# FelixJI/smartdns c27671b set_main_dns; relocate its service path and tolerate absent
# options under this fixture set -e (the native script runs without errexit).
cat >"$tmp/native-main" <<'EOF'
set_main_dns()
{
	local hostip
	hostip="$(uci -q get network.lan.ipaddr)"
	dnsmasq_port="$(uci -q get dhcp.@dnsmasq[0].port || true)"
	[ -z "$dnsmasq_port" ] && dnsmasq_port="53"
	[ -z "$hostip" ] && return
	[ "$dnsmasq_port" = "53" ] && {
		uci -q set dhcp.@dnsmasq[0].port=0
		uci -q add_list dhcp.lan.dhcp_option="6,$hostip"
	}
	redir_dns="$(uci -q get dhcp.@dnsmasq[0].dns_redirect || true)"
	[ "$redir_dns" = "1" ] && {
		uci -q set dhcp.@dnsmasq[0].dns_redirect=0
		uci -q set dhcp.@dnsmasq[0].old_dns_redirect=1
	}
	uci commit dhcp
	"$ROUTEPOLICY_ROOT/etc/init.d/dnsmasq" reload
}
EOF
cat >"$tmp/root/etc/init.d/smartdns" <<'EOF'
#!/bin/sh
set -eu
service=smartdns
svc="$TEST_DNS_TMP/svc"
printf '%s %s\n' "$service" "$1" >>"$TEST_DNS_TMP/service-log"
case "$1" in
	enabled) [ "$(cat "$TEST_DNS_TMP/svc/$service.enabled")" = 1 ]; exit ;;
	enable) printf 1 >"$TEST_DNS_TMP/svc/$service.enabled"; exit ;;
	disable) printf 0 >"$TEST_DNS_TMP/svc/$service.enabled"; exit ;;
	stop) printf 0 >"$TEST_DNS_TMP/svc/$service.running"; exit ;;
	start|reload|restart) ;;
	*) exit 1 ;;
esac
if [ "$1" = reload ] && [ -f "$svc/publication-attempted" ]; then
	case "$(cat "$svc/compensation-fault")" in
		reload-error) exit 1 ;;
		reload-stale) exit 0 ;;
		reload-pending|reload-foreign|reload-partial)
			cat "$svc/compensation-fault" >"$svc/listener-fault"
			printf '%s' "$(($(cat "$svc/smartdns.pid") + 1))" >"$svc/smartdns.pid"
			exit 0 ;;
	esac
fi
if [ "$1" = restart ]; then
	. "$TEST_DNS_TMP/native-forward"
	config_get() { value=$(uci -q get "smartdns.$2.$3" || printf '%s' "${4:-}"); export "$1=$value"; }
	config_get_bool() { config_get "$@"; }
	DO_RELOAD=0; set +e; unload_service '@smartdns[0]'; set -e
fi
: >"$TEST_DNS_TMP/native-start-called"
rm -f "$TEST_DNS_TMP/svc/smartdns.absent"
enabled=$(uci -q get 'smartdns.@smartdns[0].enabled' || printf 0)
printf '%s' "$enabled" >"$TEST_DNS_TMP/svc/$service.running"
[ "$enabled" = 1 ] || exit 0
port=$(uci -q get 'smartdns.@smartdns[0].port' || printf 53)
port=${port:-53}
printf '%s' "$port" >"$TEST_DNS_TMP/svc/smartdns.port"
if [ "$port" = 53 ]; then
	. "$TEST_DNS_TMP/native-main"
	set_main_dns
fi
auto=$(uci -q get 'smartdns.@smartdns[0].auto_set_dnsmasq' || printf 1)
auto=${auto:-1}
if [ "$port" != 53 ] && [ "$auto" = 1 ]; then
	. "$TEST_DNS_TMP/native-forward"
	set +e; set_forward_dnsmasq "$port"; set -e
fi
uci set "smartdns.@smartdns[0].old_enabled=$enabled"
uci set "smartdns.@smartdns[0].old_port=$port"
uci set "smartdns.@smartdns[0].old_auto_set_dnsmasq=$auto"
uci commit smartdns
if [ "$port" = 53 ] && [ "$(cat "$TEST_DNS_TMP/svc/dnsmasq.running")" = 1 ] && [ "$(cat "$TEST_DNS_TMP/svc/dnsmasq.port")" = 53 ]; then exit 1; fi
cache=$(uci -q get 'smartdns.@smartdns[0].cache_file' || true)
if [ "$cache" = /tmp/routepolicy/smartdns.cache ]; then
	mkdir -p "$ROUTEPOLICY_ROOT/tmp/routepolicy"
	[ -e "$ROUTEPOLICY_ROOT$cache" ] || printf FRESH >"$ROUTEPOLICY_ROOT$cache"
fi
mkdir -p "$ROUTEPOLICY_ROOT/var/etc/smartdns"
{
	printf 'bind :%s@br-lan -group rp_init_default\nbind :%s@lo -group rp_init_default\n' "$port" "$port"
	printf 'bind-tcp :%s@br-lan -group rp_init_default\nbind-tcp :%s@lo -group rp_init_default\n' "$port" "$port"
	printf 'server 192.0.2.53:53 -group rp_init_default -exclude-default-group -interface eth1\nserver 198.51.100.53:53 -group rp_init_policy -exclude-default-group -interface eth2\n'
	case " $(uci -q get 'smartdns.@smartdns[0].conf_files') " in *' /etc/smartdns/conf.d/90-routepolicy.conf '*) printf "conf-file '/etc/smartdns/conf.d/90-routepolicy.conf'\n" ;; esac
	printf "conf-file '/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf'\n"
} >"$ROUTEPOLICY_ROOT/var/etc/smartdns/smartdns.conf"
# procd start/set retains the process if its tracked main config is unchanged.
generated="$ROUTEPOLICY_ROOT/var/etc/smartdns/smartdns.conf"
if [ "$1" != start ] || [ ! -f "$svc/compensation-fault" ] || ! cmp -s "$generated" "$svc/live-main"; then
	printf '%s' "$(($(cat "$svc/smartdns.pid") + 1))" >"$svc/smartdns.pid"
	if [ -f "$svc/compensation-fault" ]; then
		cp "$generated" "$svc/live-main"
		cp "$ROUTEPOLICY_ROOT/etc/smartdns/conf.d/90-routepolicy.conf" "$svc/live90"
	fi
fi
if [ -f "$TEST_DNS_TMP/source-dns-clock" ]; then
	cat "$TEST_DNS_TMP/source-dns-clock" >"$ROUTEPOLICY_ROOT/proc/uptime"; rm "$TEST_DNS_TMP/source-dns-clock"
fi
EOF
cat >"$tmp/root/etc/init.d/dnsmasq" <<'EOF'
#!/bin/sh
set -eu
printf 'dnsmasq %s\n' "$1" >>"$TEST_DNS_TMP/service-log"
case "$1" in
	enabled) [ "$(cat "$TEST_DNS_TMP/svc/dnsmasq.enabled")" = 1 ] ;;
	enable) printf 1 >"$TEST_DNS_TMP/svc/dnsmasq.enabled" ;;
	disable) printf 0 >"$TEST_DNS_TMP/svc/dnsmasq.enabled" ;;
	stop) printf 0 >"$TEST_DNS_TMP/svc/dnsmasq.running" ;;
	start|restart|reload)
		# Native per-instance early return; rc disabled does not block reload_service.
		case "$(uci -q get 'dhcp.@dnsmasq[0].disabled' || true)" in
			1|on|true|yes|enabled) printf 0 >"$TEST_DNS_TMP/svc/dnsmasq.running"; exit 0 ;;
		esac
		printf 1 >"$TEST_DNS_TMP/svc/dnsmasq.running"
		[ ! -f "$TEST_DNS_TMP/stale-dnsmasq" ] || exit 0
		uci -q get 'dhcp.@dnsmasq[0].port' >"$TEST_DNS_TMP/svc/dnsmasq.port" ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/root/etc/init.d/routepolicy" <<'EOF'
#!/bin/sh
set -eu
printf 'routepolicy %s\n' "$*" >>"$TEST_DNS_TMP/service-log"
case "$1" in
	enabled) [ "$(cat "$TEST_DNS_TMP/svc/routepolicy.enabled")" = 1 ]; exit ;;
	enable) printf 1 >"$TEST_DNS_TMP/svc/routepolicy.enabled"; exit ;;
	disable) printf 0 >"$TEST_DNS_TMP/svc/routepolicy.enabled"; exit ;;
	start) shift ;;
	*) exit 1 ;;
esac
[ ! -f "$TEST_DNS_TMP/watch-fail" ] || exit 1
ROUTEPOLICY_INIT_TRANSACTION="$ROUTEPOLICY_LIBEXEC/init-transaction"
. "$TEST_DNS_REAL_INIT"
config_load() { :; }
config_get_bool() { enabled=$(uci -q get routepolicy.main.enabled); }
procd_open_instance() { :; }
procd_set_param() { printf '%s\n' "$*" >>"$TEST_DNS_TMP/watch-registration"; }
procd_close_instance() { printf 1 >"$TEST_DNS_TMP/svc/routepolicy.running"; }
start_service "$@"
EOF
for service in network firewall odhcpd routepolicy-initguard routepolicy-prerecover; do printf '#!/bin/sh\nexit 0\n' >"$tmp/root/etc/init.d/$service"; done
cat >"$tmp/root/etc/init.d/network" <<'EOF'
#!/bin/sh
if [ "$(cat "$TEST_DNS_TMP/svc/dnsmasq.running")" = 1 ]; then uci -q get 'dhcp.@dnsmasq[0].port' >"$TEST_DNS_TMP/svc/dnsmasq.port"; fi
EOF
cp "$tmp/root/etc/init.d/network" "$tmp/root/usr/sbin/smartdns"
chmod +x "$tmp/bin/"* "$tmp/lib/"* "$tmp/root/etc/init.d/"* "$tmp/root/usr/sbin/smartdns"
export PATH="$tmp/bin:$PATH"
[ "$(init_dns_service_state routepolicy-initguard)" = 1 ]
TX="$tmp/lib/init-transaction"
canonical() {
	exported=$(native-uci -c "$tmp/root/etc/config" export "$1") || return 1
	printf '%s\n' "$exported" | awk '
		$1=="config"{section=$0;print "section " section;next}
		NF{key=section " " $1 " " $2;print key " " ($1=="list"?++sequence[key]:0) " " $0}' >"$tmp/canonical" || return 1
	LC_ALL=C sort "$tmp/canonical"
}
baseline() {
	rm -rf "$tmp/root/etc/routepolicy" "$tmp/root/tmp/routepolicy" "$tmp/root/etc/smartdns" "$tmp/root/var" "$tmp/svc" "$tmp/external"
	rm -f "$tmp/policy-running" "$tmp/query-fail" "$tmp/policy-fail" "$tmp/kill-stage" "$tmp/queries" "$tmp/service-log" "$tmp/list-fail" "$tmp/delete-fail" "$tmp/delete-race" "$tmp/quiesce-fault" "$tmp/native-start-called" "$tmp/stale-dnsmasq" "$tmp/kill-confirm" "$tmp/kill-policy" "$tmp/watch-fail" "$tmp/watch-registration"
	mkdir -p "$tmp/svc" "$tmp/external" "$tmp/root/etc/smartdns/conf.d" "$tmp/root/proc/sys/kernel/random"
	mkdir -p "$tmp/root/tmp/resolv.conf.d"
	rm -f "$tmp/root/etc/resolv.conf" "$tmp/root/tmp/resolv.conf" "$tmp/root/tmp/resolv.conf.d/routepolicy.conf"
	ln -s /tmp/resolv.conf "$tmp/root/etc/resolv.conf"
	ln -s /tmp/resolv.conf.d/resolv.conf.auto "$tmp/root/tmp/resolv.conf"
	printf 'nameserver 192.0.2.53\n' >"$tmp/root/tmp/resolv.conf.d/resolv.conf.auto"
	printf '100.00 0.00\n' >"$tmp/root/proc/uptime"
	printf '00000000-0000-4000-8000-000000000001\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
	printf "config interface 'lan'\n\toption proto 'static'\n\toption ipaddr '192.0.2.1'\n\tlist ip6addr '2001:db8::1/64'\nconfig interface 'wan'\n\toption proto 'dhcp'\nconfig interface 'wan2'\n\toption proto 'dhcp'\n" >"$tmp/root/etc/config/network"
	printf "config dnsmasq\n\toption port '53'\n\tlist server '192.0.2.99'\n\tlist server '/local/192.0.2.98'\n\toption unknown 'keep'\nconfig dhcp 'lan'\n\toption interface 'lan'\n" >"$tmp/root/etc/config/dhcp"
	printf "config smartdns\n\toption enabled '1'\n\toption port '6053'\n\toption cache_persist '1'\n\toption cache_file '/etc/smartdns/user.cache'\n\toption auto_set_dnsmasq '0'\n\toption old_port '6053'\n\toption old_enabled '1'\n\toption old_auto_set_dnsmasq '0'\n\tlist conf_files '/etc/smartdns/custom-a.conf'\n\tlist conf_files '/etc/smartdns/custom-b.conf'\n\toption unknown 'keep'\nconfig server 'user'\n\toption ip '192.0.2.88'\n" >"$tmp/root/etc/config/smartdns"
	printf "config main 'main'\n\toption enabled '0'\n\toption lan_interface 'lan'\n\toption default_interface 'wan'\n\toption policy_interface 'wan2'\n\toption route_table '200'\n" >"$tmp/root/etc/config/routepolicy"
	printf '# untouched\n' >"$tmp/root/etc/config/firewall"
	printf USER-CACHE >"$tmp/root/etc/smartdns/user.cache"
	for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.before"; done
	printf 0 >"$tmp/svc/routepolicy.enabled"; printf 0 >"$tmp/svc/routepolicy.running"
	printf '%s' "$1" >"$tmp/svc/smartdns.enabled"; printf '%s' "$2" >"$tmp/svc/smartdns.running"
	printf 100 >"$tmp/svc/smartdns.pid"
	printf '%s' "$3" >"$tmp/svc/dnsmasq.enabled"; printf '%s' "$4" >"$tmp/svc/dnsmasq.running"
	printf 6053 >"$tmp/svc/smartdns.port"; printf 53 >"$tmp/svc/dnsmasq.port"
}
prepare() {
	output=$("$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53)
	token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	[ "${#token}" = 32 ]
}
restored() {
	for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.after"; cmp "$tmp/$package.before" "$tmp/$package.after" || { diff -u "$tmp/$package.before" "$tmp/$package.after"; return 1; }; done
	[ ! -e "$tmp/root/etc/smartdns/conf.d/90-routepolicy.conf" ]
	[ ! -e "$tmp/root/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf" ]
	[ ! -e "$tmp/policy-running" ]
	[ "$(cat "$tmp/root/etc/smartdns/user.cache")" = USER-CACHE ]
	[ "$(cat "$tmp/svc/routepolicy.enabled")" = 0 ]
}
prepare_dns() {
	output=$("$TX" prepare lan wan wan2 - - - - - - - - "$1" 198.51.100.53)
	token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	[ "${#token}" = 32 ]
}
confirm_dns() {
	"$TX" apply "$token" >/dev/null
	if ! SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >"$tmp/confirm-result"; then cat "$tmp/confirm-result" >&2; return 1; fi
}
test_boot() {
	test_boot_sequence=$(( ${test_boot_sequence:-10} + 1 ))
	printf '00000000-0000-4000-8000-%012d\n' "$test_boot_sequence" >"$tmp/root/proc/sys/kernel/random/boot_id"
	rm -f "$RP_RESOLVER_ENTRY" "$RP_RESOLVER_FILE"
	ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
}
if [ "${1:-}" = --boot-watch ]; then
	: "${TEST_UCI_SDK_ROOT:?provide the official OpenWrt rootfs for rc.common}"
	boot_case=${2:-all}
	case "$boot_case" in all|current|coordinated) ;; *) exit 1 ;; esac
	n=$TEST_UCI_SDK_ROOT; rc_root="$tmp/rc-root"
	mkdir -p "$rc_root/lib/functions" "$rc_root/usr/share/libubox" "$rc_root/var/lock" "$rc_root/etc/rc.d"
	cp "$n/lib/functions/procd.sh" "$rc_root/lib/functions/procd.sh"
	cp "$n/usr/share/libubox/jshn.sh" "$rc_root/usr/share/libubox/jshn.sh"
	cat >"$rc_root/lib/functions.sh" <<'SH'
list_contains() { eval "case \" \$$1 \" in *\" $2 \"*) return 0 ;; *) return 1 ;; esac"; }
config_load() { :; }
config_get_bool() { [ "$1" = enabled ] && enabled=$(uci -q get routepolicy.main.enabled); }
SH
	: >"$rc_root/lib/functions/service.sh"
	cat >"$tmp/bin/jshn" <<'SH'
#!/bin/sh
exec "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/usr/bin/jshn" "$@"
SH
	chmod +x "$tmp/bin/jshn"
	native_rc() {
		IPKG_INSTROOT="$rc_root" timeout -k 2 12 "$n/lib/ld-musl-x86_64.so.1" --library-path "$n/lib:$n/usr/lib" \
			"$n/bin/busybox" ash "$n/etc/rc.common" "$@"
	}
	baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
	txroot="$RP_STATE_DIR/init-transaction"; active=$(rp_init_active_record)
	quarantine_boot() {
		rm -rf "$RP_RUN_DIR"; rm -f "$tmp/policy-running"; test_boot
		printf 0 >"$tmp/svc/smartdns.running"
		ROUTEPOLICY_INIT_TRANSACTION="$TX" native_rc "$ROOT/routepolicy/files/etc/init.d/routepolicy-prerecover" boot
		[ -f "$active/dns-boot-pending" ]
	}
	quarantine_boot
	"$TX" boot-dns >/dev/null
	boot_now=$(cat "$RP_ROOT/proc/sys/kernel/random/boot_id")
	[ "$(cat "$active/dns-boot-ready")" = "$boot_now" ] && [ "$(cat "$active/boot-id")" != "$boot_now" ] || exit 1
	[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")" = 11 ] && [ -f "$tmp/policy-running" ] || exit 1
	receipt="$RP_STATE_DIR/applied"
	printf 'schema=1\nboot_id=%s\nsource_bootstrap=0\nmark=0x100\nmark_mask=0x100\n' "$boot_now" >>"$receipt"
	uci set routepolicy.main.mark=0x200; uci set routepolicy.main.mark_mask=0x200; uci commit routepolicy
	ready="$active/dns-boot-ready"
	mv "$tmp/bin/ubus" "$tmp/bin/boot-fixture-ubus"
	cat >"$tmp/bin/ubus" <<'SH'
#!/bin/sh
case "$1:${2:-}:${3:-}:${4:-}" in
	call:service:set:*|call:service:add:*)
		if [ "${TEST_BOOT_RACE:-0}" = 1 ]; then
			pid=$(cat "$TEST_DNS_TMP/boot-rc-pid") || exit 91
			readlink "/proc/$pid/fd/1000" >"$TEST_DNS_TMP/boot-procd-lock" || exit 91
			if "$TEST_BOOT_FLOCK" -n "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/lock" true; then exit 92; fi
		fi
		printf '%s\n' "$4" >>"$TEST_DNS_TMP/boot-procd"; exit 0 ;;
	call:service:delete:*'"routepolicy"'*) exit 0 ;;
esac
exec "$TEST_DNS_TMP/bin/boot-fixture-ubus" "$@"
SH
	cat >"$tmp/bin/boot-transaction" <<'SH'
#!/bin/sh
rc=0
if [ "$1" = recover-startup ]; then printf '%s\n' "$PPID" >"$TEST_DNS_TMP/boot-rc-pid"; fi
if [ "$1:${2:-}" != recover-startup:boot ]; then
	"$TEST_BOOT_TX" "$@" || rc=$?
	printf '%s %s\n' "$1" "$rc" >>"$TEST_DNS_TMP/boot-tx-trace"
	exit "$rc"
fi
"$TEST_BOOT_TX" "$@" >"$TEST_DNS_TMP/boot-recovery-result" || rc=$?
printf '%s %s\n' "$1" "$rc" >>"$TEST_DNS_TMP/boot-tx-trace"
if [ "$rc" = 0 ] && [ -n "${TEST_BOOT_COORDINATE:-}" ]; then
	dns_rc=0
	"$TEST_BOOT_TX" boot-dns >"$TEST_DNS_TMP/boot-dns.stdout" 2>"$TEST_DNS_TMP/boot-dns.stderr" || dns_rc=$?
	printf '%s\n' "$dns_rc" >"$TEST_DNS_TMP/boot-dns.rc"
fi
if [ "$rc:${TEST_BOOT_RACE:-0}" = 0:1 ]; then
	printf 'window\n' >"$TEST_DNS_TMP/boot-lock-window"
	remaining=500
	while [ ! -s "$TEST_DNS_TMP/boot-lock-held" ]; do
		[ "$remaining" -gt 0 ] || exit 92
		remaining=$((remaining - 1)); sleep 0.01
	done
fi
cat "$TEST_DNS_TMP/boot-recovery-result"
exit "$rc"
SH
	TEST_BOOT_FLOCK=$(command -v flock); export TEST_BOOT_FLOCK
	cat >"$tmp/bin/flock" <<'SH'
#!/bin/sh
if [ "$1:${2:-}:${3:-}:${TEST_BOOT_RACE:-0}" = -w:180:9:1 ]; then
	pid=$(cat "$TEST_DNS_TMP/boot-rc-pid") || exit 93
	[ ! -e "/proc/$pid/fd/1000" ] || exit 94
	if "$TEST_BOOT_FLOCK" -n 9; then exit 95; fi
	printf 'waiting before procd\n' >"$TEST_DNS_TMP/boot-recovery-wait"
fi
exec "$TEST_BOOT_FLOCK" "$@"
SH
	mv "$tmp/lib/apply" "$tmp/lib/boot-fixture-apply"
	cat >"$tmp/lib/apply" <<'SH'
#!/bin/sh
set -eu
. "$ROUTEPOLICY_LIBEXEC/common"
mark=$(uci -q get routepolicy.main.mark); mask=$(uci -q get routepolicy.main.mark_mask)
if rp_writer_owned; then
	case "$ROUTEPOLICY_WRITER_KIND" in
		apply)
			[ "$ROUTEPOLICY_DNS_DEFER:$ROUTEPOLICY_INIT_RESTORE:${ROUTEPOLICY_INIT_GENERATION:-}:$ROUTEPOLICY_SOURCE_BOOTSTRAP:$ROUTEPOLICY_DECLARATION_OWNER" = 0:0::0:0 ]
			pid=$(cat "$TEST_DNS_TMP/boot-rc-pid")
			[ ! -e "/proc/$pid/fd/1000" ]
			printf 'startup apply %s %s\n' "$mark" "$mask" >>"$TEST_DNS_TMP/boot-inner-apply" ;;
		init) [ "$ROUTEPOLICY_DNS_DEFER" = 1 ]; printf 'coordinator apply\n' >>"$TEST_DNS_TMP/boot-coordinator-apply" ;;
		*) exit 1 ;;
	esac
fi
if "$ROUTEPOLICY_LIBEXEC/boot-fixture-apply" "$@"; then
	printf 'mark=%s\nmark_mask=%s\n' "$mark" "$mask" >>"$RP_STATE_DIR/applied"
else
	printf 'boot-policy-applied\n'
	exit 1
fi
SH
	cat >"$tmp/bin/boot-ctl" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >>"$TEST_DNS_TMP/boot-apply"
exec "$TEST_BOOT_CTL" "$@"
SH
	chmod +x "$tmp/bin/ubus" "$tmp/bin/boot-transaction" "$tmp/bin/boot-ctl" "$tmp/bin/flock" "$tmp/lib/apply"
	export TEST_BOOT_TX="$TX" TEST_BOOT_CTL="$ROOT/routepolicy/files/usr/sbin/routepolicyctl"
	export ROUTEPOLICY_INIT_TRANSACTION="$tmp/bin/boot-transaction" ROUTEPOLICY_CTL="$tmp/bin/boot-ctl"
	export ROUTEPOLICY_WATCH="$tmp/watch" ROUTEPOLICY_APPLY=true
	ln -s "$TEST_DNS_REAL_INIT" "$rc_root/etc/rc.d/S95routepolicy"
	check_watcher() {
		[ "$(jsonfilter -i "$tmp/boot-procd" -e '@.instances.*.command[0]' | grep -Fxc "$tmp/watch")" = 1 ] || {
			cat "$tmp/boot-recovery-result" "$tmp/boot-tx-trace" "$tmp/boot-procd"
			printf '%s\n' 'expected exactly one watcher' >&2; return 1;
		}
	}
	run_boot_entry() {
		: >"$tmp/boot-procd"; : >"$tmp/boot-apply"; : >"$tmp/boot-tx-trace"; : >"$tmp/boot-inner-apply"
		: >"$tmp/boot-coordinator-apply"
		native_rc "$1" "$2" >"$tmp/boot-$2.stdout" 2>"$tmp/boot-$2.stderr"
	}
	wait_marker() {
		remaining=500
		while [ ! -s "$1" ]; do
			[ "$remaining" -gt 0 ] || return 1
			remaining=$((remaining - 1)); sleep 0.01
		done
	}
	boot_link="$rc_root/etc/rc.d/S95routepolicy"
	run_contended_boot() {
		for marker in before-held recovery-wait lock-window lock-held lock-release procd-lock; do rm -f "$tmp/boot-$marker"; done
		(
			exec 9>"$txroot/lock"; flock -n 9
			printf 'held\n' >"$tmp/boot-before-held"
			wait_marker "$tmp/boot-recovery-wait"; flock -u 9
			wait_marker "$tmp/boot-lock-window"; flock -n 9
			printf 'held\n' >"$tmp/boot-lock-held"
			wait_marker "$tmp/boot-lock-release"
		) & guard_pid=$!
		wait_marker "$tmp/boot-before-held"
		TEST_BOOT_RACE=1 TEST_BOOT_COORDINATE="$1" run_boot_entry "$boot_link" boot
		printf 'release\n' >"$tmp/boot-lock-release"; wait "$guard_pid"; guard_pid=
		grep -Fxq 'recover-startup 0' "$tmp/boot-tx-trace"
		[ -s "$tmp/boot-recovery-wait" ] && [ -s "$tmp/boot-procd-lock" ] && [ -s "$tmp/boot-lock-held" ] || exit 1
	}
	if [ "$boot_case" != coordinated ]; then
		# active_publish clears this leftover copy while holding FD9. The archive is already ready.
		cp "$ready" "$txroot/current/dns-boot-pending"
		run_contended_boot ''
		[ ! -e "$txroot/current/dns-boot-pending" ]
		check_watcher
		[ "$(cat "$tmp/boot-recovery-result")" = boot-policy-applied ] &&
			[ "$(cat "$tmp/boot-inner-apply")" = 'startup apply 0x200 0x200' ] || exit 1
		grep -Fxq 'mark=0x200' "$receipt" && grep -Fxq 'mark_mask=0x200' "$receipt" && [ ! -s "$tmp/boot-apply" ] || exit 1
		printf '%s\n' 'cold boot: current pending cleared, committed mark/mask applied under FD9, later FD9 owner did not prevent one watcher'
		[ "$boot_case" != current ] || exit 0
	fi
	quarantine_boot
	run_contended_boot complete
	[ "$(cat "$tmp/boot-dns.rc")" = 0 ] && [ ! -e "$active/dns-boot-pending" ] || exit 1
	cmp "$ready" "$RP_ROOT/proc/sys/kernel/random/boot_id"
	check_watcher
	[ "$(cat "$tmp/boot-recovery-result")" = boot-policy-coordinated ] && [ ! -s "$tmp/boot-inner-apply" ] &&
		[ ! -s "$tmp/boot-apply" ] && [ "$(cat "$tmp/boot-coordinator-apply")" = 'coordinator apply' ] || exit 1
	printf '%s\n' 'cold boot: coordinator completed after recovery, later FD9 owner did not cause apply or prevent one watcher'
	[ "$boot_case" != coordinated ] || exit 0
	quarantine_boot
	: >"$tmp/policy-fail"
	TEST_BOOT_COORDINATE=fail run_boot_entry "$boot_link" boot
	check_watcher
	[ "$(cat "$tmp/boot-recovery-result")" = boot-policy-coordinated ] && [ "$(cat "$tmp/boot-dns.rc")" != 0 ] &&
		[ -f "$active/dns-boot-pending" ] && [ ! -f "$tmp/policy-running" ] &&
		[ ! -s "$tmp/boot-apply" ] && [ ! -s "$tmp/boot-inner-apply" ] &&
		[ "$(cat "$tmp/boot-coordinator-apply")" = 'coordinator apply' ] || exit 1
	grep -Fq '启动策略/DNS 验证失败' "$tmp/boot-dns.stderr"
	if cmp -s "$ready" "$RP_ROOT/proc/sys/kernel/random/boot_id"; then exit 1; fi
	printf '%s\n' 'cold boot: failed coordinator kept pending and registered only the watcher'
	rm "$tmp/policy-fail"; "$TX" boot-dns >/dev/null
	cp "$ready" "$tmp/boot-ready"; cp "$active/boot-id" "$tmp/old-boot"
	: >"$tmp/policy-fail"
	if run_boot_entry "$rc_root/etc/rc.d/S95routepolicy" boot; then printf '%s\n' 'failed boot apply returned success' >&2; exit 1; fi
	[ -s "$tmp/boot-inner-apply" ] && [ ! -s "$tmp/boot-procd" ] && [ ! -s "$tmp/boot-apply" ] || exit 1
	grep -Fq '启动策略应用失败' "$tmp/boot-boot.stderr"
	rm "$tmp/policy-fail"
	for action in start restart; do
		run_boot_entry "$TEST_DNS_REAL_INIT" "$action"
		[ "$(cat "$tmp/boot-apply")" = apply ] && [ ! -s "$tmp/boot-inner-apply" ] || exit 1
		check_watcher
	done
	if "$TX" recover-startup boot extra >/dev/null || "$TX" recover-startup invalid >/dev/null || "$TX" recover boot >/dev/null; then exit 1; fi
	for edge in missing-ready old-ready malformed-ready ready-link pending-link same-boot disabled legacy; do
		expected_boot_result=boot-policy-deferred
		case "$edge" in
			missing-ready) rm "$ready" ;;
			old-ready) cp "$tmp/old-boot" "$ready" ;;
			malformed-ready) printf '\n' >>"$ready" ;;
			ready-link) rm "$ready"; ln -s "$tmp/boot-ready" "$ready" ;;
			pending-link) ln -s "$tmp/absent" "$active/dns-boot-pending" ;;
			same-boot) cp "$tmp/boot-ready" "$active/boot-id" ;;
			disabled) uci set routepolicy.main.enabled=0; uci commit routepolicy ;;
			legacy) mv "$txroot" "$tmp/boot-saved-tx" ;;
		esac
		case "$edge" in missing-ready|old-ready|malformed-ready|ready-link) expected_boot_result=boot-policy-coordinated ;; esac
		: >"$tmp/boot-inner-apply"
		[ "$("$TX" recover-startup boot)" = "$expected_boot_result" ] && [ ! -s "$tmp/boot-inner-apply" ] || {
			printf 'unexpected pre-procd apply: %s\n' "$edge" >&2; exit 1;
		}
		if [ "$expected_boot_result" = boot-policy-coordinated ]; then
			[ -f "$active/dns-boot-pending" ] && [ ! -L "$active/dns-boot-pending" ]
		fi
		case "$edge" in
			disabled) run_boot_entry "$rc_root/etc/rc.d/S95routepolicy" boot
				[ ! -s "$tmp/boot-apply" ] && [ ! -s "$tmp/boot-inner-apply" ] || exit 1
				if jsonfilter -i "$tmp/boot-procd" -e '@.instances.*.command[0]' | grep -Fxq "$tmp/watch"; then exit 1; fi
				uci set routepolicy.main.enabled=1; uci commit routepolicy ;;
			legacy) boot_policy_result=boot-policy-applied run_boot_entry "$rc_root/etc/rc.d/S95routepolicy" boot
				[ "$(cat "$tmp/boot-apply")" = apply ]; check_watcher; break ;;
		esac
		rm -f "$ready" "$active/dns-boot-pending" "$txroot/current/dns-boot-pending"
		cp "$tmp/boot-ready" "$ready"; cp "$tmp/old-boot" "$active/boot-id"
	done
	printf '%s\n' 'cold boot watcher: failed apply, ordinary start/restart, legacy fallback and invalid boot evidence passed'
	exit 0
fi
if [ "${1:-}" = --prerecover-upgrade ]; then
	: "${TEST_UCI_SDK_ROOT:?provide the official OpenWrt rootfs for rc.common}"
	prerecover_entry() {
		IPKG_INSTROOT="$tmp/rc-root" ROUTEPOLICY_INIT_TRANSACTION="$TX" \
			"$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" \
			"$TEST_UCI_SDK_ROOT/bin/busybox" ash "$TEST_UCI_SDK_ROOT/etc/rc.common" \
			"$ROOT/routepolicy/files/etc/init.d/routepolicy-prerecover" "$1"
	}
	post_upgrade_start() { PKG_UPGRADE=1 APK_SCRIPT=post-upgrade prerecover_entry start; }
	assert_dns_online() {
		[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")" = 11 ] || {
			printf '%s\n' 'post-upgrade start disabled or stopped confirmed SmartDNS' >&2; return 1;
		}
		[ "$(cat "$tmp/svc/dnsmasq.enabled")$(cat "$tmp/svc/dnsmasq.running")" = 00 ]
	}
	mkdir -p "$tmp/rc-root/lib/functions"
	cp "$TEST_UCI_SDK_ROOT/lib/functions.sh" "$tmp/rc-root/lib/"
	cp "$TEST_UCI_SDK_ROOT/lib/functions/service.sh" "$tmp/rc-root/lib/functions/"
	txdir="$RP_STATE_DIR/init-transaction"
	current="$txdir/current"
	baseline 0 0 1 1
	post_upgrade_start
	[ ! -e "$txdir" ] && [ ! -e "$tmp/service-log" ] && restored
	prepare; confirm_dns
	active=$(rp_init_active_record)
	assert_dns_online
	cp "$tmp/service-log" "$tmp/post-upgrade-before"
	post_upgrade_start
	assert_dns_online
	[ ! -e "$current/dns-boot-quarantined" ] && [ ! -e "$active/dns-boot-pending" ]
	cmp "$tmp/service-log" "$tmp/post-upgrade-before"

	# Cold boot still removes the S19 links and S94 restores verified native DNS.
	rm -rf "$RP_RUN_DIR"; rm -f "$tmp/policy-running"
	test_boot
	printf 0 >"$tmp/svc/smartdns.running"
	prerecover_entry boot
	[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
	[ -f "$current/dns-boot-quarantined" ] && [ -f "$active/dns-boot-pending" ]
	"$TX" boot-dns >/dev/null
	assert_dns_online
	boot_now=$(cat "$RP_ROOT/proc/sys/kernel/random/boot_id")
	[ "$(cat "$current/boot-id")" != "$boot_now" ]
	[ "$(cat "$active/dns-boot-ready")" = "$boot_now" ] && [ ! -e "$active/dns-boot-pending" ]
	cp "$tmp/service-log" "$tmp/post-upgrade-before"
	post_upgrade_start
	assert_dns_online
	cmp "$tmp/service-log" "$tmp/post-upgrade-before"

	# A repair intent can coexist with a previous ready marker until it converges.
	printf '%s\n' "$boot_now" >"$active/dns-boot-pending"
	post_upgrade_start
	[ "$(cat "$tmp/svc/smartdns.enabled")" = 0 ] && [ -f "$active/dns-boot-pending" ]
	"$TX" boot-dns >/dev/null
	assert_dns_online
	printf '%s\n\n' "$boot_now" >"$active/dns-boot-ready"
	post_upgrade_start
	[ "$(cat "$tmp/svc/smartdns.enabled")" = 0 ] && [ -f "$active/dns-boot-pending" ]
	"$TX" boot-dns >/dev/null
	assert_dns_online
	# Matching bytes in a symlink cannot stand in for verified boot readiness.
	mv "$active/dns-boot-ready" "$tmp/boot-ready-record"
	ln -s "$tmp/boot-ready-record" "$active/dns-boot-ready"
	post_upgrade_start
	[ "$(cat "$tmp/svc/smartdns.enabled")" = 0 ] && [ -f "$active/dns-boot-pending" ]

	for point in intent pointer; do
		baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
		printf '%s\n' "$point" >"$tmp/kill-confirm"
		if SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >"$tmp/upgrade-killed" 2>&1; then exit 1; fi
		[ "$(cat "$current/phase")" = confirming ]
		post_upgrade_start
		[ "$(cat "$current/phase")" = confirmed ] && [ "$(cat "$txdir/active")" = "$token" ]
		assert_dns_online
		[ ! -e "$current/dns-boot-quarantined" ]
	done

	baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
	post_upgrade_start
	[ "$(cat "$current/phase")" = pending ] && assert_dns_online
	printf 'conflict\n' >"$current/phase"
	if post_upgrade_start; then printf '%s\n' 'post-upgrade start hid a recovery conflict' >&2; exit 1; fi
	[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
	# A router affected before upgrading uses the existing explicit repair command.
	baseline 0 0 1 1; prepare; confirm_dns
	"$tmp/root/etc/init.d/smartdns" disable
	: >"$current/dns-boot-quarantined"
	post_upgrade_start
	[ "$(cat "$tmp/svc/smartdns.enabled")" = 0 ]
	"$TX" repair >/dev/null
	assert_dns_online
	[ -f "$current/dns-boot-quarantined" ]
	printf '%s\n' 'native prerecover upgrade: fresh, confirmed, recovered boot, pending repair, invalid ready marker, confirmation interruption, conflict and explicit repair passed'
	exit 0
fi
managed_apply_dns() {
	cp "$REAL_LIB/smartdns-control" "$tmp/lib/"
	# The policy service fixture supplies the same typed content receipt as real apply.
	{
		printf 'schema=1\nboot_id=%s\ninit_generation=\nsource_bootstrap=0\n' "$(cat "$tmp/root/proc/sys/kernel/random/boot_id")"
		printf 'route_table=200\nrule_priority=12000\nmark=0x100\nmark_mask=0x100\npolicy_interface=%s\npolicy_device=eth2\n' "$(uci -q get routepolicy.main.policy_interface)"
		printf 'smartdns90_present=1\n'
		sed 's/^/smartdns90:/' "$RP_SMARTDNS_FILE"
	} >"$RP_STATE_DIR/applied"
	"$tmp/lib/smartdns-control" status >"$tmp/managed-status"
	managed_version=$(jsonfilter -i "$tmp/managed-status" -e '@.version')
	printf 'version\t%s\ninitialize\t0\n' "$managed_version" | "$tmp/lib/smartdns-control" save >/dev/null
	printf '203.0.114.30 firmware-local.lab19.test\n' | "$tmp/lib/smartdns-control" write-local-hosts >/dev/null
}
if [ "${1:-}" = --exit-managed ]; then
	TEST_MANAGED_GREP=$(command -v grep); export TEST_MANAGED_GREP
	cat >"$tmp/bin/grep" <<'SH'
#!/bin/sh
if [ "$1" = -Fq ] && [ "${2:-}" = '\' ] && [ -f "$TEST_DNS_TMP/fail-proof-read" ]; then exit 2; fi
exec "$TEST_MANAGED_GREP" "$@"
SH
	chmod +x "$tmp/bin/grep"
	TEST_MANAGED_MV=$(command -v mv); export TEST_MANAGED_MV
	cat >"$tmp/bin/mv" <<'SH'
#!/bin/sh
for target do :; done
if [ "$target" = "$ROUTEPOLICY_ROOT/etc/routepolicy/state/applied" ] && [ -f "$TEST_DNS_TMP/fail-managed-receipt" ]; then
	if [ -f "$TEST_DNS_TMP/svc/compensation-fault" ]; then
		cp "$TEST_DNS_TMP/svc/live90" "$TEST_DNS_TMP/svc/publication-attempted"
		cp "$TEST_DNS_TMP/svc/live-main" "$TEST_DNS_TMP/svc/publication-main"
	fi
	rm "$TEST_DNS_TMP/fail-managed-receipt"; exit 1
fi
if [ "$target" = "$ROUTEPOLICY_ROOT/etc/routepolicy/state/applied" ] && [ -f "$TEST_DNS_TMP/fail-managed-restore" ] &&
	grep -Fq 'smartdns90:address /firmware-local.lab19.test/' "$target"; then
	rm "$TEST_DNS_TMP/fail-managed-restore"; exit 1
fi
"$TEST_MANAGED_MV" "$@" || exit $?
if [ "$target" = "$ROUTEPOLICY_ROOT/etc/smartdns/conf.d/90-routepolicy.conf" ] && [ -f "$TEST_DNS_TMP/kill-managed-file" ]; then
	rm "$TEST_DNS_TMP/kill-managed-file"; kill -KILL "$PPID"
fi
SH
	chmod +x "$tmp/bin/mv"
	for managed_case in immediate legacy-shape publish-fail reload-error reload-stale reload-pending reload-foreign reload-partial publish-stopped publish-sync rollback-fail receipt-conflict file-conflict interrupted preboot preforeign premissing preoversize external77 oldboot duplicate badtuple bootstrap foreign90 real91 continuation proof-read-error; do
		baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
		active=$(rp_init_active_record)
		cp -R "$active/origin" "$tmp/managed-origin-$managed_case"
		managed_apply_dns
		cp "$RP_STATE_DIR/applied" "$tmp/managed-receipt.before"
		cp "$RP_SMARTDNS_FILE" "$tmp/managed90.before"
		case "$managed_case" in
			publish-fail|reload-*|publish-stopped)
				printf '%s\n' "$managed_case" >"$tmp/svc/compensation-fault"
				: >"$tmp/fail-managed-receipt"
				cp "$RP_SMARTDNS_GENERATED" "$tmp/managed-main.before"
				cp "$tmp/managed-main.before" "$tmp/svc/live-main"
				cp "$tmp/managed90.before" "$tmp/svc/live90"
				if [ "$managed_case" = publish-stopped ]; then
					"$tmp/root/etc/init.d/smartdns" stop
					rm -f "$tmp/svc/live-main"
				fi ;;
			publish-sync) : >"$tmp/fail-managed-sync" ;;
			rollback-fail) : >"$tmp/fail-managed-sync"; : >"$tmp/fail-managed-restore" ;;
			receipt-conflict) : >"$tmp/change-managed-receipt" ;;
			file-conflict) : >"$tmp/change-managed-file" ;;
			interrupted) : >"$tmp/kill-managed-file" ;;
			preboot) sed 's/^boot_id=.*/boot_id=00000000-0000-4000-8000-000000000099/' "$RP_STATE_DIR/applied" >"$tmp/corrupt"; cp "$tmp/corrupt" "$RP_STATE_DIR/applied" ;;
			preforeign) printf 'address /foreign.test/203.0.114.99\n' >>"$RP_SMARTDNS_FILE" ;;
			premissing) rm "$RP_STATE_DIR/applied" ;;
			preoversize) dd if=/dev/zero bs=2097153 count=1 >"$RP_STATE_DIR/applied" 2>/dev/null ;;
		esac
		case "$managed_case" in publish-fail|reload-*|publish-stopped)
			if "$tmp/lib/smartdns-control" apply >"$tmp/managed-failed" 2>&1; then printf 'receipt failure succeeded\n' >&2; exit 1; fi
			cmp "$RP_STATE_DIR/applied" "$tmp/managed-receipt.before"
			cmp "$RP_SMARTDNS_FILE" "$tmp/managed90.before"
			cmp "$RP_SMARTDNS_GENERATED" "$tmp/managed-main.before"
			cmp "$tmp/svc/publication-main" "$tmp/managed-main.before"
			grep -Fxq 'address /firmware-local.lab19.test/203.0.114.30' "$tmp/svc/publication-attempted"
			[ -f "$RP_SMARTDNS_CANDIDATE" ] && [ -f "$RP_LOCAL_HOSTS_CANDIDATE" ]
			case "$managed_case" in
				publish-fail)
					cmp "$tmp/svc/live90" "$tmp/managed90.before" || { printf '运行中的 SmartDNS 仍使用候选片段\n' >&2; exit 1; }
					grep -Fq '已恢复应用前配置' "$tmp/managed-failed"
					"$TX" exit-preview >/dev/null ;;
				publish-stopped)
					[ "$(cat "$tmp/svc/smartdns.running")" = 0 ]
					grep -Fq '已恢复应用前配置' "$tmp/managed-failed" ;;
				*)
					cmp "$tmp/svc/live90" "$tmp/svc/publication-attempted"
					grep -Fq '补偿未完整完成' "$tmp/managed-failed"
					! grep -Fq '已恢复应用前配置' "$tmp/managed-failed" ;;
			esac
			diff -r "$active/origin" "$tmp/managed-origin-$managed_case"
			continue ;;
		esac
		case "$managed_case" in preboot|preforeign|premissing|preoversize)
			cp "$RP_SMARTDNS_UCI" "$tmp/pre-managed.uci"
			cp "$RP_SMARTDNS_FILE" "$tmp/pre-managed90"
			if "$tmp/lib/smartdns-control" apply >"$tmp/managed-refused" 2>&1; then printf 'unproven preflight succeeded\n' >&2; exit 1; fi
			cmp "$RP_SMARTDNS_UCI" "$tmp/pre-managed.uci"; cmp "$RP_SMARTDNS_FILE" "$tmp/pre-managed90"
			diff -r "$active/origin" "$tmp/managed-origin-$managed_case"
			continue ;;
		esac
		case "$managed_case" in rollback-fail|receipt-conflict|file-conflict)
			if "$tmp/lib/smartdns-control" apply >"$tmp/managed-failed" 2>&1; then printf 'compensation failure succeeded\n' >&2; exit 1; fi
			grep -Fq '补偿未完整完成' "$tmp/managed-failed"
			! grep -Fq '已恢复应用前配置' "$tmp/managed-failed"
			case "$managed_case" in
				receipt-conflict) grep -Fxq external_owner=keep "$RP_STATE_DIR/applied" ;;
				file-conflict) grep -Fq external-during-publish.test "$RP_SMARTDNS_FILE" ;;
				rollback-fail) grep -Fq 'smartdns90:address /firmware-local.lab19.test/' "$RP_STATE_DIR/applied" ;;
			esac
			[ -f "$RP_SMARTDNS_CANDIDATE" ] && [ -f "$RP_LOCAL_HOSTS_CANDIDATE" ]
			diff -r "$active/origin" "$tmp/managed-origin-$managed_case"
			continue ;;
		esac
		if [ "$managed_case" = publish-sync ] || [ "$managed_case" = interrupted ]; then
			if "$tmp/lib/smartdns-control" apply >"$tmp/managed-failed" 2>&1; then printf 'managed failure succeeded\n' >&2; exit 1; fi
			cmp "$RP_STATE_DIR/applied" "$tmp/managed-receipt.before"
			[ -f "$RP_SMARTDNS_CANDIDATE" ] && [ -f "$RP_LOCAL_HOSTS_CANDIDATE" ]
			if [ "$managed_case" != interrupted ]; then
				cmp "$RP_SMARTDNS_FILE" "$tmp/managed90.before"
				"$TX" exit-preview >/dev/null
			else
				if "$TX" exit-preview >"$tmp/managed-blocked"; then exit 1; fi
				grep -Fq file:dns90 "$tmp/managed-blocked"
			fi
			diff -r "$active/origin" "$tmp/managed-origin-$managed_case"
			continue
		fi
		"$tmp/lib/smartdns-control" apply >"$tmp/managed-applied"
		grep -Fxq 'address /firmware-local.lab19.test/203.0.114.30' "$RP_SMARTDNS_FILE"
		sed '/^smartdns90/d' "$tmp/managed-receipt.before" >"$tmp/managed-metadata.before"
		sed '/^smartdns90/d' "$RP_STATE_DIR/applied" >"$tmp/managed-metadata.after"
		cmp "$tmp/managed-metadata.before" "$tmp/managed-metadata.after"
		if [ "$managed_case" = legacy-shape ]; then rm -rf "$RP_STATE_DIR/init-transaction/current"; fi
		case "$managed_case" in
			external77) uci add_list 'smartdns.@smartdns[0].conf_files=/etc/smartdns/conf.d/77-external.conf'; uci commit smartdns ;;
			oldboot) sed 's/^boot_id=.*/boot_id=00000000-0000-4000-8000-000000000099/' "$RP_STATE_DIR/applied" >"$tmp/corrupt"; cp "$tmp/corrupt" "$RP_STATE_DIR/applied" ;;
			duplicate) printf 'schema=1\n' >>"$RP_STATE_DIR/applied" ;;
			badtuple) sed 's/^route_table=.*/route_table=999/' "$RP_STATE_DIR/applied" >"$tmp/corrupt"; cp "$tmp/corrupt" "$RP_STATE_DIR/applied" ;;
			bootstrap) sed 's/^source_bootstrap=.*/source_bootstrap=1/' "$RP_STATE_DIR/applied" >"$tmp/corrupt"; cp "$tmp/corrupt" "$RP_STATE_DIR/applied" ;;
			foreign90) printf 'address /foreign.test/203.0.114.99\n' >>"$RP_SMARTDNS_FILE" ;;
			real91) printf 'cache-checkpoint-time 600\n' >>"$RP_SMARTDNS_EXTRA_FILE" ;;
			continuation) printf '\\\n' >>"$active/origin/dns-file-new"; cp -R "$active/origin/." "$tmp/managed-origin-$managed_case/" ;;
			proof-read-error) : >"$tmp/fail-proof-read" ;;
		esac
		if [ "$managed_case" != immediate ] && [ "$managed_case" != legacy-shape ]; then
			if "$TX" exit-preview >"$tmp/managed-blocked"; then printf 'exit adopted %s\n' "$managed_case" >&2; exit 1; fi
			if [ "$managed_case" = external77 ]; then
				grep -Fq field:smartdns "$tmp/managed-blocked"
				! grep -Fq file:dns "$tmp/managed-blocked"
			fi
			diff -r "$active/origin" "$tmp/managed-origin-$managed_case"
			continue
		fi
		"$TX" exit-preview >/dev/null
		output=$("$TX" exit-prepare); exit_token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
		"$TX" exit-apply "$exit_token" >"$tmp/managed-exit"
		[ "$(cat "$RP_STATE_DIR/init-transaction/current/phase")" = exited ]
		[ ! -e "$RP_SMARTDNS_FILE" ] && [ ! -e "$RP_SMARTDNS_EXTRA_FILE" ]
		grep -Fxq '203.0.114.30 firmware-local.lab19.test' "$RP_LOCAL_HOSTS"
		diff -r "$active/origin" "$tmp/managed-origin-$managed_case"
	done
	baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
	uci add_list 'smartdns.@smartdns[0].conf_files=/etc/smartdns/conf.d/90-routepolicy.conf'
	uci add_list 'smartdns.@smartdns[0].conf_files=/etc/smartdns/conf.d/91-routepolicy-smartdns-extra.conf'
	uci add_list 'smartdns.@smartdns[0].conf_files=/etc/smartdns/conf.d/77-external.conf'
	uci add_list 'smartdns.@smartdns[0].conf_files=/etc/smartdns/conf.d/78-external.conf'; uci commit smartdns
	managed_apply_dns; "$tmp/lib/smartdns-control" apply >/dev/null
	for fragment in 90-routepolicy.conf 91-routepolicy-smartdns-extra.conf; do
		[ "$(uci -q get 'smartdns.@smartdns[0].conf_files' | tr ' ' '\n' | grep -Fxc "/etc/smartdns/conf.d/$fragment")" = 1 ]
	done
	for adapter in 0 1; do
		uci set "routepolicy.main.smartdns_enabled=$adapter"; uci commit routepolicy
		"$tmp/lib/smartdns-control" status >"$tmp/managed-status"
		managed_version=$(jsonfilter -i "$tmp/managed-status" -e '@.version')
		printf 'version\t%s\ninitialize\t0\n' "$managed_version" | "$tmp/lib/smartdns-control" save >/dev/null
		"$tmp/lib/smartdns-control" apply >/dev/null
		grep -Fxq "smartdns90_present=$adapter" "$RP_STATE_DIR/applied"
		[ "$(uci -q get 'smartdns.@smartdns[0].conf_files' | tr ' ' '\n' | grep -Fc /90-routepolicy.conf || true)" = "$adapter" ]
		uci -q get 'smartdns.@smartdns[0].conf_files' | tr ' ' '\n' | grep -E '/7[78]-external.conf$' >"$tmp/unknown-order"
		printf '/etc/smartdns/conf.d/77-external.conf\n/etc/smartdns/conf.d/78-external.conf\n' >"$tmp/unknown-expected"
		cmp "$tmp/unknown-order" "$tmp/unknown-expected"
	done
	printf '%s\n' 'managed DNS exit: passed (immediate formal apply, exact receipts, failure/kill, foreign UCI/files, original ledger)'
	exit 0
fi
if [ "${1:-}" = --resolver-repair ]; then
	baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
	active=$(rp_init_active_record)
	rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
	if "$TX" repair >"$tmp/repair-auto-result" 2>&1; then printf 'confirmed repair overwrote external auto link\n' >&2; exit 1; fi
	[ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/resolv.conf.d/resolv.conf.auto ]
	[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")" = 11 ]
	"$TX" status >"$tmp/repair-status"; [ "$(jsonfilter -i "$tmp/repair-status" -e '@.active.dns_boot_state')" = resolver_conflict ]
	rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/resolv.conf.d/routepolicy.conf "$RP_RESOLVER_ENTRY"
	"$TX" repair >/dev/null
	test_boot; printf 0 >"$tmp/svc/smartdns.running"; printf 0 >"$tmp/svc/dnsmasq.running"
	"$TX" recover-early >/dev/null; "$TX" boot-dns >/dev/null
	[ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/resolv.conf.d/routepolicy.conf ]
	rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
	if "$TX" repair >/dev/null 2>&1; then printf 'post-reboot confirmed repair overwrote external auto link\n' >&2; exit 1; fi
	[ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/resolv.conf.d/resolv.conf.auto ]
	printf '%s\n' 'confirmed resolver repair: passed (external before preserved, manual restoration retries, genuine new boot rebuilds, ready-boot external rollback rejected)'
	exit 0
fi
if [ "${1:-}" = --resolver-probes ]; then
	for probe_case in legacy no-header complete duplicate-role conflict-role duplicate-address conflict-address; do
		baseline 0 0 1 1
		path="$RP_SMARTDNS_EXTRA_FILE"
		printf '# USER_KEEP unknown fragment\nprefetch-domain yes\n' >"$path"
		case "$probe_case" in no-header) rp_smartdns_init_probes | tail -n +2 >>"$path" ;; complete) rp_smartdns_init_probes >>"$path" ;; *) rp_smartdns_init_probes | head -n 3 >>"$path" ;; esac
		case "$probe_case" in
			duplicate-role) printf 'domain-rules /routepolicy-init-default.test/ -nameserver rp_init_default -speed-check-mode none\n' >>"$path" ;;
			conflict-role) printf 'domain-rules /routepolicy-init-policy.test/ -nameserver wrong\n' >>"$path" ;;
			duplicate-address) printf 'address /routepolicy-init-resolver.test/127.0.0.1\naddress /routepolicy-init-resolver.test/127.0.0.1\n' >>"$path" ;;
			conflict-address) printf 'address /routepolicy-init-resolver.test/192.0.2.99\n' >>"$path" ;;
		esac
		cp "$path" "$tmp/probe.before"
		case "$probe_case" in
			legacy|no-header|complete)
				prepare_dns 192.0.2.53
				new="$RP_STATE_DIR/init-transaction/current/dns-file-new"
				head -c "$(wc -c <"$tmp/probe.before")" "$new" >"$tmp/probe.prefix"; cmp "$tmp/probe.before" "$tmp/probe.prefix"
				for probe in default policy resolver; do expected=$(rp_smartdns_init_probes | grep -F "/routepolicy-init-$probe.test/"); [ "$(grep -Fxc "$expected" "$new")" = 1 ]; done
				confirm_dns ;;
			*) if "$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53 >/dev/null 2>&1; then printf 'duplicate/conflicting probe accepted: %s\n' "$probe_case" >&2; exit 1; fi
				cmp "$tmp/probe.before" "$path" ;;
		esac
	done
	printf '%s\n' 'resolver probe upgrade: passed (legacy/headerless/complete, unique role/address rules, unknown byte prefix preserved, duplicates/conflicts rejected before public write)'
	exit 0
fi
if [ "${1:-}" = --legacy-resolver ]; then
	[ -n "${TEST_LEGACY_INIT_LIBEXEC:-}" ] || { printf 'legacy resolver: skipped (provide frozen old libexec)\n'; exit 0; }
	baseline 0 0 1 1
	cp -R "$tmp/lib" "$tmp/legacy-lib"
	cp "$TEST_LEGACY_INIT_LIBEXEC/common" "$TEST_LEGACY_INIT_LIBEXEC/init-dns" "$TEST_LEGACY_INIT_LIBEXEC/init-transaction" "$tmp/legacy-lib/"
	chmod +x "$tmp/legacy-lib/init-transaction"
	output=$(ROUTEPOLICY_LIBEXEC="$tmp/legacy-lib" "$tmp/legacy-lib/init-transaction" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53)
	token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	ROUTEPOLICY_LIBEXEC="$tmp/legacy-lib" "$tmp/legacy-lib/init-transaction" apply "$token" >/dev/null
	SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' ROUTEPOLICY_LIBEXEC="$tmp/legacy-lib" "$tmp/legacy-lib/init-transaction" confirm "$token" >/dev/null
	test_boot; "$TX" recover-early >/dev/null
	active=$(rp_init_active_record)
	if "$TX" boot-dns >/dev/null 2>&1; then printf 'legacy resolver boot adopted without authority\n' >&2; exit 1; fi
	[ "$(cat "$active/failed-stage")" = boot-resolver-contract-missing ] && [ -f "$active/dns-boot-pending" ]
	for failure in boot-dns-start boot-dns-admission; do
		printf '%s\n' "$failure" >"$active/failed-stage"
		if "$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53 >/dev/null 2>&1; then printf 'unrelated boot failure bypassed prepare gate\n' >&2; exit 1; fi
	done
	printf 'boot-resolver-contract-missing\n' >"$active/failed-stage"
	uci set 'dhcp.@dnsmasq[0].port=53'; uci commit dhcp
	if "$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53 >/dev/null 2>&1; then printf 'legacy external conflict bypassed prepare gate\n' >&2; exit 1; fi
	uci set 'dhcp.@dnsmasq[0].port=0'; uci commit dhcp
	prepare_dns 192.0.2.53; : >"$tmp/query-fail"
	if "$TX" apply "$token" >/dev/null; then printf 'new initialization failure accepted\n' >&2; exit 1; fi
	[ -f "$active/dns-boot-pending" ] && [ ! -f "$active/dns-boot-ready" ]
	[ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/resolv.conf.d/resolv.conf.auto ] && [ ! -e "$RP_RESOLVER_FILE" ]
	rm "$tmp/query-fail"; prepare_dns 192.0.2.53; confirm_dns
	[ "$(rp_init_active_record)" != "$active" ]; (WAL=$(rp_init_active_record); export WAL; init_resolver_verify)
	printf '%s\n' 'legacy resolver reinitialization: passed (precise missing-contract gate; other failures/conflicts denied; failed apply retains old pending; new confirmed contract ready)'
	exit 0
fi
if [ "${1:-}" = --restore-prior-confirmed ] || [ "${1:-}" = --migrate ]; then
	cp "$REAL_LIB/lifecycle" "$REAL_LIB/validate" "$REAL_LIB/converter-lib" "$tmp/lib/"
	chmod +x "$tmp/lib/lifecycle" "$tmp/lib/validate" "$tmp/lib/converter-lib"
	baseline 0 0 1 1
	cp "$ROOT/routepolicy/files/etc/config/routepolicy" "$RP_UCI_CONFIG"
	uci set routepolicy.main.policy_interface=wan2; uci commit routepolicy
	if [ "${1:-}" = --migrate ]; then
		uci -q delete routepolicy.main.config_schema || true; uci commit routepolicy
		"$tmp/lib/lifecycle" migrate >/dev/null
		[ "$(uci get routepolicy.main.config_schema)" = 1 ]
	fi
	prepare_dns 192.0.2.53; confirm_dns
	if [ "${1:-}" = --migrate ]; then
		"$tmp/lib/lifecycle" migrate >/dev/null
		printf 'pending\n' >"$RP_STATE_DIR/init-transaction/current/phase"
		cp "$RP_UCI_CONFIG" "$tmp/migrate-pending.before"
		if "$tmp/lib/lifecycle" migrate >/dev/null 2>&1; then printf 'pending init migrated\n' >&2; exit 1; fi
		cmp "$tmp/migrate-pending.before" "$RP_UCI_CONFIG"; printf 'confirmed\n' >"$RP_STATE_DIR/init-transaction/current/phase"
		uci set routepolicy.main.config_schema=2; uci commit routepolicy
		if "$tmp/lib/lifecycle" migrate >/dev/null 2>&1; then printf 'future schema migrated\n' >&2; exit 1; fi
		uci set routepolicy.main.config_schema=1; uci commit routepolicy
		uci set network.lan.user_pending=keep
		if "$tmp/lib/lifecycle" migrate >/dev/null 2>&1; then printf 'pending configuration migrated\n' >&2; exit 1; fi
		[ "$(uci changes network)" != '' ]
		printf '%s\n' 'native migrate: passed (real nested archive, no/archive legacy paths, schema and pending rejection)'; exit 0
	fi
	# Restore now requires explicit policy disable; retain the confirmed DNS contract.
	uci set routepolicy.main.enabled=0; uci commit routepolicy
	ROUTEPOLICY_INIT_RESTORE=1 "$tmp/lib/apply" teardown
	mkdir -p "$RP_USER_DIR"; cp "$ROOT/routepolicy/files/etc/routepolicy/user.d/"*.list "$RP_USER_DIR/"
	ROUTEPOLICY_OUTPUT=text "$tmp/lib/lifecycle" config-export >"$tmp/prior-export"
	"$tmp/lib/lifecycle" config-import <"$tmp/prior-export" >/dev/null
	cp "$RP_UCI_CONFIG" "$tmp/prior-app.before"
	: >"$tmp/kill-installed"
	mapping=$(printf 'lan\twan\twan2\t-\t-\t-\t-\t-\t-\t-\t-\t192.0.2.53\t198.51.100.53\t1\t1\n')
	if printf '%s\n' "$mapping" | "$tmp/lib/lifecycle" restore-prepare >/dev/null 2>&1; then printf 'installed kill missing\n' >&2; exit 1; fi
	decl="$RP_STATE_DIR/init-transaction/declarations"
	[ ! -e "$decl/init-token" ] && [ "$(cat "$decl/phase")" = installed ]
	"$tmp/lib/lifecycle" restore-recover >/dev/null
	cmp "$tmp/prior-app.before" "$RP_UCI_CONFIG"; [ "$(cat "$decl/phase")" = rolled_back ]
	(WAL=$(rp_init_active_record); export WAL; init_resolver_verify)
	printf '%s\n' 'prior confirmed declaration recovery: passed (real installed sync kill, no new token, original declarations and resolver preserved)'
	exit 0
fi
if [ "${1:-}" = --restore-empty ] || [ "${1:-}" = --restore-confirmed ] || [ "${1:-}" = --restore-cancel ]; then
	cp "$REAL_LIB/lifecycle" "$REAL_LIB/validate" "$REAL_LIB/converter-lib" "$tmp/lib/"
	chmod +x "$tmp/lib/lifecycle" "$tmp/lib/validate" "$tmp/lib/converter-lib"
	for restore_case in success failure; do
		baseline 0 0 1 1
		cp "$ROOT/routepolicy/files/etc/config/routepolicy" "$tmp/root/etc/config/routepolicy"
		uci set routepolicy.main.policy_interface=wan2; uci commit routepolicy
		mkdir -p "$RP_USER_DIR" "$RP_MANAGED_CURRENT" "$RP_MANAGED_PREVIOUS"
		cp "$ROOT/routepolicy/files/etc/routepolicy/user.d/"*.list "$RP_USER_DIR/"
		printf 'stale.example\n' >"$RP_MANAGED_CURRENT/old.domain-policy.list"
		printf 'unknown\n' >"$RP_MANAGED_CURRENT/user.keep"
		printf 'previous\n' >"$RP_MANAGED_PREVIOUS/old.keep"
		cp -pR "$tmp/root/etc/routepolicy/managed.d" "$tmp/restore-before-$restore_case"
		ROUTEPOLICY_OUTPUT=text "$tmp/lib/lifecycle" config-export >"$tmp/restore-export"
		"$tmp/lib/lifecycle" config-import <"$tmp/restore-export" >/dev/null
		cp "$RP_UCI_CONFIG" "$tmp/restore-app.before"
		mapping=$(printf 'lan\twan\twan2\t-\t-\t-\t-\t-\t-\t-\t-\t192.0.2.53\t198.51.100.53\t1\t1\n')
		decl="$tmp/root/etc/routepolicy/state/init-transaction/declarations"
		network="$RP_STATE_DIR/init-transaction/current"
		if [ "${1:-}" = --restore-cancel ] && [ "$restore_case" = success ]; then
			prepare_dns 192.0.2.53
			: >"$tmp/kill-preparing"
			if printf '%s\n' "$mapping" | "$tmp/lib/lifecycle" restore-prepare >/dev/null 2>&1; then exit 1; fi
			[ "$(cat "$decl/phase")" = preparing ] && [ "$(cat "$network/phase")" = prepared ]
			if "$tmp/lib/lifecycle" restore-recover >"$tmp/restore-recover-blocked"; then exit 1; fi
			grep -Fq '先按当前 token 取消' "$tmp/restore-recover-blocked"
			[ "$(cat "$decl/phase")" = preparing ] && [ "$(cat "$network/phase")" = prepared ]
			"$TX" cancel-prepared "$token" >/dev/null
			"$tmp/lib/lifecycle" restore-recover >/dev/null
			[ "$(cat "$decl/phase")" = rolled_back ] && [ "$(cat "$network/phase")" = expired ]
			cmp "$RP_UCI_CONFIG" "$tmp/restore-app.before"
			prepare_dns 192.0.2.53
			"$tmp/lib/lifecycle" restore-recover >/dev/null
			[ "$(cat "$decl/phase")" = rolled_back ] && [ "$(cat "$network/phase")" = prepared ]
		fi
		output=$(printf '%s\n' "$mapping" | "$tmp/lib/lifecycle" restore-prepare)
		token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
		if [ "${1:-}" = --restore-cancel ]; then
			"$tmp/lib/lifecycle" restore-status | grep -Fq "\"init_token\":\"$token\""
			# Reproduce the durable boundary after prepare publishes but before binding is complete.
			if [ "$restore_case" = success ]; then rm "$decl/init-token"; else printf '%s' "$token" >"$decl/init-token"; fi
			"$tmp/lib/lifecycle" restore-status | grep -Fq '"init_token":""'
			cp "$RP_UCI_CONFIG" "$tmp/restore-app.installed"
			if "$tmp/lib/lifecycle" restore-recover >"$tmp/restore-recover-blocked"; then exit 1; fi
			grep -Fq '先按当前 token 取消' "$tmp/restore-recover-blocked"
			if "$tmp/lib/apply" >/dev/null 2>&1 || "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
			if "$TX" cancel-prepared bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >/dev/null; then exit 1; fi
			[ "$(cat "$network/phase")" = prepared ] && [ "$(cat "$decl/phase")" = installed ]
			cmp "$RP_UCI_CONFIG" "$tmp/restore-app.installed"
			"$ROOT/routepolicy/files/usr/sbin/routepolicyctl" init-cancel "$token" >/dev/null
			"$TX" cancel-prepared "$token" | grep -Fq '"phase":"expired"'
			[ "$(cat "$decl/phase")" = installed ]
			"$tmp/lib/lifecycle" restore-recover >/dev/null
			[ "$(cat "$decl/phase")" = rolled_back ]
			cmp "$RP_UCI_CONFIG" "$tmp/restore-app.before"
			prepare_dns 192.0.2.53
			continue
		fi
		if [ "${1:-}" = --restore-confirmed ]; then
			confirm_dns
			# Durable network commit exists; declaration phase publication was interrupted.
			printf 'installed\n' >"$decl/phase"
			cp "$RP_UCI_CONFIG" "$tmp/confirmed-app"
			printf 'watcher retry\n' >"$network/confirm-error"; printf 0 >"$tmp/svc/routepolicy.running"
			if "$TX" finish-confirmed bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >/dev/null; then exit 1; fi
			[ "$(cat "$decl/phase")" = installed ] && [ -f "$network/confirm-error" ] &&
				[ "$(cat "$tmp/svc/routepolicy.running")" = 0 ]
			"$TX" finish-confirmed "$token" >/dev/null
			"$TX" finish-confirmed "$token" >/dev/null
			[ "$(cat "$decl/phase")" = committed ] && [ ! -e "$network/confirm-error" ] &&
				[ "$(cat "$tmp/svc/routepolicy.running")" = 1 ]
			printf 'installed\n' >"$decl/phase"
			"$tmp/lib/lifecycle" restore-recover >"$tmp/confirmed-recover"
			cmp "$RP_UCI_CONFIG" "$tmp/confirmed-app"
			[ "$(cat "$decl/phase")" = committed ]
			printf 'installed\n' >"$decl/phase"; printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$decl/init-token"
			if "$tmp/lib/lifecycle" restore-recover >/dev/null 2>&1; then printf 'mismatched confirmed token recovered declarations\n' >&2; exit 1; fi
			cmp "$RP_UCI_CONFIG" "$tmp/confirmed-app"
			printf '%s\n' 'confirmed declaration recovery: passed (scoped watcher finish, commit gap converged; mismatched token preserves declarations)'
			exit 0
		fi
		if [ "$restore_case" = failure ]; then
			: >"$tmp/query-fail"
			if "$TX" apply "$token" >"$tmp/restore-failure"; then printf 'restore DNS failure accepted\n' >&2; exit 1; fi
			diff -r "$tmp/restore-before-$restore_case" "$tmp/root/etc/routepolicy/managed.d"
			"$tmp/lib/lifecycle" restore-recover >/dev/null
		else
			confirm_dns
			[ -z "$(find "$RP_MANAGED_CURRENT" -mindepth 1)" ] || { printf 'source-free restore retained old snapshots\n' >&2; exit 1; }
			rp_merge_lists domain-policy "$tmp/restored-merged"
			[ ! -s "$tmp/restored-merged" ]
		fi
	done
	if [ "${1:-}" = --restore-cancel ]; then
		printf '%s\n' 'prepared declaration recovery: passed (preparing interruption, terminal idempotence, absent/partial binding, scoped cancellation and exact recovery)'
		exit 0
	fi
	printf '%s\n' 'source-free restore: passed (empty published snapshot; failure restores current/previous and unknown files)'
	exit 0
fi
if [ "${1:-}" = --exit-disabled ]; then
	cp "$REAL_LIB/init-policy-runtime" "$tmp/lib/"
	cat >"$tmp/bin/nft" <<'SH'
#!/bin/sh
case "$1:$2" in
	list:table) test -f "$TEST_DNS_TMP/policy-running" ;;
	list:tables) if [ -f "$TEST_DNS_TMP/policy-running" ]; then printf 'table inet routepolicy\n'; fi ;;
	delete:table) rm -f "$TEST_DNS_TMP/policy-running" ;;
	*) exit 1 ;;
esac
SH
	cat >"$tmp/bin/ip" <<'SH'
#!/bin/sh
case "$*" in
	'-4 -N rule show'|'-4 rule show')
		printf '0: from all lookup 255\n32766: from all lookup 254\n32767: from all lookup 253\n'
		if [ -f "$TEST_DNS_TMP/foreign-rule" ]; then printf '11000: from all lookup 201\n'; fi ;;
	'-4 route flush table 200') : >"$TEST_DNS_TMP/route-flushed" ;;
	'-4 route show table 200')
		if [ -f "$TEST_DNS_TMP/policy-running" ] && [ ! -f "$TEST_DNS_TMP/route-flushed" ]; then
			printf 'default via 198.51.100.1 dev eth2 metric 10\n'
		fi ;;
	'-4 -N route show table all'|'-4 rule del '*) ;;
	*) exit 1 ;;
esac
SH
	TEST_EXIT_MV=$(command -v mv); export TEST_EXIT_MV
	cat >"$tmp/bin/mv" <<'SH'
#!/bin/sh
"$TEST_EXIT_MV" "$@" || exit $?
for target do :; done
if [ "$target" = "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current" ] &&
	[ -f "$target/dns90-new-absent" ] && [ -f "$TEST_DNS_TMP/kill-disabled-exit" ]; then
	rm "$TEST_DNS_TMP/kill-disabled-exit"; kill -KILL "$PPID"
fi
SH
	chmod +x "$tmp/bin/nft" "$tmp/bin/ip" "$tmp/bin/mv"
	for disabled_case in inactive-absent inactive-present active-absent active-present active-changed manual partial unknown reordered field foreign-rule promoted promoted-boot promoted-foreign; do
		baseline 0 0 1 1
		rm -f "$tmp/route-flushed" "$tmp/foreign-rule"
		original_active=0; original_file=0
		case "$disabled_case" in active-*) original_active=1 ;; esac
		case "$disabled_case" in *-present|active-changed|promoted*) original_file=1 ;; esac
		uci set "routepolicy.main.enabled=$original_active"
		uci set "routepolicy.main.smartdns_enabled=$original_file"
		uci set routepolicy.main.smartdns_policy_group=policy
		uci commit routepolicy
		if [ "$original_active" = 1 ]; then
			rp_ensure_dirs
			printf 'policy_interface=wan2\n' >"$RP_STATE_DIR/applied"
			: >"$tmp/policy-running"
		fi
		if [ "$original_file" = 1 ]; then
			if [ "$original_active" = 1 ]; then rp_render_smartdns90 "$RP_SMARTDNS_FILE"
			else printf '# Original user fragment\n' >"$RP_SMARTDNS_FILE"; fi
			uci add_list 'smartdns.@smartdns[0].conf_files=/etc/smartdns/conf.d/90-routepolicy.conf'
			uci commit smartdns
			cp "$RP_SMARTDNS_FILE" "$tmp/original90"
		fi
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.before"; done
		prepare_dns 192.0.2.53; confirm_dns
		active=$(rp_init_active_record); txroot="$RP_STATE_DIR/init-transaction"
		cp -R "$active/origin" "$tmp/origin-disabled-$disabled_case"
		managed_apply_dns
		if [ "$disabled_case" = active-present ]; then rm "$RP_LOCAL_HOSTS_CANDIDATE"; fi
		"$tmp/lib/smartdns-control" apply >/dev/null
		"$TX" exit-preview >/dev/null
		if [ "$disabled_case" = manual ]; then
			rm "$RP_SMARTDNS_FILE"
			if "$TX" exit-preview >"$tmp/disabled-conflict"; then printf 'exit adopted a manually removed 90\n' >&2; exit 1; fi
			grep -Fq file:dns90 "$tmp/disabled-conflict"
			continue
		fi
		uci set routepolicy.main.enabled=0; uci commit routepolicy
		if [ "$disabled_case" = partial ]; then
			rm "$RP_SMARTDNS_FILE"
			rp_smartdns_set_registration "$RP_SMARTDNS_FILE" 0
			if "$TX" exit-preview >"$tmp/disabled-conflict"; then printf 'exit adopted an incomplete teardown\n' >&2; exit 1; fi
			grep -Fq policy-disable-incomplete "$tmp/disabled-conflict"
			[ -f "$RP_STATE_DIR/applied" ] && [ -f "$tmp/policy-running" ] || exit 1
			continue
		fi
		(
			export ROUTEPOLICY_APPLY="$REAL_LIB/apply"
			config_load() { :; }
			config_get_bool() {
				# shellcheck disable=SC2034
				enabled=$(uci -q get routepolicy.main.enabled)
			}
			# shellcheck disable=SC1090
			. "$TEST_DNS_REAL_INIT"
			reload_service
		) >"$tmp/ordinary-disabled"
		[ ! -e "$RP_SMARTDNS_FILE" ] && [ ! -e "$RP_STATE_DIR/applied" ] && [ ! -e "$RP_ACTIVE_DIR" ] || exit 1
		[ "$(cat "$tmp/svc/smartdns.running")" = 1 ]
		rm -f "$tmp/route-flushed"
		case "$disabled_case" in
			unknown) uci add_list 'smartdns.@smartdns[0].conf_files=/etc/smartdns/conf.d/77-external.conf'; uci commit smartdns ;;
			reordered)
				uci del_list 'smartdns.@smartdns[0].conf_files=/etc/smartdns/custom-a.conf'
				uci add_list 'smartdns.@smartdns[0].conf_files=/etc/smartdns/custom-a.conf'; uci commit smartdns ;;
			field) uci set 'smartdns.@smartdns[0].port=6054'; uci commit smartdns ;;
			foreign-rule) : >"$tmp/foreign-rule" ;;
		esac
		case "$disabled_case" in active-changed|unknown|reordered|field|foreign-rule)
			cp -R "$tmp/root/etc/config" "$tmp/before-disabled-$disabled_case"
			if "$TX" exit-prepare >"$tmp/disabled-conflict"; then printf 'exit adopted %s\n' "$disabled_case" >&2; exit 1; fi
			case "$disabled_case" in
				active-changed) grep -Fq '原有分流与当前声明不一致，无法安全恢复' "$tmp/disabled-conflict" ;;
				unknown|reordered) grep -Fq '.conf_files' "$tmp/disabled-conflict" ;;
				field) grep -Fq '.port' "$tmp/disabled-conflict" ;;
				foreign-rule) grep -Fq policy-disable-incomplete "$tmp/disabled-conflict" ;;
			esac
			diff -r "$tmp/root/etc/config" "$tmp/before-disabled-$disabled_case"
			diff -r "$active/origin" "$tmp/origin-disabled-$disabled_case"
			[ ! -e "$txroot/exit-token" ]
			continue ;;
		esac
		"$TX" exit-preview >"$tmp/disabled-preview"
		output=$("$TX" exit-prepare); exit_token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
		case "$disabled_case" in promoted*)
			: >"$tmp/kill-disabled-exit"
			if "$TX" exit-apply "$exit_token" >"$tmp/disabled-exit-killed" 2>&1; then printf 'exit promotion fault was missed\n' >&2; exit 1; fi
			[ "$(cat "$txroot/current/dns90-new-absent")" = 1 ] && [ ! -e "$txroot/current/dns90-new" ] || exit 1
			[ -f "$txroot/current/dns90-old" ] && [ ! -e "$txroot/current/dns90-absent" ] || exit 1
			if [ "$disabled_case" = promoted-boot ]; then
				test_boot; "$TX" recover-early >"$tmp/disabled-early"
				cmp "$RP_SMARTDNS_FILE" "$tmp/original90"
			elif [ "$disabled_case" = promoted-foreign ]; then
				printf 'address /external.test/203.0.114.99\n' >"$RP_SMARTDNS_FILE"
				cp -R "$tmp/root/etc/config" "$tmp/before-disabled-foreign"
				if "$TX" recover >/dev/null 2>&1; then printf 'exit overwrote external 90 after promotion\n' >&2; exit 1; fi
				grep -Fq external.test "$RP_SMARTDNS_FILE"
				diff -r "$tmp/root/etc/config" "$tmp/before-disabled-foreign"
				diff -r "$active/origin" "$tmp/origin-disabled-$disabled_case"
				continue
			fi
			"$TX" recover >"$tmp/disabled-exited" ;;
		*) "$TX" exit-apply "$exit_token" >"$tmp/disabled-exited" ;;
		esac
		[ "$(cat "$txroot/current/phase")" = exited ] && [ ! -e "$txroot/active" ] || exit 1
		[ "$(uci -q get routepolicy.main.enabled)" = "$original_active" ]
		if [ "$original_active" = 1 ]; then [ -f "$tmp/policy-running" ] && [ -f "$RP_STATE_DIR/applied" ] || exit 1
		else [ ! -f "$tmp/policy-running" ] && [ ! -e "$RP_STATE_DIR/applied" ] || exit 1; fi
		if [ "$original_file" = 1 ]; then cmp "$RP_SMARTDNS_FILE" "$tmp/original90"
		else [ ! -e "$RP_SMARTDNS_FILE" ]; fi
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.after"; cmp "$tmp/$package.before" "$tmp/$package.after"; done
		diff -r "$active/origin" "$tmp/origin-disabled-$disabled_case"
	done
	printf '%s\n' 'disabled exit: passed (native teardown, original policy/file, foreign edits/runtime, private-stage and cold recovery)'
	exit 0
fi
if [ "${1:-}" = --exit-archive ]; then
	for archive_case in sameboot reboot conflict; do
		baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
		txroot="$RP_STATE_DIR/init-transaction"
		rm -rf "$txroot/current"
		if [ "$archive_case" = reboot ]; then test_boot; "$TX" recover-early >/dev/null; "$TX" boot-dns >/dev/null; fi
		origin="$txroot/confirmed/$(cat "$txroot/active")/origin"
		cp -R "$origin" "$tmp/origin-$archive_case"
		"$TX" exit-preview >"$tmp/archive-preview"; [ ! -e "$txroot/current" ]
		output=$("$TX" exit-prepare); [ ! -e "$txroot/current" ]
		exit_token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
		if [ "$archive_case" = conflict ]; then
			uci set smartdns.rp_init_default_1.user_note=KEEP; uci commit smartdns
			cp "$RP_SMARTDNS_UCI" "$tmp/archive-conflict.before"
			if "$TX" exit-apply "$exit_token" >"$tmp/archive-conflict" 2>&1; then printf 'archive exit overwrote unknown child\n' >&2; exit 1; fi
			cmp "$RP_SMARTDNS_UCI" "$tmp/archive-conflict.before"
			[ ! -e "$txroot/current" ] && [ -f "$txroot/active" ]
			diff -r "$origin" "$tmp/origin-$archive_case"
			continue
		fi
		"$TX" exit-apply "$exit_token" >"$tmp/archive-exit"
		[ "$(cat "$txroot/current/phase")" = exited ] && [ "$(cat "$txroot/current/kind")" = exit ]
		[ ! -e "$txroot/active" ]; [ ! -f "$tmp/policy-running" ]
		[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 11 ]
		diff -r "$origin" "$tmp/origin-$archive_case"
	done
	printf '%s\n' 'confirmed-only exit: passed (no current, same/new boot, preview/prepare create no current, real exit, unknown child preserved)'
	exit 0
fi
if [ "${1:-}" = --cache-reinit ]; then
	cache="$RP_RUN_DIR/smartdns.cache"
	txroot="$RP_STATE_DIR/init-transaction"; wal="$txroot/current"
	setup_exited_cache() {
		baseline 0 0 1 1
		uci -q delete 'smartdns.@smartdns[0].cache_file'; uci commit smartdns
		canonical smartdns >"$tmp/smartdns.before"
		prepare_dns 192.0.2.53; confirm_dns
		[ "$(cat "$cache")" = FRESH ]
		printf '%s\n' 'unknown old cache bytes' >"$tmp/cache-before"; cp "$tmp/cache-before" "$cache"
		"$TX" exit-prepare >"$tmp/cache-exit-review"
		exit_token=$(jsonfilter -i "$tmp/cache-exit-review" -e '@.token')
		"$TX" exit-apply "$exit_token" >/dev/null
		[ "$(cat "$wal/phase")" = exited ]; restored; cmp "$tmp/cache-before" "$cache"
	}
	prepare_cache_again() {
		if ! prepare_dns 192.0.2.53; then printf 'reinitialize after completed exit failed: %s\n' "$output" >&2; exit 1; fi
		cmp "$tmp/cache-before" "$cache"
		[ -f "$wal/dns-cache-preserve" ] && [ ! -e "$cache.init-$token" ] || exit 1
	}
	setup_exited_cache
	prepare_cache_again
	"$TX" cancel-prepared "$token" >/dev/null
	[ "$(cat "$wal/phase")" = expired ] && [ ! -e "$wal/boot-id" ] || exit 1
	restored
	prepare_cache_again; prepare_cache_again
	cat >"$tmp/bin/fw4" <<'SH'
#!/bin/sh
[ "$1" != check ] || [ ! -f "$TEST_DNS_TMP/fail-before-cache-move" ]
SH
	: >"$tmp/fail-before-cache-move"
	if "$TX" apply "$token" >"$tmp/cache-before-move-failed"; then exit 1; fi
	rm "$tmp/fail-before-cache-move"
	[ "$(cat "$wal/phase")" = rolled_back ] && [ ! -e "$wal/dns-cache-move" ] || exit 1
	grep -Fq 'firewall-check' "$tmp/cache-before-move-failed"
	restored; cmp "$tmp/cache-before" "$cache"
	prepare_cache_again
	TEST_CACHE_MV=$(command -v mv); export TEST_CACHE_MV
	cat >"$tmp/bin/mv" <<'SH'
#!/bin/sh
"$TEST_CACHE_MV" "$@" || exit $?
case "${2:-}:${3:-}" in */smartdns.cache:*/smartdns.cache.init-*)
	if [ -f "$TEST_DNS_TMP/kill-cache-move" ]; then rm "$TEST_DNS_TMP/kill-cache-move"; kill -KILL "$PPID"; fi ;;
	*/smartdns.cache.init-*:*/smartdns.cache)
		if [ -f "$TEST_DNS_TMP/kill-cache-restore" ]; then rm "$TEST_DNS_TMP/kill-cache-restore"; kill -KILL "$PPID"; fi ;;
esac
SH
	chmod +x "$tmp/bin/mv"
	: >"$tmp/kill-cache-move"
	if "$TX" apply "$token" >"$tmp/cache-kill-output" 2>&1; then exit 1; fi
	[ "$(cat "$wal/dns-cache-move")" = preserve-intent ] && [ ! -e "$cache" ] || exit 1
	cmp "$tmp/cache-before" "$cache.init-$token"
	"$TX" recover >/dev/null; restored; cmp "$tmp/cache-before" "$cache"
	[ ! -e "$cache.init-$token" ]
	prepare_cache_again
	: >"$tmp/query-fail"
	if "$TX" apply "$token" >"$tmp/cache-apply-failed"; then exit 1; fi
	rm "$tmp/query-fail"
	[ "$(cat "$wal/phase")" = rolled_back ]; restored; cmp "$tmp/cache-before" "$cache"
	[ "$(cat "$cache.init-$token.failed")" = FRESH ]
	prepare_cache_again
	"$TX" apply "$token" >/dev/null
	[ "$(cat "$cache")" = FRESH ]; cmp "$tmp/cache-before" "$cache.init-$token"
	mv "$cache" "$tmp/cache-generated"; ln -s "$tmp/cache-generated" "$cache"
	if "$TX" recover >"$tmp/cache-conflict"; then exit 1; fi
	[ "$(cat "$wal/phase")" = conflict ] && [ -L "$cache" ] && [ "$(cat "$cache")" = FRESH ] || exit 1
	cmp "$tmp/cache-before" "$cache.init-$token"; restored
	mv "$cache.init-$token" "$tmp/cache-displaced-backup"
	if "$TX" recover >"$tmp/cache-missing-backup" 2>"$tmp/cache-missing-backup.stderr"; then
		printf '%s\n' 'missing preserved backup with live symlink reported successful rollback' >&2; exit 1
	fi
	grep -Fq 'SmartDNS 缓存恢复有冲突' "$tmp/cache-missing-backup.stderr"
	[ "$(cat "$wal/phase")" = conflict ] && [ -L "$cache" ] && [ "$(cat "$cache")" = FRESH ] || exit 1
	cmp "$tmp/cache-before" "$tmp/cache-displaced-backup"
	rm "$cache"; mv "$tmp/cache-generated" "$cache"
	if "$TX" recover >"$tmp/cache-missing-ordinary" 2>"$tmp/cache-missing-ordinary.stderr"; then printf '%s\n' 'ordinary target hid missing backup' >&2; exit 1; fi
	grep -Fq '本次启动已移走的 SmartDNS 原缓存备份缺失' "$tmp/cache-missing-ordinary.stderr"
	[ "$(cat "$wal/phase")" = conflict ] && [ "$(cat "$cache")" = FRESH ] || exit 1
	mv "$tmp/cache-displaced-backup" "$cache.init-$token"
	mkdir "$cache.init-$token.failed"
	if "$TX" recover >"$tmp/cache-failed-path-conflict"; then exit 1; fi
	[ -d "$cache.init-$token.failed" ] && [ "$(cat "$cache")" = FRESH ] || exit 1
	cmp "$tmp/cache-before" "$cache.init-$token"; rmdir "$cache.init-$token.failed"
	: >"$tmp/kill-cache-restore"
	if "$TX" recover >"$tmp/cache-restore-killed" 2>&1; then exit 1; fi
	[ "$(cat "$wal/dns-cache-move")" = preserve-restoring ] && [ ! -e "$cache.init-$token" ] || exit 1
	cmp "$tmp/cache-before" "$cache"
	"$TX" recover >/dev/null; restored; cmp "$tmp/cache-before" "$cache"
	prepare_cache_again
	confirm_dns
	[ "$(cat "$cache")" = FRESH ]; cmp "$tmp/cache-before" "$cache.init-$token"
	[ "$(cat "$tmp/root/etc/smartdns/user.cache")" = USER-CACHE ]
	printf '%s\n' 'cache reinit: canceled preparation, untouched rollback, interrupted move/restore, missing backup conflicts and confirmation preserve bytes'
	setup_exited_cache; prepare_cache_again
	"$TX" apply "$token" >/dev/null
	[ "$(cat "$wal/dns-cache-move")" = preserve-moved ]
	# Both token backups and the live cache are in the volatile /tmp namespace.
	rm "$cache" "$cache.init-$token"; test_boot
	ln -s "$tmp/cache-before" "$cache"
	if "$TX" recover >"$tmp/cache-reboot-link-conflict"; then exit 1; fi
	[ "$(cat "$wal/phase")" = conflict ] && [ -L "$cache" ] || exit 1
	rm "$cache"
	"$TX" recover >/dev/null; restored
	[ "$(cat "$wal/phase")" = rolled_back ] && [ ! -e "$cache" ] || exit 1
	printf '%s\n' 'cache reinit: after reboot volatile backups may be absent without a same-boot restore claim'
	setup_exited_cache
	boot_file="$RP_ROOT/proc/sys/kernel/random/boot_id"; cp "$boot_file" "$tmp/cache-original-boot"
	for edge in symlink directory forged cross-boot changed-config; do
		case "$edge" in
			symlink) mv "$cache" "$tmp/cache-displaced"; ln -s "$tmp/cache-displaced" "$cache" ;;
			directory) mv "$cache" "$tmp/cache-displaced"; mkdir "$cache" ;;
			forged) mv "$wal/exit-complete" "$tmp/cache-exit-complete" ;;
			cross-boot) printf '00000000-0000-4000-8000-000000000099\n' >"$boot_file" ;;
			changed-config) uci set 'smartdns.@smartdns[0].cache_file=/etc/smartdns/other.cache'; uci commit smartdns ;;
		esac
		if prepare_dns 192.0.2.53; then printf 'accepted conflicting cache: %s\n' "$edge" >&2; exit 1; fi
		printf '%s\n' "$output" | grep -Fq '未移动缓存'
		[ "$(cat "$wal/phase")" = exited ]
		case "$edge" in
			symlink) [ -L "$cache" ]; rm "$cache"; mv "$tmp/cache-displaced" "$cache" ;;
			directory) rmdir "$cache"; mv "$tmp/cache-displaced" "$cache" ;;
			forged) mv "$tmp/cache-exit-complete" "$wal/exit-complete" ;;
			cross-boot) cp "$tmp/cache-original-boot" "$boot_file" ;;
			changed-config) uci -q delete 'smartdns.@smartdns[0].cache_file'; uci commit smartdns ;;
		esac
		cmp "$tmp/cache-before" "$cache"
	done
	baseline 0 0 1 1; mkdir -p "$RP_RUN_DIR"; cp "$tmp/cache-before" "$cache"
	if prepare_dns 192.0.2.53; then exit 1; fi
	printf '%s\n' "$output" | grep -Fq '没有可信的本次启动退出记录'
	cmp "$tmp/cache-before" "$cache"; restored
	printf '%s\n' 'cache reinit: symlink, directory, missing exit proof, other boot, changed configuration and unrelated cache rejected'
	exit 0
fi
if [ "${1:-}" = --web-exit ]; then
	baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
	txroot="$RP_STATE_DIR/init-transaction"
	"$TX" status >"$tmp/web-health"
	[ "$(jsonfilter -i "$tmp/web-health" -e '@.health.rules_loaded')" = true ]
	[ "$(jsonfilter -i "$tmp/web-health" -e '@.health.sets_loaded')" = true ]
	[ "$(jsonfilter -i "$tmp/web-health" -e '@.health.dns_queries[*].rcode' | grep -c '^NOERROR$')" = 4 ]
	touch "$tmp/nft-missing-set"
	"$TX" status >"$tmp/web-health"
	[ "$(jsonfilter -i "$tmp/web-health" -e '@.health.sets_loaded')" = false ]
	rm "$tmp/nft-missing-set"
	cat >"$tmp/root/etc/init.d/routepolicy-initguard" <<'EOF'
#!/bin/sh
[ "$1" != start ] || "$ROUTEPOLICY_LIBEXEC/init-transaction" guard-needed
EOF
	prepare_web_exit() {
		"$TX" exit-prepare >"$tmp/exit-review"
		"$TX" exit-candidate >"$tmp/exit-reopened"
		cmp "$tmp/exit-review" "$tmp/exit-reopened"
		exit_token=$(jsonfilter -i "$tmp/exit-review" -e '@.token')
	}
	wait_web_exit() {
		polls=0
		while ! grep -q "^$exit_token " "$txroot/job-result" 2>/dev/null; do
			polls=$((polls + 1)); [ "$polls" -lt 600 ] || { "$TX" status; return 1; }
			sleep 0.05
		done
	}
	prepare_web_exit
	grep -Fq 'dnsmasq\trunning\t0\t1' "$tmp/exit-review"
	uci add_list network.lan.ip6addr=2001:db8::1/64; uci commit network
	"$TX" start-exit "$exit_token" >/dev/null; wait_web_exit
	"$TX" status | grep -Fq '"state":"failed","error":"退出候选的原值或服务状态已变化'
	[ "$(cat "$txroot/current/phase")" = confirmed ]
	uci -q delete network.lan.ip6addr; uci commit network
	"$TX" start-exit "$exit_token" | grep -Fq '"state":"failed"'
	TEST_EXIT_CP=$(command -v cp); TEST_EXIT_MV=$(command -v mv)
	export TEST_EXIT_CP TEST_EXIT_MV
	cat >"$tmp/bin/cp" <<'SH'
#!/bin/sh
case "$1:${2:-}" in -pR:*/origin/.)
	if [ -f "$TEST_DNS_TMP/exit-copy-fail" ]; then
		txroot="$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction"
		for item in output error result.new; do
			[ -f "$txroot/job-$item" ] || printf '%s\n' "$item" >>"$TEST_DNS_TMP/unreserved-job-files"
		done
		"$TEST_EXIT_CP" "$2/schema" "$3/schema" || exit 1
		printf '%s\n' 'simulated storage failure during origin copy' >&2
		exit 1
	fi ;;
esac
exec "$TEST_EXIT_CP" "$@"
SH
	cat >"$tmp/bin/mv" <<'SH'
#!/bin/sh
case "$1" in */job-result.new)
	if [ -f "$TEST_DNS_TMP/exit-result-fail" ]; then
		: >"$TEST_DNS_TMP/exit-result-failed"
		exit 1
	fi ;;
esac
exec "$TEST_EXIT_MV" "$@"
SH
	chmod +x "$tmp/bin/cp" "$tmp/bin/mv"
	cp -R "$tmp/root/etc/config" "$tmp/exit-config-before"
	cp -R "$txroot/current" "$tmp/exit-current-before"
	active=$(rp_init_active_record); cp -R "$active" "$tmp/exit-active-before"
	copy_failure() {
		: >"$tmp/exit-copy-fail"
		"$TX" start-exit "$exit_token" >/dev/null
		polls=0
		while ! flock -n "$txroot/lock" true; do
			polls=$((polls + 1)); [ "$polls" -lt 600 ] || return 1
			sleep 0.05
		done
		rm "$tmp/exit-copy-fail"
		"$TX" status >"$tmp/exit-copy-status"
		[ "$(jsonfilter -i "$tmp/exit-copy-status" -e '@.job.token')" = "$exit_token" ]
		grep -Fq '"state":"failed","error":"无法复制退出归属记录' "$tmp/exit-copy-status"
		grep -Fq '可创建文件数量（inode）' "$tmp/exit-copy-status"
		grep -Fq '尚未恢复网络配置' "$tmp/exit-copy-status"
		[ ! -s "$tmp/unreserved-job-files" ]
		[ -f "$txroot/exiting-$exit_token/schema" ] && [ ! -e "$txroot/previous" ]
		grep -Fq '无法复制退出归属记录' "$txroot/job-output"
		diff -r "$tmp/exit-current-before" "$txroot/current"
		diff -r "$tmp/exit-active-before" "$(rp_init_active_record)"
		diff -r "$tmp/exit-config-before" "$tmp/root/etc/config"
	}
	prepare_web_exit; copy_failure
	grep -Fxq "$exit_token failed" "$txroot/job-result"
	for item in request result error output; do cp "$txroot/job-$item" "$tmp/exit-prior-$item"; done
	prepare_web_exit
	chmod 400 "$txroot/job-output"
	if [ -w "$txroot/job-output" ]; then mkdir "$txroot/job-request.new"; fi
	if "$TX" start-exit "$exit_token" >"$tmp/exit-reservation-failed"; then exit 1; fi
	grep -Fq '无法预留后台事务记录' "$tmp/exit-reservation-failed"
	if [ ! -w "$txroot/job-output" ]; then grep -Fq '可创建文件数量（inode）' "$tmp/exit-reservation-failed"; fi
	for item in request result error output; do cmp "$tmp/exit-prior-$item" "$txroot/job-$item"; done
	[ ! -e "$txroot/exiting-$exit_token" ]
	chmod 600 "$txroot/job-output"
	[ ! -d "$txroot/job-request.new" ] || rmdir "$txroot/job-request.new"
	: >"$tmp/exit-result-fail"; copy_failure
	[ -f "$tmp/exit-result-failed" ]
	cmp "$tmp/exit-prior-result" "$txroot/job-result"
	grep -Fxq "$exit_token failed" "$txroot/job-result.new"
	rm "$tmp/exit-result-fail"
	prepare_web_exit
	"$TX" start-exit "$exit_token" >/dev/null
	"$TX" start-exit "$exit_token" >/dev/null
	wait_web_exit
	"$TX" status | grep -Fq '"phase":"exited"'
	"$TX" start-exit "$exit_token" | grep -Fq '"state":"done"'
	restored
	[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 11 ]
	printf '%s\n' 'web exit: exact review, external change rejected, storage and publication failures preserved, guard, idempotent exit and original DNS restored'
	exit 0
fi
if [ "${1:-}" = --exit-stage ]; then
	TEST_EXIT_CP=$(command -v cp); export TEST_EXIT_CP
	cat >"$tmp/bin/cp" <<'SH'
#!/bin/sh
"$TEST_EXIT_CP" "$@" || exit $?
for argument do
	case "$argument" in */origin/.)
		if [ -f "$TEST_DNS_TMP/kill-exit-copy" ]; then rm "$TEST_DNS_TMP/kill-exit-copy"; kill -KILL "$PPID"; fi ;;
		*/candidate)
		if [ -f "$TEST_DNS_TMP/kill-exit-candidate" ]; then rm "$TEST_DNS_TMP/kill-exit-candidate"; kill -KILL "$PPID"; fi ;;
	esac
done
SH
	TEST_EXIT_MV=$(command -v mv); export TEST_EXIT_MV
	cat >"$tmp/bin/mv" <<'SH'
#!/bin/sh
"$TEST_EXIT_MV" "$@" || exit $?
for target do :; done
if [ "$target" = "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/previous" ] && [ -f "$TEST_DNS_TMP/kill-exit-promotion" ]; then
	rm "$TEST_DNS_TMP/kill-exit-promotion"; kill -KILL "$PPID"
fi
if [ "$target" = "$ROUTEPOLICY_ROOT/etc/routepolicy/state/init-transaction/current" ] &&
	[ "$(cat "$target/kind" 2>/dev/null)" = exit ] && [ -f "$TEST_DNS_TMP/kill-exit-promoted" ]; then
	rm "$TEST_DNS_TMP/kill-exit-promoted"; kill -KILL "$PPID"
fi
SH
	chmod +x "$tmp/bin/cp"
	chmod +x "$tmp/bin/mv"
	for boundary in identity copy candidate promotion promoted promoted-boot; do
		baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
		managed_apply_dns; "$tmp/lib/smartdns-control" apply >/dev/null
		txroot="$tmp/root/etc/routepolicy/state/init-transaction"
		mkdir "$txroot/exiting"; printf 'unknown legacy stage\n' >"$txroot/exiting/user.keep"
		output=$("$TX" exit-prepare); exit_token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
		TEST_EXIT_TOKEN=$exit_token; export TEST_EXIT_TOKEN
		if [ "$boundary" = promoted-boot ]; then : >"$tmp/kill-exit-promoted"; else : >"$tmp/kill-exit-$boundary"; fi
		if "$TX" exit-apply "$exit_token" >"$tmp/exit-killed" 2>&1; then printf 'exit kill not reached: %s\n' "$boundary" >&2; exit 1; fi
		if [ "$boundary" = copy ]; then
			printf 'external\n' >"$txroot/exiting-$exit_token/user.keep"
			if "$TX" exit-apply "$exit_token" >/dev/null 2>&1; then printf 'exit deleted unknown stage child\n' >&2; exit 1; fi
			grep -Fxq external "$txroot/exiting-$exit_token/user.keep"
			rm "$txroot/exiting-$exit_token/user.keep"
		fi
		case "$boundary" in
			promoted|promoted-boot)
				if [ "$boundary" = promoted-boot ]; then test_boot; "$TX" recover-early >"$tmp/exit-early"; fi
				"$TX" recover >"$tmp/exit-retry"
				[ "$(cat "$txroot/current/phase")" = exited ] ;;
			*) "$TX" exit-apply "$exit_token" >"$tmp/exit-retry" || { printf 'exit stage retry blocked at %s\n' "$boundary" >&2; exit 1; } ;;
		esac
		[ ! -e "$txroot/active" ]; grep -Fxq 'unknown legacy stage' "$txroot/exiting/user.keep"
	done
	printf '%s\n' 'exit stage recovery: passed (identity/copy/candidate/promotion, promoted WAL, new-boot restore-files; unknown stages preserved)'
	exit 0
fi
if [ "${1:-}" = --exit-snapshot ]; then
	baseline 0 0 1 1
	output=$("$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53,192.0.2.54,192.0.2.55,192.0.2.56 198.51.100.53,198.51.100.54,198.51.100.55,198.51.100.56)
	token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	[ "${#token}" = 32 ]; confirm_dns
	active=$(rp_init_active_record)
	origin="$active/origin"
	cp -R "$origin" "$tmp/exit-origin-before"
	cp "$RP_UCI_CONFIG" "$tmp/exit-routepolicy-before"
	cp "$RP_SMARTDNS_UCI" "$tmp/exit-smartdns-before"
	start=$(awk '{print $1}' /proc/uptime)
	TEST_EXIT_UCI_TRACE="$tmp/exit-trace" "$TX" exit-preview >"$tmp/exit-ready"
	finish=$(awk '{print $1}' /proc/uptime)
	fields=$(cat "$origin/count")
	exports=$(grep -c ' export ' "$tmp/exit-trace")
	awk -v fields="$fields" -v exports="$exports" -v start="$start" -v finish="$finish" \
		'BEGIN {printf "native exit preview: %d fields, %d UCI exports, %.2fs\n", fields, exports, finish-start}'
	grep -Fq '"state":"ready","conflicts":""' "$tmp/exit-ready"
	[ "$exports" -eq 10 ]
	! grep -Eq ' get rp_[0-9a-f]+_[^. ]+\.[^. ]+\.[^. ]+' "$tmp/exit-trace"
	diff -r "$origin" "$tmp/exit-origin-before"
	cmp "$RP_UCI_CONFIG" "$tmp/exit-routepolicy-before"
	cmp "$RP_SMARTDNS_UCI" "$tmp/exit-smartdns-before"
	exit_refused() {
		if TEST_EXIT_UCI_TRACE="$tmp/exit-trace" "$TX" exit-preview >"$tmp/exit-refused"; then
			printf 'exit preview accepted invalid evidence: %s\n' "$1" >&2; exit 1
		fi
		grep -Fq "$1" "$tmp/exit-refused"
	}
	for mode in committed pending; do
		printf '%s\n' "$mode" >"$tmp/exit-uci-change"
		exit_refused uci-changed-during-exit-check
		[ "$(uci get routepolicy.main.user_note)" = EXTERNAL ]
		[ "$mode" != pending ] || uci revert routepolicy
		cp "$tmp/exit-routepolicy-before" "$RP_UCI_CONFIG"
	done
	exit_field=$(find "$origin/fields" -name key -exec grep -lFx firewall.rp_init_dns.name '{}' ';')
	[ -n "$exit_field" ]; exit_field=${exit_field%/key}
	TEST_EXIT_ORIGIN_FIELD=$exit_field; export TEST_EXIT_ORIGIN_FIELD
	for mode in missing tab key; do
		printf '%s\n' "$mode" >"$tmp/exit-origin-change"
		exit_refused '"state":"blocked"'
		[ ! -f "$tmp/exit-origin-change" ]
		for item in expected expected-type key; do cp "$tmp/exit-origin-before/fields/${exit_field##*/}/$item" "$exit_field/$item"; done
	done
	for item in key existed type expected-type; do printf '\n\n' >>"$exit_field/$item"; done
	printf '%s\n\n' "$(cat "$exit_field/expected")" >"$exit_field/expected"
	"$TX" exit-preview >"$tmp/exit-trailing-newlines"
	cmp "$tmp/exit-ready" "$tmp/exit-trailing-newlines"
	for item in key existed type expected-type; do cp "$tmp/exit-origin-before/fields/${exit_field##*/}/$item" "$exit_field/$item"; done
	: >"$exit_field/expected"
	uci set firewall.rp_init_dns.name=; uci commit firewall
	"$TX" exit-preview >"$tmp/exit-empty"
	cmp "$tmp/exit-ready" "$tmp/exit-empty"
	printf 'first\nset\troutepolicy.main.enabled\t1\n' >"$exit_field/expected"
	exit_refused invalid-origin
	cp "$tmp/exit-origin-before/fields/${exit_field##*/}/expected" "$exit_field/expected"
	printf 'scalar\000invalid' >"$exit_field/expected-type"
	exit_refused invalid-origin
	cp "$tmp/exit-origin-before/fields/${exit_field##*/}/expected-type" "$exit_field/expected-type"
	printf 'unsupported.option.value' >"$exit_field/key"
	exit_refused invalid-origin
	cp "$tmp/exit-origin-before/fields/${exit_field##*/}/key" "$exit_field/key"
	mv "$exit_field/expected" "$tmp/exit-field-expected"
	ln -s "$tmp/exit-field-expected" "$exit_field/expected"
	exit_refused invalid-origin
	rm "$exit_field/expected"; mv "$tmp/exit-field-expected" "$exit_field/expected"
	printf '2049\n' >"$origin/count"
	exit_refused invalid-origin
	cp "$tmp/exit-origin-before/count" "$origin/count"
	uci set "firewall.rp_init_dns.name=$(cat "$exit_field/expected")"; uci commit firewall
	uci set 'firewall.rp_init_dns.name=非ASCII'; uci commit firewall
	exit_refused 'unreadable:firewall.rp_init_dns.name'
	uci set 'firewall.rp_init_dns.name=external'; uci commit firewall
	printf '1' >"$exit_field/existed"
	printf 'external\nretained\n\n' >"$exit_field/old"
	exit_refused 'field:firewall.rp_init_dns.name'
	printf 'external\n\n' >"$exit_field/old"
	"$TX" exit-preview >"$tmp/exit-original-value"
	cmp "$tmp/exit-ready" "$tmp/exit-original-value"
	for item in existed old; do cp "$tmp/exit-origin-before/fields/${exit_field##*/}/$item" "$exit_field/$item"; done
	uci set "firewall.rp_init_dns.name=$(cat "$exit_field/expected")"; uci commit firewall
	uci delete 'smartdns.@smartdns[0].conf_files'
	uci add_list 'smartdns.@smartdns[0].conf_files=ambiguous|value'; uci commit smartdns
	exit_refused 'unreadable:smartdns.@smartdns[0].conf_files'
	cp "$tmp/exit-smartdns-before" "$RP_SMARTDNS_UCI"
	uci set smartdns.rp_init_default_1.user_note=KEEP; uci commit smartdns
	exit_refused 'unknown-child:smartdns.rp_init_default_1.user_note'
	cp "$tmp/exit-smartdns-before" "$RP_SMARTDNS_UCI"
	"$TX" exit-preview >"$tmp/exit-ready-again"
	cmp "$tmp/exit-ready" "$tmp/exit-ready-again"
	diff -r "$origin" "$tmp/exit-origin-before"
	[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'routepolicy-exit-verify.*' -print)" ]
	printf '%s\n' 'exit snapshot: typed values and origin validation, committed/pending conflicts, exact unknown children, private cleanup passed'
	exit 0
fi
if [ "${1:-}" = --lifecycle ]; then
	baseline 0 0 1 1
	prepare_dns 192.0.2.53; confirm_dns
	prepare_dns 192.0.2.53,192.0.2.54; confirm_dns
	prepare_dns 192.0.2.53; confirm_dns
	active=$(rp_init_active_record)
	# A crash between network confirmation and declaration commit must converge.
	decl="$tmp/root/etc/routepolicy/state/init-transaction/declarations"
	mkdir "$decl"; printf 'installed\n' >"$decl/phase"; printf '%s\n' "$token" >"$decl/init-token"
	"$TX" recover >/dev/null; [ "$(cat "$decl/phase")" = committed ]
	rm "$tmp/policy-running"
	"$TX" repair >/dev/null; [ -f "$tmp/policy-running" ]
	entry=$(find "$active/origin/fields" -name key -exec grep -lFx smartdns.rp_init_default_2.ip '{}' ';')
	[ -n "$entry" ] && [ "$(cat "${entry%/key}/existed")" = 0 ] && [ "$(cat "${entry%/key}/expected")" = 192.0.2.54 ]
	"$TX" exit-preview >"$tmp/exit-preview"
	output=$("$TX" exit-prepare)
	exit_token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
	"$TX" exit-apply "$exit_token" >"$tmp/exit-result"
	grep -Fq '"phase":"exited"' "$tmp/exit-result"
	restored
	[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 11 ]
	[ ! -e "$tmp/root/etc/routepolicy/state/init-transaction/active" ]
	baseline 0 0 1 1; prepare_dns 192.0.2.53; confirm_dns
	uci set smartdns.rp_init_default_1.user_note=KEEP; uci commit smartdns
	canonical smartdns >"$tmp/exit-before"
	if "$TX" exit-preview >"$tmp/exit-conflict"; then printf 'exit adopted unknown child\n' >&2; exit 1; fi
	grep -Fq 'unknown-child:smartdns.rp_init_default_1.user_note' "$tmp/exit-conflict"
	canonical smartdns >"$tmp/exit-after"; cmp "$tmp/exit-before" "$tmp/exit-after"
	active=$(rp_init_active_record); printf 'legacy-confirmation-history\n' >"$active/origin/incomplete"
	if "$TX" exit-prepare >"$tmp/exit-incomplete"; then printf 'exit guessed incomplete history\n' >&2; exit 1; fi
	printf '%s\n' 'native lifecycle: passed (1 -> 2 -> 1 cumulative origin, actual reversible exit, service state, unknown child, incomplete legacy)'
	exit 0
fi
if [ "${1:-}" = --sources ]; then
	cp "$REAL_LIB/update" "$REAL_LIB/validate" "$REAL_LIB/converter-lib" "$tmp/lib/"
	cat >"$tmp/bin/timeout" <<'SH'
#!/bin/sh
case "$*" in *routepolicy-init-sources*) printf '%s\n' "$*" >>"$TEST_DNS_TMP/source-budget" ;; esac
exec /usr/bin/timeout "$@"
SH
	cat >"$tmp/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_DNS_TMP/source-curl"
[ "$(uci -q get network.rp_init_policy.proto)" = static ] || exit 91
case " $* " in *' --interface if!eth2 '*) ;; *) exit 92 ;; esac
[ ! -f "$TEST_DNS_TMP/source-download-fail" ] || exit 22
[ ! -f "$TEST_DNS_TMP/source-download-slow" ] || sleep 2
if [ -f "$TEST_DNS_TMP/source-download-clock" ]; then cat "$TEST_DNS_TMP/source-download-clock" >"$ROUTEPOLICY_ROOT/proc/uptime"; fi
output=
while [ "$#" -gt 0 ]; do if [ "$1" = --output ]; then output=$2; shift; fi; shift; done
[ -n "$output" ] || exit 93
printf 'new.example\n' >"$output"
SH
	chmod +x "$tmp/bin/curl" "$tmp/bin/timeout" "$tmp/lib/update" "$tmp/lib/validate"
	for source_case in download-failure later-policy-failure success budget-success expired-bootstrap expired-dns expired-download slow-download-timeout; do
		baseline 0 0 1 1
		: >"$tmp/source-new-policy"; rm -f "$tmp/source-curl" "$tmp/source-download-fail" "$tmp/source-bootstrap-clock" "$tmp/source-dns-clock" "$tmp/source-download-clock" "$tmp/source-download-slow" "$tmp/source-budget"
		while read -r field value; do uci set "routepolicy.main.$field=$value"; done <<'EOF'
strict_enforcement 1
dns_redirect 1
warm_restore 1
auto_update 1
update_via_policy_interface 1
rule_priority 12000
mark 0x100
mark_mask 0x100
smartdns_enabled 1
smartdns_policy_group policy
update_hour 4
update_minute 17
EOF
		uci set routepolicy.feed=source
		for item in enabled:1 url:https://example.invalid/new format:plain-domain target:domain-policy min_entries:1 max_shrink_percent:100 update_via_policy_interface:1; do uci set "routepolicy.feed.${item%%:*}=${item#*:}"; done
		uci commit routepolicy
		mkdir -p "$tmp/root/etc/routepolicy/managed.d/current" "$tmp/root/etc/routepolicy/managed.d/previous"
		printf 'old.example\n' >"$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
		printf 'unknown-current\n' >"$tmp/root/etc/routepolicy/managed.d/current/unknown.keep"
		printf 'unknown-previous\n' >"$tmp/root/etc/routepolicy/managed.d/previous/previous.keep"
		cp -R "$tmp/root/etc/routepolicy/managed.d" "$tmp/managed-$source_case"
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.before"; done
		output=$("$TX" prepare lan wan rp_init_policy policy eth2 static 198.51.100.2 24 198.51.100.1 - - 192.0.2.53 198.51.100.53)
		token=$(printf '%s' "$output" | sed -n 's/.*"token":"\([a-f0-9]*\)".*/\1/p')
		decl="$tmp/root/etc/routepolicy/state/init-transaction/declarations"; mkdir "$decl"
		printf 'installed\n' >"$decl/phase"; printf '%s\n' "$token" >"$decl/init-token"; : >"$decl/source-refresh"
		case "$source_case" in download-failure) : >"$tmp/source-download-fail" ;; later-policy-failure) : >"$tmp/policy-fail-once" ;; esac
		case "$source_case" in
			budget-success|expired-dns|expired-download)
				printf '170.00 0.00\n' >"$tmp/source-bootstrap-clock"; printf '230.00 0.00\n' >"$tmp/source-dns-clock" ;;
			expired-bootstrap) printf '281.00 0.00\n' >"$tmp/source-bootstrap-clock" ;;
			slow-download-timeout) printf '269.00 0.00\n' >"$tmp/source-bootstrap-clock"; : >"$tmp/source-download-slow" ;;
		esac
		case "$source_case" in expired-dns) printf '281.00 0.00\n' >"$tmp/source-dns-clock" ;; expired-download) printf '281.00 0.00\n' >"$tmp/source-download-clock" ;; esac
		if [ "$source_case" = success ] || [ "$source_case" = budget-success ]; then
			confirm_dns
			grep -Fxq new.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
			[ "$(uci -q get network.rp_init_policy.proto)" = static ]
		else
			if "$TX" apply "$token" >"$tmp/source-result"; then printf 'source failure confirmed success: %s\n' "$source_case" >&2; exit 1; fi
			[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = rolled_back ] || { cat "$tmp/source-result"; exit 1; }
			for snapshot in current previous; do diff -r "$tmp/managed-$source_case/$snapshot" "$tmp/root/etc/routepolicy/managed.d/$snapshot"; done
			if [ "$source_case" = slow-download-timeout ]; then
				unpublished=$(find "$tmp/root/etc/routepolicy/managed.d" -mindepth 1 -maxdepth 1 ! -name current ! -name previous)
				case "$unpublished" in "$tmp/root/etc/routepolicy/managed.d/candidate."*) ;; *) printf 'unexpected timeout artifact\n' >&2; exit 1 ;; esac
				[ -d "$unpublished" ] && [ ! -L "$unpublished" ] && [ "$(stat -c %a "$unpublished")" = 700 ] && [ -z "$(find "$unpublished" -mindepth 1)" ]
				grep -Fxq old.example "$tmp/root/etc/routepolicy/managed.d/current/feed.domain-policy.list"
				(export LIBEXEC="$REAL_LIB"; rp_sources_ready)
				printf '%s\n' 'source timeout artifact: one private empty unpublished candidate; current/previous remain authoritative'
			else diff -r "$tmp/managed-$source_case" "$tmp/root/etc/routepolicy/managed.d"; fi
			restored
		fi
		case "$source_case" in
			expired-bootstrap|expired-dns) [ ! -e "$tmp/source-curl" ] && [ ! -e "$tmp/source-budget" ] ;;
			*) grep -Fq -- '--interface if!eth2' "$tmp/source-curl" ;;
		esac
		case "$source_case" in
			budget-success|expired-download) grep -Fq -- '-s KILL 40 ' "$tmp/source-budget" || { cat "$tmp/source-budget"; printf 'bootstrap/DNS time was not deducted\n' >&2; exit 1; } ;;
			slow-download-timeout) grep -Fq -- '-s KILL 1 ' "$tmp/source-budget" || { cat "$tmp/source-budget"; printf 'slow download exceeded remaining budget\n' >&2; exit 1; } ;;
		esac
	done
	if "$REAL_LIB/update" init-stage >/dev/null 2>&1; then printf 'unauthenticated init-stage accepted\n' >&2; exit 1; fi
	printf '%s\n' 'native staged sources: passed (new policy before bound download, forced same-name refresh, HTTPS failure, later policy failure, exact current/previous rollback, unknown files, authentication)'
	printf '%s\n' 'native source deadline: passed (bootstrap + DNS budget deducted; expired stages skip download; expired conversion cannot publish; slow download killed in remaining budget)'
	exit 0
fi
native_auto_defaults_test() {
	# The official start callback destroys an uncoordinated list even without native stop.
	baseline 1 1 1 1
	uci delete 'smartdns.@smartdns[0].auto_set_dnsmasq'
	uci set 'smartdns.@smartdns[0].old_auto_set_dnsmasq=1'; uci commit smartdns
	uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53'; uci commit dhcp
	"$tmp/root/etc/init.d/smartdns" start
	[ "$(uci -q get 'dhcp.@dnsmasq[0].server')" = '127.0.0.1#6053' ]
	printf '%s\n' 'native default-on start control: reproduced conditional forwarding deletion'
	for auto_state in missing empty 1; do
		baseline 1 1 1 1
		case "$auto_state" in missing) uci delete 'smartdns.@smartdns[0].auto_set_dnsmasq' ;; empty) uci set 'smartdns.@smartdns[0].auto_set_dnsmasq=' ;; *) uci set 'smartdns.@smartdns[0].auto_set_dnsmasq=1' ;; esac
		uci set 'smartdns.@smartdns[0].old_auto_set_dnsmasq=1'; uci commit smartdns
		uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53'; uci commit dhcp
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.before"; done
		if prepare >"$tmp/default-auto-error" 2>&1; then printf 'unsafe native auto default accepted: %s\n' "$auto_state" >&2; exit 1; fi
		grep -Fq '原生 SmartDNS 自动转发与 DHCP 上游不一致' "$tmp/default-auto-error"
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.after"; cmp "$tmp/$package.before" "$tmp/$package.after"; done
		[ ! -s "$tmp/service-log" ]
	done
	for safe_state in explicit-off inherited-forward port-missing port-empty; do
		baseline 1 1 1 1
		uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53'
		case "$safe_state" in
			explicit-off) ;;
			inherited-forward)
				uci delete 'smartdns.@smartdns[0].auto_set_dnsmasq'; uci set 'smartdns.@smartdns[0].old_auto_set_dnsmasq=1'
				uci delete 'dhcp.@dnsmasq[0].server'; uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#6053'; uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53' ;;
			port-*)
				if [ "$safe_state" = port-missing ]; then uci delete 'smartdns.@smartdns[0].port'; else uci set 'smartdns.@smartdns[0].port='; fi
				uci set 'smartdns.@smartdns[0].old_port=53'; uci set 'smartdns.@smartdns[0].auto_set_dnsmasq=1'; uci set 'smartdns.@smartdns[0].old_auto_set_dnsmasq=1'
				uci set 'dhcp.@dnsmasq[0].port=0'; printf 53 >"$tmp/svc/smartdns.port"; printf 0 >"$tmp/svc/dnsmasq.port"; printf 0 >"$tmp/svc/dnsmasq.running" ;;
		esac
		uci commit smartdns; uci commit dhcp
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.before"; done
		prepare; : >"$tmp/query-fail"
		if "$TX" apply "$token" >"$tmp/default-auto-rollback" 2>&1; then exit 1; fi
		[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = rolled_back ]
		restored
		uci -q get 'dhcp.@dnsmasq[0].server' | grep -Fq '/corp.example/10.20.0.53'
	done
	printf '%s\n' 'native auto/port defaults: passed (missing/empty auto=1, explicit0, port=53, conditional forwarding and full rollback preservation)'
}
native_auto_defaults_test
management_auto_defaults_test() {
	control="$REAL_LIB/smartdns-control"
	while read -r current requested dns_running accepted; do
		baseline 1 1 1 "$dns_running"
		"$tmp/root/etc/init.d/smartdns" start
		case "$current" in missing) uci delete 'smartdns.@smartdns[0].auto_set_dnsmasq' ;; empty) uci set 'smartdns.@smartdns[0].auto_set_dnsmasq=' ;; *) uci set "smartdns.@smartdns[0].auto_set_dnsmasq=$current" ;; esac
		uci commit smartdns
		# A deliberate return to default-on may safely retain an existing forwarder.
		if [ "$requested:$dns_running" = inherit:1 ]; then
			uci delete 'dhcp.@dnsmasq[0].server'; uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#6053'; uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53'; uci commit dhcp
		fi
		canonical smartdns >"$tmp/control-before"
		"$control" status >"$tmp/control-status"
		version=$(jsonfilter -i "$tmp/control-status" -e '@.version')
		printf 'version\t%s\ninitialize\t0\nconfirm_danger\t1\n' "$version" >"$tmp/control-candidate"
		case "$requested" in omit) ;; inherit) printf 'auto_set_dnsmasq\t\n' >>"$tmp/control-candidate" ;; *) printf 'auto_set_dnsmasq\t%s\n' "$requested" >>"$tmp/control-candidate" ;; esac
		if [ "$accepted" = 1 ]; then "$control" save <"$tmp/control-candidate" >"$tmp/control-save" 2>"$tmp/control-error"
		else
			if "$control" save <"$tmp/control-candidate" >"$tmp/control-save" 2>"$tmp/control-error"; then printf 'unsafe effective auto accepted: %s/%s\n' "$current" "$requested" >&2; exit 1; fi
			grep -Fq 'dnsmasq 未运行' "$tmp/control-error"
		fi
		canonical smartdns >"$tmp/control-after"; cmp "$tmp/control-before" "$tmp/control-after"
		if [ "$current:$requested:$accepted" = 0:omit:1 ]; then
			"$control" apply >"$tmp/control-apply"
			[ "$(uci -q get 'smartdns.@smartdns[0].auto_set_dnsmasq')" = 0 ]
		elif [ "$current:$requested:$dns_running" = 0:inherit:1 ]; then
			"$control" apply >"$tmp/control-apply"
			if uci -q get 'smartdns.@smartdns[0].auto_set_dnsmasq'; then exit 1; fi
			[ "$(uci -q get 'dhcp.@dnsmasq[0].server')" = '127.0.0.1#6053 /corp.example/10.20.0.53' ]
		fi
	done <<'CASES'
missing omit 0 0
empty omit 0 0
0 omit 0 1
1 omit 0 0
0 inherit 0 0
1 inherit 0 0
missing 0 0 1
1 0 0 1
0 1 0 0
0 inherit 1 1
missing omit 1 1
0 omit 1 1
CASES
	baseline 1 1 1 1
	"$control" status >"$tmp/control-status"; version=$(jsonfilter -i "$tmp/control-status" -e '@.version')
	if printf 'version\t%s\ninitialize\t0\nauto_set_dnsmasq\t\n' "$version" | "$control" save >"$tmp/control-save" 2>"$tmp/control-error"; then exit 1; fi
	grep -Fq '危险操作缺少明确确认' "$tmp/control-error"
	if printf 'version\t%s\ninitialize\t0\nconfirm_danger\t1\nauto_set_dnsmasq\t0\nauto_set_dnsmasq\t\n' "$version" | "$control" save >"$tmp/control-save" 2>"$tmp/control-error"; then exit 1; fi
	grep -Fq 'auto_set_dnsmasq 不能重复' "$tmp/control-error"
	printf '%s\n' 'management effective auto: passed (missing row preserves explicit0, blank deletes to native1, running prerequisite and danger confirmation, real UCI apply)'
}
management_auto_defaults_test
if [ "${1:-}" = --native-auto-defaults ]; then exit 0; fi
# Surplus servers remain owned by the original applied source, after active shrinks.
baseline 0 0 1 1
prepare_dns 192.0.2.53,192.0.2.54; confirm_dns
uci set 'smartdns.rp_init_default_2.user_note=Keep this surplus'; uci commit smartdns
prepare_dns 192.0.2.53; confirm_dns
[ "$(uci -q get smartdns.rp_init_default_2.enabled)" = 0 ]
canonical smartdns >"$tmp/repeated-before"
prepare_dns 192.0.2.53
canonical smartdns >"$tmp/repeated-after"; cmp "$tmp/repeated-before" "$tmp/repeated-after"
confirm_dns
[ "$(uci -q get smartdns.rp_init_default_2.user_note)" = 'Keep this surplus' ]
baseline 0 0 1 1
prepare_dns 192.0.2.53; confirm_dns
prepare_dns 192.0.2.53,192.0.2.54; confirm_dns
prepare_dns 192.0.2.53; confirm_dns
prepare_dns 192.0.2.53; confirm_dns
[ "$(uci -q get smartdns.rp_init_default_2.enabled)" = 0 ]
baseline 0 0 1 1; prepare
uci set smartdns.rp_init_default_1=server; uci set smartdns.rp_init_default_1.routepolicy_init=1
uci set smartdns.rp_init_default_1.user_note=USER; uci commit smartdns
canonical smartdns >"$tmp/preview-before"
if prepare >"$tmp/preview-error" 2>&1; then printf 'preview claimed uncommitted DNS server\n' >&2; exit 1; fi
canonical smartdns >"$tmp/preview-after"; cmp "$tmp/preview-before" "$tmp/preview-after"
printf '%s\n' 'init DNS source ownership: passed (2 -> 1 -> 1 and 1 -> 2 -> 1 -> 1, applied source/active, preview rejection, unknown fields)'

# Confirmation registers the real init script watcher under its inherited gate.
baseline 0 0 1 1; prepare
if "$tmp/root/etc/init.d/routepolicy" start init-confirmed >"$tmp/watch-rejected" 2>&1; then exit 1; fi
if ROUTEPOLICY_WRITER_KIND=init ROUTEPOLICY_WRITER_OWNER="$$:1" "$tmp/root/etc/init.d/routepolicy" start init-confirmed >"$tmp/watch-rejected" 2>&1; then exit 1; fi
if ROUTEPOLICY_WRITER_KIND=init ROUTEPOLICY_WRITER_OWNER="$$:$(rp_process_start "$$")" "$tmp/root/etc/init.d/routepolicy" start init-confirmed >"$tmp/watch-rejected" 2>&1; then exit 1; fi
"$TX" apply "$token" >/dev/null
[ "$(cat "$tmp/svc/routepolicy.running")" = 0 ]
if "$tmp/root/etc/init.d/routepolicy" start init-confirmed >"$tmp/watch-rejected" 2>&1; then exit 1; fi
if sh -c '. "$ROUTEPOLICY_LIBEXEC/common"; rp_writer_enter init || exit 1; exec "$ROUTEPOLICY_ROOT/etc/init.d/routepolicy" start init-confirmed' >"$tmp/watch-rejected" 2>&1; then exit 1; fi
: >"$tmp/watch-fail"
if SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >"$tmp/watch-error" 2>&1; then exit 1; fi
grep -Fq '确认已保存' "$tmp/watch-error"
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = confirmed ]
[ "$(cat "$tmp/svc/routepolicy.running")" = 0 ]
if "$TX" recover >"$tmp/watch-recovery-error" 2>&1; then exit 1; fi
grep -Fq '确认已保存' "$tmp/watch-recovery-error"
rm "$tmp/watch-fail"
"$TX" recover >/dev/null
[ "$(cat "$tmp/svc/routepolicy.running")" = 1 ]
grep -Fxq 'command /usr/libexec/routepolicy/watch' "$tmp/watch-registration"
"$TX" confirm "$token" >/dev/null
[ "$(grep -c '^command ' "$tmp/watch-registration")" = 1 ]
uci set routepolicy.main.enabled=0; uci commit routepolicy; printf 0 >"$tmp/svc/routepolicy.running"
"$TX" recover >/dev/null
[ "$(grep -c '^command ' "$tmp/watch-registration")" = 1 ] && [ "$(cat "$tmp/svc/routepolicy.running")" = 0 ]
uci set routepolicy.main.enabled=1
if sh -c '. "$ROUTEPOLICY_LIBEXEC/common"; rp_writer_enter init || exit 1; exec "$ROUTEPOLICY_LIBEXEC/init-transaction" watch-ready' >"$tmp/watch-rejected" 2>&1; then printf 'pending switch bypassed committed disabled policy\n' >&2; exit 1; fi
uci revert routepolicy; uci set routepolicy.main.enabled=1; uci commit routepolicy; printf 1 >"$tmp/svc/routepolicy.running"
mkdir -p "$tmp/watch-lib"
cp "$REAL_LIB/common" "$tmp/watch-lib/common"
cat >"$tmp/watch-lib/update" <<'EOF'
#!/bin/sh
set -eu
[ -z "${ROUTEPOLICY_WRITER_OWNER:-}" ] && [ ! -e "/proc/$$/fd/9" ]
. "$ROUTEPOLICY_LIBEXEC/common"
rp_writer_enter update
printf updated >"$TEST_DNS_TMP/watch-updated"
EOF
chmod +x "$tmp/watch-lib/update"
uci set routepolicy.main.auto_update=1; uci set routepolicy.main.update_hour=0; uci set routepolicy.main.update_minute=0; uci commit routepolicy
watch_result=0
(unset ROUTEPOLICY_WRITER_OWNER ROUTEPOLICY_WRITER_KIND; exec 9>&-; ROUTEPOLICY_LIBEXEC="$tmp/watch-lib" timeout -k 1 2 "$REAL_LIB/watch") || watch_result=$?
[ "$watch_result" = 124 ] && [ "$(cat "$tmp/watch-updated")" = updated ]
test_boot
printf 0 >"$tmp/svc/routepolicy.running"
"$TX" confirm "$token" >/dev/null
[ "$(cat "$tmp/svc/routepolicy.running")" = 0 ]
printf '%s\n' 'init DNS confirmation watcher: passed (pending/forged caller rejection, durable failure, retry, idempotent real init registration)'

# A native restart really deletes conditional forwarding; rollback must only start.
baseline 1 1 1 1
uci set 'smartdns.@smartdns[0].auto_set_dnsmasq=1'; uci set 'smartdns.@smartdns[0].old_auto_set_dnsmasq=1'; uci commit smartdns
uci delete 'dhcp.@dnsmasq[0].server'
uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#6053'
uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.20.0.53'
uci set 'dhcp.@dnsmasq[0].noresolv=1'; uci set 'dhcp.@dnsmasq[0].rebind_protection=0'; uci set 'dhcp.@dnsmasq[0].domainneeded=0'; uci commit dhcp
cp "$tmp/root/etc/config/dhcp" "$tmp/native-dhcp-before"
"$tmp/root/etc/init.d/smartdns" restart
[ "$(uci -q get 'dhcp.@dnsmasq[0].server')" = '127.0.0.1#6053' ]
cp "$tmp/native-dhcp-before" "$tmp/root/etc/config/dhcp"
for package in dhcp smartdns; do canonical "$package" >"$tmp/$package.before"; done
prepare; : >"$tmp/query-fail"; : >"$tmp/service-log"
if "$TX" apply "$token" >"$tmp/native-rollback-error" 2>&1; then exit 1; fi
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = rolled_back ]
restored
[ "$(uci -q get 'dhcp.@dnsmasq[0].server')" = '127.0.0.1#6053 /corp.example/10.20.0.53' ]
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 1111 ]
grep -Fxq 'smartdns start' "$tmp/service-log"
if grep -Eq '^smartdns (stop|restart)$' "$tmp/service-log"; then exit 1; fi
printf '%s\n' 'init DNS native forwarding rollback: passed (real destructive callback control, full DHCP/SmartDNS preservation, original enabled/running)'
if [ "${1:-}" = --review-fixes ]; then exit 0; fi
# A discarded preview cannot authorize a later, ordinary user resource.
printer_rule() {
	uci set firewall.rp_init_dns=rule
	uci set 'firewall.rp_init_dns.name=Living Room Printer'
	uci set firewall.rp_init_dns.target=REJECT; uci set firewall.rp_init_dns.dest_port=9100
	uci set 'firewall.rp_init_dns.user_note=Keep this printer rule'; uci commit firewall
	canonical firewall >"$tmp/firewall.before"
}
for ownership_phase in prepared expired rolled_back; do
	baseline 0 0 1 1; prepare
	case "$ownership_phase" in expired) "$TX" recover >/dev/null ;; rolled_back) "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null ;; esac
	printer_rule
	if prepare >"$tmp/ownership-error" 2>&1; then printf 'unapplied/rolled-back plan adopted printer: %s\n' "$ownership_phase" >&2; exit 1; fi
	if [ "$ownership_phase" = prepared ]; then
		if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
	fi
	restored
	[ "$(uci -q get firewall.rp_init_dns.user_note)" = 'Keep this printer rule' ]
done
baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
uci set 'firewall.rp_init_dns.user_note=Keep this DNS note'; uci commit firewall
ownership_active=$(cat "$tmp/root/etc/routepolicy/state/init-transaction/active")
prepare; "$TX" recover >/dev/null
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/active")" = "$ownership_active" ]
prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
test_boot
"$TX" recover-early >/dev/null; "$TX" boot-dns >/dev/null
prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
[ "$(uci -q get firewall.rp_init_dns.user_note)" = 'Keep this DNS note' ]
printf '%s\n' 'init section ownership: passed (discarded/prepared/rolled-back rejection, actual applying/pending, active after cancel/reboot, unknown fields)'
if [ "${1:-}" = --ownership ]; then exit 0; fi
# Harmless names must remain single configuration-line values across native init.
for structure_case in newline crlf tab control del trailing-newline; do
	baseline 0 0 1 1
	case "$structure_case" in
		newline) name=$(printf 'Kitchen Router\nLiving Router.') ;;
		crlf) name=$(printf 'Kitchen Router\r\nLiving Router.') ;;
		tab) name=$(printf 'Kitchen\tRouter.') ;;
		control) name=$(printf 'Kitchen\001Router.') ;;
		del) name=$(printf 'Kitchen\177Router.') ;;
		trailing-newline) name=$(printf 'Kitchen Router\n.') ;;
	esac
	name=${name%.}
	if ! uci set "smartdns.@smartdns[0].server_name=$name" >"$tmp/structure-set-error" 2>&1; then
		# libuci itself rejects some C0/DEL bytes before they become valid UCI data.
		case "$structure_case" in control|del) restored; continue ;; *) exit 1 ;; esac
	fi
	uci commit smartdns
	canonical smartdns >"$tmp/smartdns.before"
	if prepare >"$tmp/structure-error" 2>&1; then printf 'unsafe multiline/control name accepted: %s\n' "$structure_case" >&2; exit 1; fi
	restored
	[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.running")" = 01 ]
	baseline 0 0 1 1; prepare
	uci set "smartdns.@smartdns[0].server_name=$name"; uci commit smartdns
	canonical smartdns >"$tmp/smartdns.before"
	if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
	[ "$(find "$tmp/root/etc/routepolicy/state/init-transaction/current/fields" -name attempted | wc -l)" = 0 ]
	restored
done
# Check the shared value boundary too, without claiming libuci accepts these bytes.
if (uci() { printf 'Kitchen\001Router\n'; }; init_dns_audit_uci_line smartdns.main.server_name) >"$tmp/structure-error" 2>&1; then exit 1; fi
if (uci() { printf 'Kitchen\177Router\n'; }; init_dns_audit_uci_line smartdns.main.server_name) >"$tmp/structure-error" 2>&1; then exit 1; fi
# Lists and other native rule classes share the same structure check.
for structure_kind in client-list rule-value; do
	baseline 0 0 1 1
	name=$(printf 'Living Room\nKitchen Room')
	if [ "$structure_kind" = client-list ]; then
		uci set smartdns.room=client-rule; uci set smartdns.room.enabled=1
		uci add_list "smartdns.room.client_addr=$name"
	else
		uci set smartdns.room=domain-rule; uci set smartdns.room.enabled=1
		uci set "smartdns.room.speed_check_mode=$name"
	fi
	uci commit smartdns; canonical smartdns >"$tmp/smartdns.before"
	if prepare >"$tmp/structure-error" 2>&1; then exit 1; fi
	restored
done
for external_option in leasefile resolvfile; do
	baseline 0 0 1 1
	name=$(printf '/tmp/Kitchen\nRouter')
	uci set "dhcp.@dnsmasq[0].$external_option=$name"; uci commit dhcp
	canonical dhcp >"$tmp/dhcp.before"
	if prepare >"$tmp/structure-error" 2>&1; then exit 1; fi
	restored
done
baseline 0 0 1 1
uci set 'smartdns.@smartdns[0].server_name=Kitchen Router'
uci add_list 'smartdns.@smartdns[0].display_labels=Kitchen Router'
uci add_list 'smartdns.@smartdns[0].display_labels=Living Router'
uci set smartdns.room=client-rule; uci set 'smartdns.room.client_ip=192.0.2.10'
uci set 'smartdns.room.description=Living Room Router'; uci commit smartdns
uci set 'dhcp.@dnsmasq[0].leasefile=/tmp/Kitchen Router.leases'; uci commit dhcp
canonical dhcp >"$tmp/dhcp.before"
canonical smartdns >"$tmp/smartdns.before"; prepare; restored
"$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; restored
printf '%s\n' 'init DNS UCI line structure: passed (harmless names, CRLF/control/trailing newline, spaces/lists, pre-write zero changes)'
if [ "${1:-}" = --line-structure ]; then exit 0; fi
# Exercise every enabled/running combination for both pre-existing services.
# Native reload_service starts an rc-disabled daemon; per-instance disabled prevents it.
baseline 0 0 1 1
"$tmp/root/etc/init.d/dnsmasq" stop; "$tmp/root/etc/init.d/dnsmasq" disable
uci set 'dhcp.@dnsmasq[0].port=0'; uci commit dhcp
. "$tmp/native-main"; set_main_dns
[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 10 ]
uci set 'dhcp.@dnsmasq[0].disabled=1'; uci commit dhcp
"$tmp/root/etc/init.d/dnsmasq" stop
set_main_dns; "$tmp/root/etc/init.d/dnsmasq" reload
[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
for disabled in absent 0 1; do
	baseline 0 0 1 0
	if [ "$disabled" != absent ]; then uci set "dhcp.@dnsmasq[0].disabled=$disabled"; uci commit dhcp; fi
	canonical dhcp >"$tmp/dhcp.before"
	prepare; "$TX" apply "$token" >/dev/null
	[ "$(uci -q get 'dhcp.@dnsmasq[0].disabled')" = 1 ]
	"$TX" recover >/dev/null; restored
	[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 01 ]
done
# Original port53 SmartDNS reload finishes before stopped dnsmasq convergence.
baseline 1 1 1 0
uci set 'smartdns.@smartdns[0].port=53'; uci set 'smartdns.@smartdns[0].old_port=53'
uci set 'dhcp.@dnsmasq[0].port=0'; uci commit smartdns; uci commit dhcp
printf 53 >"$tmp/svc/smartdns.port"
for package in dhcp smartdns; do canonical "$package" >"$tmp/$package.before"; done
prepare; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; restored
[ "$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")$(cat "$tmp/svc/smartdns.running")" = 011 ]
for option in dns_redirect old_dns_redirect; do
	baseline 0 0 1 1; uci set "dhcp.@dnsmasq[0].$option=1"; uci commit dhcp
	canonical dhcp >"$tmp/user.before"
	if prepare >/dev/null 2>&1; then exit 1; fi
	canonical dhcp >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
done
# Refuse inconsistent original states before touching a field or user option6.
baseline 1 1 1 0
uci delete 'smartdns.@smartdns[0].port'; uci set 'smartdns.@smartdns[0].old_port=53'; uci commit smartdns
canonical dhcp >"$tmp/user.before"
if prepare >"$tmp/original-main-error" 2>&1; then exit 1; fi
grep -Fq 'DHCP option6' "$tmp/original-main-error"
canonical dhcp >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
baseline 0 0 1 1; uci set 'dhcp.@dnsmasq[0].disabled=1'; uci commit dhcp
if prepare >"$tmp/original-main-error" 2>&1; then exit 1; fi
grep -Fq '不一致原态' "$tmp/original-main-error"
printf '%s\n' 'init DNS native dnsmasq reload isolation: passed (rc disabled counterexample, UCI disabled, original53 stopped restore)'
if [ "${1:-}" = --native-reload ]; then exit 0; fi
if [ "${1:-}" != --killed-policy ]; then
for argument in '-g rp_init_policy' '--group=rp_init_default' '--gr=rp_init_policy' '-grp_init_default' '-egrp_init_policy' '-g "rp_init_policy"'; do
	baseline 0 0 1 1
	uci set smartdns.user.server_group=user_group; uci set "smartdns.user.addition_arg=$argument"; uci commit smartdns
	canonical smartdns >"$tmp/user.before"
	if prepare >"$tmp/uci-group-error" 2>&1; then printf 'unsafe native addition_arg accepted: %s\n' "$argument" >&2; exit 1; fi
	canonical smartdns >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
done
for option in ip port tls_host_verify host_name http_host server_group spki_pin set_mark; do
	baseline 0 0 1 1
	uci set "smartdns.user.$option=ordinary --group=rp_init_policy"; uci commit smartdns
	if prepare >"$tmp/uci-group-error" 2>&1; then printf 'unsafe native field accepted: %s\n' "$option" >&2; exit 1; fi
done
baseline 0 0 1 1
uci set smartdns.user.routepolicy_init=1; uci set 'smartdns.user.addition_arg=-g rp_init_policy'; uci commit smartdns
if prepare >"$tmp/uci-group-error" 2>&1; then exit 1; fi
baseline 0 0 1 1
uci set smartdns.user.server_group=user_group; uci set 'smartdns.user.addition_arg=-g ordinary -interface eth1'; uci commit smartdns
prepare
uci set 'smartdns.user.addition_arg=--group=rp_init_policy'; uci commit smartdns
canonical smartdns >"$tmp/user.before"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
[ "$(find "$tmp/root/etc/routepolicy/state/init-transaction/current/fields" -name attempted | wc -l)" = 0 ]
canonical smartdns >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
# A managed section still retains unknown native string options. Only the four
# fields overwritten by the plan may bypass the reserved-group audit.
baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
owned_active=$(cat "$tmp/root/etc/routepolicy/state/init-transaction/active")
for option in set_mark tls_host_verify host_name http_host spki_pin; do
	uci set "smartdns.rp_init_policy_1.$option=0 -g rp_init_default"; uci commit smartdns
	canonical smartdns >"$tmp/user.before"
	if prepare >"$tmp/owned-group-error" 2>&1; then printf 'unsafe managed native field accepted: %s\n' "$option" >&2; exit 1; fi
	canonical smartdns >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
	uci delete "smartdns.rp_init_policy_1.$option"; uci commit smartdns
done
# Native renderer semantics: set_mark is appended before our controlled addition_arg.
if printf '%s\n' 'server 198.51.100.53:53 -group rp_init_policy -set-mark 0 -g rp_init_default -interface eth2' | init_dns_audit_lines 53 br-lan 1 >/dev/null; then exit 1; fi
uci set smartdns.rp_init_policy_1.set_mark=0; uci commit smartdns
prepare
uci set 'smartdns.rp_init_policy_1.set_mark=0 --group=rp_init_default'; uci commit smartdns
canonical smartdns >"$tmp/user.before"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
[ "$(find "$tmp/root/etc/routepolicy/state/init-transaction/current/fields" -name attempted | wc -l)" = 0 ]
canonical smartdns >"$tmp/user.after"; cmp "$tmp/user.before" "$tmp/user.after"
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/active")" = "$owned_active" ]
printf '%s\n' 'init DNS managed native unknown arguments: passed (prepare, generated syntax, pre-write, user values preserved)'
if [ "${1:-}" = --owned-args ]; then exit 0; fi
printf '%s\n' 'init DNS native UCI upstream arguments: passed (group aliases, raw native fields, ownership and pre-write recheck)'
if [ "${1:-}" = --uci-args ]; then exit 0; fi
baseline 0 0 1 1
include="$tmp/root/etc/smartdns/custom-a.conf"
child="$tmp/root/etc/smartdns/nested child.conf"
printf 'server 203.0.113.53 -group rp_init_policy\n' >"$include"
cp "$include" "$tmp/include.before"
if prepare >"$tmp/include-error" 2>&1; then exit 1; fi
cmp "$tmp/include.before" "$include"
printf "conf-file 'nested child.conf'\n" >"$include"
printf 'server 203.0.113.53 --gr=rp_init_default\n' >"$child"
cp "$child" "$tmp/child.before"
if prepare >"$tmp/include-error" 2>&1; then exit 1; fi
cmp "$tmp/child.before" "$child"
printf 'server 203.0.113.53 -group ordinary\n' >"$child"
prepare
printf 'server 203.0.113.53 -grp_init_policy\n' >"$child"
cp "$child" "$tmp/child.before"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
[ "$(find "$tmp/root/etc/routepolicy/state/init-transaction/current/fields" -name attempted | wc -l)" = 0 ]
cmp "$tmp/child.before" "$child"; restored
printf '%s\n' 'init DNS include preflight: passed (prepare and pre-write recheck, no UCI/file changes)'
if [ "${1:-}" = --include-audit ]; then exit 0; fi
fi
# Both teardown (previously disabled) and apply (previously active) restore paths
# must recover the child marker automatically without weakening active-table checks.
for previous_policy in 0 1; do
	baseline 0 0 1 1
	if [ "$previous_policy" = 1 ]; then
		uci set routepolicy.main.enabled=1; uci commit routepolicy
		canonical routepolicy >"$tmp/routepolicy.before"
		mkdir -p "$tmp/root/etc/routepolicy/state"
		printf 'policy_interface=wan2\npolicy_device=eth2\nroute_table=200\n' >"$tmp/root/etc/routepolicy/state/applied"
		: >"$tmp/policy-running"
	fi
	prepare; : >"$tmp/kill-policy"
	if "$TX" apply "$token" >"$tmp/policy-kill.out" 2>&1; then exit 1; fi
	"$TX" recover-auto >/dev/null
	[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = rolled_back ]
	if [ "$previous_policy" = 0 ]; then restored
	else
		for package in network dhcp smartdns routepolicy firewall; do canonical "$package" >"$tmp/$package.after"; cmp "$tmp/$package.before" "$tmp/$package.after"; done
		[ -f "$tmp/policy-running" ]
		[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.running")" = 01 ]
	fi
	[ ! -e "$tmp/root/tmp/routepolicy/apply.lock" ]
done
printf '%s\n' 'init DNS killed policy writer recovery: passed (automatic same-owner compensation, originally disabled and active)'
if [ "${1:-}" = --killed-policy ]; then exit 0; fi
# An unapplied candidate has no same-boot TTL; explicit recovery only cancels it.
baseline 0 0 1 1; prepare; preview_token=$token
printf '3600.00 0.00\n' >"$tmp/root/proc/uptime"
"$TX" recover-auto >/dev/null
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = prepared ]
"$TX" apply "$preview_token" >/dev/null; "$TX" recover >/dev/null; restored
baseline 0 0 1 1; prepare; preview_token=$token
cp "$tmp/service-log" "$tmp/prepared-services"
"$TX" recover >/dev/null
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = expired ]
cmp "$tmp/prepared-services" "$tmp/service-log"; restored
if "$TX" apply "$preview_token" >/dev/null 2>&1; then exit 1; fi
baseline 0 0 1 1; prepare; preview_token=$token
"$REAL_LIB/apply" event >/dev/null
cp "$tmp/service-log" "$tmp/prepared-services"
test_boot
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = expired ]
cmp "$tmp/prepared-services" "$tmp/service-log"; restored
[ -f "$tmp/root/tmp/routepolicy/events.pending" ]
"$REAL_LIB/apply" reconcile-event >/dev/null
[ ! -f "$tmp/root/tmp/routepolicy/events.pending" ]
if "$TX" apply "$preview_token" >/dev/null 2>&1; then exit 1; fi
baseline 0 0 1 1; prepare
: >"$tmp/root/etc/routepolicy/state/init-transaction/current/dns-service-attempted"
test_boot
if "$TX" recover-early >/dev/null 2>&1; then exit 1; fi
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = prepared ]
printf '%s\n' 'init DNS unapplied candidate lifecycle: passed (same-boot preview, explicit cancel, cross-boot and zero-write evidence)'
if [ "${1:-}" = --review-regressions ]; then exit 0; fi
matrix_count=0
if [ "${1:-}" != --boot-smoke ] && [ "${1:-}" != --quiesce-smoke ] && [ "${1:-}" != --lifecycle-smoke ] && [ "${1:-}" != --restore-smoke ]; then
for se in 0 1; do for sr in 0 1; do for de in 0 1; do for dr in 0 1; do
	case "${1:-}:$se$sr$de$dr" in --recovery-smoke:0000|--recovery-smoke:0111|--recovery-smoke:1001|--recovery-smoke:1110) ;; --recovery-smoke:*) continue ;; esac
	baseline "$se" "$sr" "$de" "$dr"; prepare
	queries_before=0; [ ! -f "$tmp/queries" ] || queries_before=$(wc -l <"$tmp/queries")
	"$TX" apply "$token" >/dev/null
	[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.enabled")$(cat "$tmp/svc/dnsmasq.running")" = 1100 ]
	[ "$(( $(wc -l <"$tmp/queries") - queries_before ))" = 9 ]
	[ "$(cat "$tmp/svc/routepolicy.enabled")" = 1 ]
	"$TX" recover >/dev/null; restored
	[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.enabled")$(cat "$tmp/svc/dnsmasq.running")" = "$se$sr$de$dr" ]
	matrix_count=$((matrix_count+1))
done; done; done; done
fi
baseline 0 0 1 1
: >"$tmp/delete-fail"
if init_dns_stop; then exit 1; fi
rm "$tmp/delete-fail"; : >"$tmp/list-fail"
if init_dns_stop; then exit 1; fi
rm "$tmp/list-fail"; : >"$tmp/delete-race"
init_dns_stop; init_dns_stop
# Stopping before the first field must restore running state after a later failure.
baseline 0 1 1 1; prepare; : >"$tmp/quiesce-fault"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
[ "$(find "$tmp/root/etc/routepolicy/state/init-transaction/current/fields" -name attempted | wc -l)" = 0 ]
restored
[ "$(cat "$tmp/svc/smartdns.running")" = 1 ]
# Stopped UCI-disabled service must stay stopped without native start adding old_*.
baseline 1 0 1 1
uci set 'smartdns.@smartdns[0].enabled=0'
for option in old_enabled old_port old_auto_set_dnsmasq; do uci delete "smartdns.@smartdns[0].$option"; done
uci commit smartdns; canonical smartdns >"$tmp/smartdns.before"
prepare; : >"$tmp/quiesce-fault"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
restored; [ ! -e "$tmp/native-start-called" ]
if [ "${1:-}" = --quiesce-smoke ]; then
	printf '%s\n' 'init DNS quiesce recovery: passed (no field attempted, native metadata absent, stopped UCI-disabled service, NotFound and real errors)'; exit 0
fi
baseline 0 0 1 1; prepare; : >"$tmp/query-fail"
if "$TX" apply "$token" >/dev/null; then printf 'SERVFAIL was accepted\n' >&2; exit 1; fi
restored
baseline 0 0 1 1; : >"$tmp/netstat-fail"
if "$TX" prepare lan wan wan2 - - - - - - - - 192.0.2.53 198.51.100.53 >"$tmp/listener-error" 2>&1; then exit 1; fi
grep -Fq 'SmartDNS 协调准备阶段失败' "$tmp/listener-error"
rm "$tmp/netstat-fail"
baseline 0 0 1 1; export TEST_DNS_IPV6=1
prepare; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; restored
grep -Fq -- '-6 +tcp' "$tmp/queries"; grep -Fq -- '-6 +notcp' "$tmp/queries"
unset TEST_DNS_IPV6
# A successful init-script return cannot hide a dnsmasq process still using port=0.
baseline 0 0 1 1; prepare; : >"$tmp/query-fail"; : >"$tmp/stale-dnsmasq"
if "$TX" apply "$token" >/dev/null; then exit 1; fi
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = conflict ]
grep -Fq smartdns-service "$tmp/root/etc/routepolicy/state/init-transaction/current/conflicts"
rm "$tmp/stale-dnsmasq" "$tmp/query-fail"; "$TX" recover >/dev/null; restored
# A running, originally DNS-disabled dnsmasq has no invented port-53 obligation.
baseline 0 0 1 1
uci set 'dhcp.@dnsmasq[0].port=0'; uci commit dhcp; printf 0 >"$tmp/svc/dnsmasq.port"
canonical dhcp >"$tmp/dhcp.before"
prepare; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; restored
# Reserved names are never adopted by replacing an unknown upstream section type.
baseline 0 0 1 1
printf "config server 'rp_init'\n\toption ip '192.0.2.88'\n" >"$tmp/root/etc/config/smartdns"
canonical smartdns >"$tmp/smartdns.before"
if prepare >"$tmp/reserved-error" 2>&1; then exit 1; fi
grep -Fq '保留根段 rp_init' "$tmp/reserved-error"
canonical smartdns >"$tmp/smartdns.after"; cmp "$tmp/smartdns.before" "$tmp/smartdns.after"
printf '%s\n' 'init DNS restore functionality and reserved-root protection: passed'
if [ "${1:-}" = --restore-smoke ]; then exit 0; fi
baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
test_boot
printf 0 >"$tmp/svc/smartdns.running"; printf 0 >"$tmp/svc/dnsmasq.running"
rm -f "$tmp/policy-running"
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/root/etc/routepolicy/state/init-transaction/current/phase")" = rolling_back ]
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
# Emulate a boot entry captured before S18 removed its link. S94 must converge.
printf 1 >"$tmp/svc/smartdns.running"
"$TX" recover-startup >/dev/null; restored
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 011 ]
# The native UCI enable flag is distinct from rc-enabled and running.
baseline 1 0 1 1
uci set 'smartdns.@smartdns[0].enabled=0'; uci set 'smartdns.@smartdns[0].old_enabled=0'; uci commit smartdns
canonical smartdns >"$tmp/smartdns.before"
prepare; "$TX" apply "$token" >/dev/null; "$TX" recover >/dev/null; restored
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/smartdns.running")" = 10 ]
# A killed partial field commit is undone before native S19 entries can run.
baseline 1 0 1 1; prepare
printf 'commit:smartdns.@smartdns[0].port' >"$tmp/kill-stage"
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
test_boot
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
"$TX" recover-startup >/dev/null; restored
# A true conflict also quarantines both native DNS startup entries.
baseline 1 0 1 1; prepare; "$TX" apply "$token" >/dev/null
uci set 'smartdns.@smartdns[0].port=9999'; uci commit smartdns
test_boot
if "$TX" recover-early >/dev/null; then exit 1; fi
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
[ "$(uci -q get 'smartdns.@smartdns[0].port')" = 9999 ]
# Confirmed reboot: cold application cache, sets before DNS, and failure stays closed.
baseline 0 0 1 1; prepare; "$TX" apply "$token" >/dev/null
SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null
active="$tmp/root/etc/routepolicy/state/init-transaction/confirmed/$token"
canonical dhcp >"$tmp/shutdown-dhcp.before"
"$TX" shutdown-dns >/dev/null
[ "$(cat "$tmp/svc/smartdns.enabled")" = 0 ]
canonical dhcp >"$tmp/shutdown-dhcp.after"; cmp "$tmp/shutdown-dhcp.before" "$tmp/shutdown-dhcp.after"
rm -rf "$tmp/root/tmp/routepolicy"; rm -f "$tmp/policy-running"
printf 0 >"$tmp/svc/smartdns.running"; printf 0 >"$tmp/svc/dnsmasq.running"
test_boot
"$TX" recover-early >/dev/null
[ "$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.enabled")" = 00 ]
# Admission precedes policy writes and native start; it never repairs DHCP drift.
cp "$tmp/root/etc/config/dhcp" "$tmp/boot-dhcp.good"
for drift in missing port53 list disabled pending; do
	cp "$tmp/boot-dhcp.good" "$tmp/root/etc/config/dhcp"
	case "$drift" in
		missing) uci delete 'dhcp.@dnsmasq[0].port' ;;
		port53) uci set 'dhcp.@dnsmasq[0].port=53' ;;
		list) uci delete 'dhcp.@dnsmasq[0].port'; uci add_list 'dhcp.@dnsmasq[0].port=0' ;;
		disabled) uci set 'dhcp.@dnsmasq[0].disabled=0' ;;
		pending) uci set 'dhcp.@dnsmasq[0].port=53' ;;
	esac
	[ "$drift" = pending ] || uci commit dhcp
	cp "$tmp/root/etc/config/dhcp" "$tmp/boot-dhcp.drift"
	starts_before=$(grep -Ec '^smartdns (start|reload)$' "$tmp/service-log" || true)
	if "$TX" boot-dns >/dev/null 2>&1; then printf 'boot accepted DHCP drift: %s\n' "$drift" >&2; exit 1; fi
	[ "$(grep -Ec '^smartdns (start|reload)$' "$tmp/service-log" || true)" = "$starts_before" ]
	cmp "$tmp/boot-dhcp.drift" "$tmp/root/etc/config/dhcp"
	[ -f "$active/dns-boot-pending" ] && [ ! -f "$active/dns-boot-ready" ]
	[ ! -f "$tmp/policy-running" ]
	[ "$drift" != pending ] || uci revert dhcp
done
cp "$tmp/boot-dhcp.good" "$tmp/root/etc/config/dhcp"
: >"$tmp/policy-fail"
if "$TX" boot-dns >/dev/null; then exit 1; fi
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")" = 00 ]
rm "$tmp/policy-fail"
: >"$tmp/query-fail"
if "$TX" boot-dns >/dev/null; then exit 1; fi
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")" = 00 ]
[ -f "$active/dns-boot-pending" ]
rm "$tmp/query-fail"
"$TX" boot-dns >/dev/null
[ -f "$tmp/policy-running" ]
[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/smartdns.enabled")$(cat "$tmp/svc/dnsmasq.running")$(cat "$tmp/svc/dnsmasq.enabled")" = 1100 ]
[ "$(cat "$tmp/root/etc/smartdns/user.cache")" = USER-CACHE ]
[ ! -f "$active/dns-boot-pending" ]

# Drive retries through the real S94 entry and its supervised guard command.
guard_entry() {
	guard_pid=
	export ROUTEPOLICY_INIT_TRANSACTION=$TX
	. "$ROOT/routepolicy/files/etc/init.d/routepolicy-initguard"
	procd_open_instance() { :; }
	procd_set_param() { [ "$1" != command ] || guard_command=$2; }
	procd_close_instance() { "$guard_command" guard >"$tmp/guard.log" 2>&1 & guard_pid=$!; }
	start_service
}
wait_guard() {
	remaining=20
	while [ -f "$active/dns-boot-pending" ]; do
		[ "$remaining" -gt 0 ] || { cat "$tmp/guard.log"; kill "$guard_pid"; return 1; }
		sleep 1; remaining=$((remaining-1))
	done
	[ -z "$guard_pid" ] || wait "$guard_pid"
}
reboot_services() {
	rm -rf "$tmp/root/tmp/routepolicy"; rm -f "$tmp/policy-running"
	printf 0 >"$tmp/svc/smartdns.running"; printf 0 >"$tmp/svc/dnsmasq.running"
	test_boot
	"$TX" recover-early >/dev/null
}
# Policy off keeps DNS, even when the policy NIC is down and apply cannot run.
for adapter in 1 0; do
	uci set routepolicy.main.enabled=0; uci set "routepolicy.main.smartdns_enabled=$adapter"; uci commit routepolicy
	: >"$tmp/policy-down"; : >"$tmp/policy-fail"; : >"$tmp/queries"; rm -f "$tmp/watch-registration"
	reboot_services "dns-only-$adapter"
	"$TX" boot-dns >/dev/null
	[ "$(cat "$tmp/svc/smartdns.running")$(cat "$tmp/svc/dnsmasq.running")" = 10 ]
	[ ! -f "$tmp/policy-running" ] && [ ! -e "$tmp/root/tmp/routepolicy/active" ] && [ ! -e "$tmp/watch-registration" ]
	[ "$(wc -l <"$tmp/queries")" = 4 ]
	if grep -Fq routepolicy-init-policy.test "$tmp/queries" || grep -Fq "conf-file '/etc/smartdns/conf.d/90-routepolicy.conf'" "$tmp/root/var/etc/smartdns/smartdns.conf"; then exit 1; fi
	[ "$(uci -q get routepolicy.main.enabled):$(uci -q get routepolicy.main.smartdns_enabled)" = "0:$adapter" ]
done
rm "$tmp/policy-down" "$tmp/policy-fail"
uci set routepolicy.main.enabled=1; uci set routepolicy.main.smartdns_enabled=0; uci commit routepolicy
reboot_services policy-without-adapter; "$TX" boot-dns >/dev/null
[ -f "$tmp/policy-running" ]
if grep -Fq "conf-file '/etc/smartdns/conf.d/90-routepolicy.conf'" "$tmp/root/var/etc/smartdns/smartdns.conf"; then exit 1; fi
uci set routepolicy.main.smartdns_enabled=1; uci commit routepolicy
reboot_services policy-with-adapter; "$TX" boot-dns >/dev/null
grep -Fq "conf-file '/etc/smartdns/conf.d/90-routepolicy.conf'" "$tmp/root/var/etc/smartdns/smartdns.conf"
printf 'DNS ownership/policy switches: passed (DNS-only with policy down, both adapter values, no policy apply/90/watch, policy enabled unchanged)\n'
txdir="$tmp/root/etc/routepolicy/state/init-transaction"
origin=$(cat "$txdir/source"); cp -R "$txdir/confirmed/$origin/fields" "$tmp/origin-fields"
prepare
[ "$(cat "$txdir/active")" = "$origin" ]
reboot_services prepared-after-confirm
"$REAL_LIB/apply" event >/dev/null
: >"$tmp/policy-fail"; guard_entry
[ -f "$active/dns-boot-pending" ] && [ "$(cat "$tmp/svc/smartdns.running")" = 0 ]
"$TX" status >"$tmp/active-status"
[ "$(jsonfilter -i "$tmp/active-status" -e '@.phase')" = expired ]
[ "$(jsonfilter -i "$tmp/active-status" -e '@.active.dns_boot_state')" = retrying ]
rm "$tmp/policy-fail"; : >"$tmp/query-fail"
remaining=30
while [ "$(cat "$active/failed-stage")" != boot-dns-start ]; do
	[ "$remaining" -gt 0 ] || { cat "$tmp/guard.log"; exit 1; }
	sleep 1; remaining=$((remaining-1))
done
[ -f "$active/dns-boot-pending" ] && [ "$(cat "$tmp/svc/smartdns.running")" = 0 ]
rm "$tmp/query-fail"; wait_guard
[ ! -f "$tmp/root/tmp/routepolicy/events.pending" ] && [ ! -f "$tmp/root/tmp/routepolicy/events.inflight" ]
[ "$(cat "$txdir/current/phase")" = expired ]
if "$TX" apply "$token" >/dev/null 2>&1; then exit 1; fi
"$TX" status | grep -Fq '"prepared_expired_reason":"boot-changed"'
diff -r "$tmp/origin-fields" "$txdir/confirmed/$origin/fields"
# A repeated apply rollback keeps the first accepted boot and provenance contract.
prepare; : >"$tmp/query-fail"
if "$TX" apply "$token" >/dev/null; then exit 1; fi
[ "$(cat "$txdir/current/phase")" = rolled_back ]
rm "$tmp/query-fail"
reboot_services rollback-after-confirm; guard_entry; wait_guard
[ "$(cat "$txdir/active")" = "$origin" ]
# Both sides of the pointer commit converge after a power loss in confirmation.
mkdir "$txdir/confirmed-foreign"; printf USER >"$txdir/confirmed-foreign/keep"
for point in intent pointer; do
	prepare; "$TX" apply "$token" >/dev/null
	printf '%s\n' "$point" >"$tmp/kill-confirm"
	if SSH_CONNECTION='198.51.100.9 1234 192.0.2.1 22' "$TX" confirm "$token" >/dev/null 2>&1; then exit 1; fi
	[ "$(cat "$txdir/current/phase")" = confirming ]
	reboot_services "confirm-interrupted-$point"
	[ "$(cat "$txdir/current/phase")" = confirmed ] && [ "$(cat "$txdir/active")" = "$token" ]
	active="$txdir/confirmed/$token"; guard_entry; wait_guard
	[ "$(find "$txdir/confirmed" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 2 ]
	[ "$(cat "$txdir/confirmed-foreign/keep")" = USER ]
	[ "$(cat "$txdir/source")" = "$origin" ]
	diff -r "$tmp/origin-fields" "$txdir/confirmed/$origin/fields"
done
mv "$txdir/active" "$tmp/active.value"; ln -s "$tmp/active.value" "$txdir/active"
if "$TX" recover-early >/dev/null; then exit 1; fi
[ "$(cat "$tmp/active.value")" = "$token" ]
rm "$txdir/active"; mv "$tmp/active.value" "$txdir/active"
mv "$active" "$tmp/active.record"; ln -s "$tmp/active.record" "$active"
if "$TX" recover-early >/dev/null; then exit 1; fi
rm "$active"; mv "$tmp/active.record" "$active"
printf 'init DNS native WAL: passed (matrix=%s; distinct UCI flag, kill, conflict, pending and confirmed reboot)\n' "$matrix_count"
