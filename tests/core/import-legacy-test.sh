#!/bin/sh

set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-import-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

make_tree() {
	root=$1
	mkdir -p "$root/etc/config" "$root/etc/routepolicy/user.d" \
		"$root/etc/routepolicy/managed.d/current" "$root/etc/routepolicy/managed.d/previous" \
		"$root/etc/routepolicy/state" "$root/tmp/routepolicy" "$root/legacy"
	: >"$root/etc/config/routepolicy"
}

ok="$tmp/ok"
make_tree "$ok"
printf '%s\n' 'example.com' >"$ok/legacy/domain-policy.list"
printf '%s\n' '8.8.8.8' >"$ok/legacy/managed-ipv4-policy.list"
ROUTEPOLICY_ROOT="$ok" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$LIBEXEC/import-legacy" "$ok/legacy" >/dev/null
grep -Fxq 'example.com' "$ok/etc/routepolicy/user.d/domain-policy.list"
grep -Fxq '8.8.8.8' "$ok/etc/routepolicy/managed.d/current/legacy.ipv4-policy.list"
[ -f "$ok/etc/routepolicy/.legacy-imported" ]
[ -f "$ok/etc/routepolicy/state/legacy-import-report.json" ]

bad="$tmp/bad"
make_tree "$bad"
printf '%s\n' 'old.example' >"$bad/etc/routepolicy/user.d/domain-policy.list"
printf '%s\n' 'new.example' >"$bad/legacy/domain-policy.list"
printf '%s\n' 'not a domain' >"$bad/legacy/domain-default.list"
if ROUTEPOLICY_ROOT="$bad" ROUTEPOLICY_LIBEXEC="$LIBEXEC" \
	"$LIBEXEC/import-legacy" "$bad/legacy" >/dev/null 2>&1; then
	printf '%s\n' 'invalid legacy input unexpectedly succeeded' >&2
	exit 1
fi
grep -Fxq 'old.example' "$bad/etc/routepolicy/user.d/domain-policy.list"
[ ! -e "$bad/etc/routepolicy/user.d/domain-default.list" ]
[ ! -e "$bad/etc/routepolicy/.legacy-imported" ]
[ ! -e "$bad/etc/routepolicy/state/legacy-import-report.json" ]

printf '%s\n' 'import legacy tests: passed'
