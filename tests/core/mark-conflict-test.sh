#!/bin/sh

set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$ROOT/routepolicy/files/usr/libexec/routepolicy/common"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-mark-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat >"$tmp/ip" <<'EOF'
#!/bin/sh
cat <<'RULES'
12000: from all fwmark 0x100/0x100 lookup 200
11000: from all fwmark 0x000/0x300 lookup 201
10000: from all fwmark 0x400/0x400 lookup 202
RULES
EOF
chmod +x "$tmp/ip"
conflicts=$(PATH="$tmp:$PATH" rp_mark_conflicts 0x100 0x100 12000 200)
printf '%s\n' "$conflicts" | grep -Fq '0x000/0x300' || { printf 'overlapping mask was not detected\n' >&2; exit 1; }
if printf '%s\n' "$conflicts" | grep -Fq '0x400/0x400'; then printf 'disjoint mask was reported\n' >&2; exit 1; fi
if printf '%s\n' "$conflicts" | grep -Fq '12000:'; then printf 'owned rule was reported\n' >&2; exit 1; fi
printf 'mark conflict tests: passed\n'
