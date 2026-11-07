#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-ownership.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export ROUTEPOLICY_ROOT="$tmp/root" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" TEST_OWNERSHIP_LOG="$tmp/commands"
mkdir -p "$tmp/bin" "$tmp/root/etc/config" "$tmp/root/etc/routepolicy/state" "$tmp/root/proc/sys/kernel/random"
: >"$tmp/root/etc/config/routepolicy"
printf '22222222-2222-4222-8222-222222222222\n' >"$tmp/root/proc/sys/kernel/random/boot_id"
cat >"$tmp/bin/nft" <<'SH'
#!/bin/sh
printf 'nft %s\n' "$*" >>"$TEST_OWNERSHIP_LOG"
case "$*" in
 'list tables') [ "${TEST_KERNEL_OCCUPIED:-0}" != 1 ] || printf 'table inet routepolicy\n' ;;
 'list table inet routepolicy') [ "${TEST_KERNEL_OCCUPIED:-0}" = 1 ] || exit 1; printf 'table inet routepolicy { }\n' ;;
 *) exit 0 ;;
esac
SH
cat >"$tmp/bin/ip" <<'SH'
#!/bin/sh
printf 'ip %s\n' "$*" >>"$TEST_OWNERSHIP_LOG"
case "$*" in
 '-4 -N rule show'|'-4 rule show') [ "${TEST_KERNEL_OCCUPIED:-0}" != 1 ] || printf '12000: from all fwmark 0x100/0x100 lookup 200\n' ;;
 '-4 route show table 200') [ "${TEST_KERNEL_OCCUPIED:-0}" != 1 ] || printf 'default via 192.0.2.1 dev foreign metric 10\n' ;;
esac
exit 0
SH
chmod +x "$tmp/bin/nft" "$tmp/bin/ip"
export PATH="$tmp/bin:$ROOT/tests/core/stubs:$PATH"
receipt="$tmp/root/etc/routepolicy/state/applied"
for evidence in legacy crossboot absent; do
	rm -f "$receipt"
	if [ "$evidence" != absent ]; then
		cat >"$receipt" <<'EOF'
schema=1
route_table=200
rule_priority=12000
mark=0x100
mark_mask=0x100
policy_interface=usbwan
EOF
		[ "$evidence" != crossboot ] || printf 'boot_id=11111111-1111-4111-8111-111111111111\n' >>"$receipt"
		cp "$receipt" "$tmp/receipt.before"
	fi
	: >"$TEST_OWNERSHIP_LOG"
	if TEST_KERNEL_OCCUPIED=1 "$ROUTEPOLICY_LIBEXEC/apply" teardown >"$tmp/result" 2>&1; then printf 'untrusted %s receipt deleted target objects\n' "$evidence" >&2; exit 1; fi
	if grep -Eq '^nft delete|^ip .* (flush|del|replace|add) ' "$TEST_OWNERSHIP_LOG"; then cat "$TEST_OWNERSHIP_LOG" >&2; exit 1; fi
	[ "$evidence" = absent ] || cmp "$receipt" "$tmp/receipt.before"
done
# The same legacy receipt can be retired only after successful empty observations.
cat >"$receipt" <<'EOF'
schema=1
route_table=200
rule_priority=12000
mark=0x100
mark_mask=0x100
policy_interface=usbwan
EOF
: >"$TEST_OWNERSHIP_LOG"
TEST_KERNEL_OCCUPIED=0 "$ROUTEPOLICY_LIBEXEC/apply" teardown >/dev/null
[ ! -e "$receipt" ]
if grep -Eq '^nft delete|^ip .* (flush|del|replace|add) ' "$TEST_OWNERSHIP_LOG"; then cat "$TEST_OWNERSHIP_LOG" >&2; exit 1; fi
printf '%s\n' 'boot ownership tests: passed (legacy, absent and cross-boot conflicts preserved; empty legacy receipt retired)'
