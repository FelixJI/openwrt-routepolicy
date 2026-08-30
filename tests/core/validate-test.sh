#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
VALIDATE="$ROOT/routepolicy/files/usr/libexec/routepolicy/validate"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-validate-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d"
cp "$ROOT/routepolicy/files/etc/config/routepolicy" "$tmp/etc/config/routepolicy"
cp "$ROOT"/routepolicy/files/etc/routepolicy/user.d/*.list "$tmp/etc/routepolicy/user.d/"

run_validate() {
	PATH="$ROOT/tests/core/stubs:$PATH" ROUTEPOLICY_ROOT="$tmp" ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy" \
		"$VALIDATE"
}

run_validate >/dev/null || {
	printf '%s\n' 'shipped optional user lists did not pass validation' >&2
	exit 1
}

for file in domain-policy domain-default ipv4-policy ipv4-default; do
	printf '%s\n' '  ' '# optional list intentionally left empty' '; converter-style comment' >"$tmp/etc/routepolicy/user.d/$file.list"
done
run_validate >/dev/null || {
	printf '%s\n' 'whitespace/comment-only optional user lists did not pass validation' >&2
	exit 1
}

printf '%s\n' 'not a valid domain' >"$tmp/etc/routepolicy/user.d/domain-default.list"
if run_validate >/dev/null 2>&1; then
	printf '%s\n' 'validation accepted an invalid non-empty user list' >&2
	exit 1
fi

printf '%s\n' 'validate tests: passed'
