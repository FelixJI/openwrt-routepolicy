#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-resolver.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
LIBEXEC=$ROUTEPOLICY_LIBEXEC
. "$LIBEXEC/common"
. "$LIBEXEC/init-dns"
WAL="$RP_STATE_DIR/init-transaction/current"; export WAL
REAL_RESOLVER_MV=$(command -v mv); REAL_RESOLVER_RM=$(command -v rm); export REAL_RESOLVER_MV REAL_RESOLVER_RM
mkdir "$tmp/bin"
cat >"$tmp/bin/uci" <<'SH'
#!/bin/sh
case "$*" in '-q show dhcp') echo dhcp.main=dnsmasq ;; '-q get dhcp.main.localuse') echo 1 ;; '-q get dhcp.main.domain') echo lan ;; *) exit 1 ;; esac
SH
cat >"$tmp/bin/dig" <<'SH'
#!/bin/sh
[ "$(readlink "$ROUTEPOLICY_ROOT/tmp/resolv.conf")" = /tmp/resolv.conf.d/routepolicy.conf ] || exit 1
printf '127.0.0.1\n'
SH
cat >"$tmp/bin/mv" <<'SH'
#!/bin/sh
"$REAL_RESOLVER_MV" "$@" || exit $?
for target do :; done
if [ -f "$TEST_RESOLVER_KILL" ] && [ "$target" = "$(cat "$TEST_RESOLVER_KILL")" ]; then "$REAL_RESOLVER_RM" "$TEST_RESOLVER_KILL"; kill -KILL "$PPID"; fi
SH
cat >"$tmp/bin/rm" <<'SH'
#!/bin/sh
"$REAL_RESOLVER_RM" "$@" || exit $?
for target do :; done
if [ -f "$TEST_RESOLVER_KILL" ] && [ "$target" = "$(cat "$TEST_RESOLVER_KILL")" ]; then "$REAL_RESOLVER_RM" "$TEST_RESOLVER_KILL"; kill -KILL "$PPID"; fi
SH
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" TEST_RESOLVER_KILL="$tmp/kill"
init_dns_service_state() { printf '1\n'; }
reset() {
	rm -rf "$tmp/root"
	mkdir -p "$WAL" "$tmp/root/etc" "$tmp/root/tmp/resolv.conf.d" "$tmp/root/proc/sys/kernel/random"
	chmod 755 "$tmp" "$tmp/root" "$tmp/root/tmp" "$tmp/root/tmp/resolv.conf.d"
	printf '00000000-0000-4000-8000-000000000001\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
	printf 'set\tdhcp.main.localuse\t0\n' >"$WAL/candidate"
	ln -s /tmp/resolv.conf "$tmp/root/etc/resolv.conf"
	ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
	printf 'nameserver 198.51.100.53\n' >"$tmp/root/tmp/resolv.conf.d/resolv.conf.auto"
}
restored() {
	init_resolver_restore
	[ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/resolv.conf.d/resolv.conf.auto ] && [ ! -e "$RP_RESOLVER_FILE" ]
	grep -Fxq 'nameserver 198.51.100.53' "$tmp/root/tmp/resolv.conf.d/resolv.conf.auto"
	init_resolver_restore
}
reset; init_resolver_prepare; init_resolver_install; init_resolver_verify
nonroot_read=skipped
if [ "$(id -u)" = 0 ] && command -v runuser >/dev/null && id nobody >/dev/null 2>&1; then runuser -u nobody -- cat "$RP_RESOLVER_FILE" | grep -Fxq 'nameserver 127.0.0.1'; nonroot_read=passed; fi
printf 'resolver nonroot read: %s\n' "$nonroot_read"
restored
reset; rm "$RP_RESOLVER_ENTRY"; printf 'search lan\nnameserver 127.0.0.1\nnameserver ::1\n' >"$RP_RESOLVER_ENTRY"; chmod 644 "$RP_RESOLVER_ENTRY"
cp "$RP_RESOLVER_ENTRY" "$tmp/native.before"
init_resolver_prepare; init_resolver_install; init_resolver_restore; cmp "$tmp/native.before" "$RP_RESOLVER_ENTRY"
for object in file link; do
	reset; init_resolver_prepare
	case "$object" in file) printf '%s\n' "$RP_RESOLVER_FILE" >"$TEST_RESOLVER_KILL" ;; *) printf '%s\n' "$RP_RESOLVER_ENTRY" >"$TEST_RESOLVER_KILL" ;; esac
	if sh -c '. "$ROUTEPOLICY_LIBEXEC/common"; . "$ROUTEPOLICY_LIBEXEC/init-dns"; init_resolver_install'; then printf 'resolver install kill missing\n' >&2; exit 1; fi
	[ ! -f "$TEST_RESOLVER_KILL" ]; restored
done
for object in link file; do
	reset; init_resolver_prepare; init_resolver_install
	case "$object" in file) printf '%s\n' "$RP_RESOLVER_FILE" >"$TEST_RESOLVER_KILL" ;; *) printf '%s\n' "$RP_RESOLVER_ENTRY" >"$TEST_RESOLVER_KILL" ;; esac
	if sh -c '. "$ROUTEPOLICY_LIBEXEC/common"; . "$ROUTEPOLICY_LIBEXEC/init-dns"; init_resolver_restore'; then printf 'resolver restore kill missing\n' >&2; exit 1; fi
	[ ! -f "$TEST_RESOLVER_KILL" ]; restored
done
for object in file link; do
	reset; init_resolver_prepare; init_resolver_install
	case "$object" in file) printf 'external\n' >"$RP_RESOLVER_FILE" ;; *) rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/user-resolver "$RP_RESOLVER_ENTRY" ;; esac
	if init_resolver_restore; then printf 'resolver external conflict overwritten\n' >&2; exit 1; fi
	case "$object" in file) grep -Fxq external "$RP_RESOLVER_FILE"; init_resolver_link_ok ;; *) [ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/user-resolver ]; init_resolver_file_ok ;; esac
done
reset; rm "$tmp/root/etc/resolv.conf"; ln -s /tmp/custom "$tmp/root/etc/resolv.conf"
if init_resolver_prepare; then printf 'custom etc resolver accepted\n' >&2; exit 1; fi
reset; rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/custom "$RP_RESOLVER_ENTRY"
if init_resolver_prepare; then printf 'custom tmp resolver accepted\n' >&2; exit 1; fi
reset; init_resolver_prepare; init_resolver_install
token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
active="$RP_STATE_DIR/init-transaction/confirmed/$token"
mkdir -p "$active/origin"; cp "$WAL/dns-resolver" "$active/dns-resolver"; cp "$WAL/dns-resolver" "$active/origin/dns-resolver"
printf '%s\n' "$token" >"$active/token"; printf 'confirmed\n' >"$active/phase"; printf '%s\n' "$token" >"$RP_STATE_DIR/init-transaction/active"
WAL="$RP_STATE_DIR/init-transaction/second"; export WAL; mkdir "$WAL"; printf 'set\tdhcp.main.localuse\t0\n' >"$WAL/candidate"
init_resolver_prepare; init_resolver_install; init_resolver_origin "$active/origin"
[ "$(init_resolver_get "$active/origin/dns-resolver" file-kind)" = absent ]
cp "$active/origin/dns-resolver" "$WAL/dns-resolver"; init_resolver_attempt file; init_resolver_attempt link; restored
# A new boot must not replay the old native regular file or stale object ownership.
printf '00000000-0000-4000-8000-000000000002\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
rm "$RP_RESOLVER_ENTRY"; printf 'new boot external\n' >"$RP_RESOLVER_ENTRY"
init_resolver_restore; grep -Fxq 'new boot external' "$RP_RESOLVER_ENTRY"
rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
init_resolver_prepare boot; init_resolver_origin "$active/origin"; init_resolver_install; init_resolver_verify; restored
reset; init_resolver_prepare; init_resolver_install
printf 'confirmed\n' >"$WAL/phase"; cp "$tmp/root/proc/sys/kernel/random/boot_id" "$WAL/boot-id"
rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
if init_resolver_prepare || init_resolver_install; then printf 'confirmed before was treated as unfinished install\n' >&2; exit 1; fi
[ "$(readlink "$RP_RESOLVER_ENTRY")" = /tmp/resolv.conf.d/resolv.conf.auto ]
rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/resolv.conf.d/routepolicy.conf "$RP_RESOLVER_ENTRY"; init_resolver_install
printf '00000000-0000-4000-8000-000000000003\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
rm "$RP_RESOLVER_ENTRY" "$RP_RESOLVER_FILE"; ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
init_resolver_prepare boot; init_resolver_install; init_resolver_verify
cp "$tmp/root/proc/sys/kernel/random/boot_id" "$WAL/dns-boot-ready"
rm "$RP_RESOLVER_ENTRY"; ln -s /tmp/resolv.conf.d/resolv.conf.auto "$RP_RESOLVER_ENTRY"
if init_resolver_install; then printf 'ready boot before was treated as unfinished install\n' >&2; exit 1; fi
printf '%s\n' 'resolver transaction: passed (standard native/link, modes, four kill boundaries, conflicts, confirmed before rejected, sameboot origin, crossboot no replay/rebuild, auto preserved)'
