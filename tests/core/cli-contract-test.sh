#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
CTL="$ROOT/routepolicy/files/usr/sbin/routepolicyctl"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-cli-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

for name in validate render apply status diagnose update rollback; do
	cat >"$tmp/$name" <<EOF
#!/bin/sh
printf '{"ok":true,"operation":"$name"}\\n'
EOF
	chmod +x "$tmp/$name"
done
cp "$tmp/apply" "$tmp/import-legacy"
cp "$tmp/apply" "$tmp/user-list"
cat >"$tmp/smartdns-control" <<'EOF'
#!/bin/sh
case "$1" in save|write-local-hosts) cat >/dev/null ;; esac
printf '{"ok":true,"operation":"smartdns-%s"}\n' "$1"
EOF
chmod +x "$tmp/smartdns-control"

for command_name in validate render apply reload status diagnose update rollback; do
	out=$(ROUTEPOLICY_LIBEXEC="$tmp" "$CTL" "$command_name" --json)
	case "$out" in '{"ok":true'* ) ;; *) printf 'bad JSON contract for %s\n' "$command_name" >&2; exit 1 ;; esac
done
ROUTEPOLICY_LIBEXEC="$tmp" "$CTL" import-legacy /etc/splitroute --json >/dev/null
ROUTEPOLICY_LIBEXEC="$tmp" "$CTL" user-list read domain-policy --json >/dev/null
for operation in status save validate apply discard read-local-hosts write-local-hosts; do
	printf '%s\n' 'initialize	1' | ROUTEPOLICY_LIBEXEC="$tmp" "$CTL" "smartdns-$operation" --json >/dev/null
done
if ROUTEPOLICY_LIBEXEC="$tmp" "$CTL" status --json extra >/dev/null 2>&1; then
	printf 'extra argv unexpectedly accepted\n' >&2; exit 1
fi
if ROUTEPOLICY_LIBEXEC="$tmp" "$CTL" shell 'reboot' >/dev/null 2>&1; then
	printf 'unknown command unexpectedly accepted\n' >&2; exit 1
fi
printf 'CLI contract tests: passed\n'
