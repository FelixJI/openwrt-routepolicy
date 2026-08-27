#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-user-list-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d"
: >"$tmp/etc/config/routepolicy"

run_ctl() {
	ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$LIBEXEC" "$ROOT/routepolicy/files/usr/sbin/routepolicyctl" "$@"
}

printf 'B.Example.com\na.example.com\na.example.com\n' | run_ctl user-list write domain-policy --json >"$tmp/write.json"
grep -q '"ok":true' "$tmp/write.json"
expected='a.example.com
b.example.com'
actual=$(cat "$tmp/etc/routepolicy/user.d/domain-policy.list")
[ "$actual" = "$expected" ] || { printf 'normalized output mismatch\n' >&2; exit 1; }

before=$(cat "$tmp/etc/routepolicy/user.d/domain-policy.list")
if printf 'valid.example\nbad_domain.example\n' | run_ctl user-list write domain-policy --json >/dev/null 2>&1; then
	printf 'invalid write unexpectedly succeeded\n' >&2; exit 1
fi
after=$(cat "$tmp/etc/routepolicy/user.d/domain-policy.list")
[ "$before" = "$after" ] || { printf 'failed write changed previous file\n' >&2; exit 1; }

run_ctl user-list read domain-policy --json >"$tmp/read.json"
grep -q '"content":"a.example.com\\nb.example.com"' "$tmp/read.json"

label63=$(printf '%063d' 0 | tr 0 a)
label61=$(printf '%061d' 0 | tr 0 b)
label62=$(printf '%062d' 0 | tr 0 c)
domain253="$label63.$label63.$label61.$label63"
domain254="$label63.$label63.$label62.$label63"
printf '%s\n' "$domain253" | run_ctl user-list write domain-policy --json >/dev/null
if printf '%s\n' "$domain254" | run_ctl user-list write domain-policy --json >/dev/null 2>&1; then
	printf 'overlong domain unexpectedly accepted\n' >&2; exit 1
fi

rm -f "$tmp/etc/routepolicy/user.d/ipv4-policy.list"
ln -s "$tmp/etc/config/routepolicy" "$tmp/etc/routepolicy/user.d/ipv4-policy.list"
if [ -L "$tmp/etc/routepolicy/user.d/ipv4-policy.list" ]; then
	if printf '8.8.8.8\n' | run_ctl user-list write ipv4-policy --json >/dev/null 2>&1; then
		printf 'symlink target unexpectedly accepted\n' >&2; exit 1
	fi
fi

printf 'user-list tests: passed\n'
