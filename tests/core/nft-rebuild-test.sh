#!/bin/sh
# Run explicitly under unshare --net; never mutate the caller's network namespace.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
if [ "${TEST_NFT_ISOLATED:-0}" != 1 ] || [ "$(id -u)" != 0 ] || ! command -v nft >/dev/null 2>&1; then
	printf '%s\n' 'nft rebuild kernel test: skipped (requires root, nft and TEST_NFT_ISOLATED=1 under unshare --net)'
	exit 0
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-nft-rebuild.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/etc/config" "$tmp/etc/routepolicy/user.d" "$tmp/etc/routepolicy/managed.d/current" "$tmp/etc/routepolicy/managed.d/previous"
: >"$tmp/etc/config/routepolicy"
LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
ROUTEPOLICY_ROOT=$tmp
export ROUTEPOLICY_ROOT
. "$LIBEXEC/common"
mkdir -p "$RP_RUN_DIR"
# This test exercises object lifetime, independently of optional routing modules.
cat >"$RP_NFT_FILE" <<'EOF'
table inet routepolicy {
	set domain_policy4 { type ipv4_addr; flags timeout; timeout 1h; }
	set domain_default4 { type ipv4_addr; flags timeout; timeout 1h; }
	set static_policy4 { type ipv4_addr; }
	set static_default4 { type ipv4_addr; }
	set source_ingress4 { type ifname . ipv4_addr; flags dynamic,timeout; }
	set source_egress4 { type ifname . ipv4_addr; flags dynamic,timeout; }
	chain prerouting { }
	chain output { }
	chain classify { }
	chain source_prerouting { }
	chain source_postrouting { }
}
EOF
nft -f "$RP_NFT_FILE"
nft add element inet routepolicy domain_policy4 '{ 192.0.2.1 timeout 45s, 192.0.2.2 timeout 1s }'
nft add element inet routepolicy domain_default4 '{ 198.51.100.1 timeout 45s }'
nft list table inet routepolicy >"$tmp/old.nft"
# Exercise a legacy table with a missing chain, forcing a full rebuild.
nft flush chain inet routepolicy source_postrouting
nft delete chain inet routepolicy source_postrouting
rp_nft_rebuild "$RP_NFT_FILE" "$tmp/rebuild.nft"
# Simulate a DNS answer after the candidate was prepared but before its commit.
nft add element inet routepolicy domain_policy4 '{ 192.0.2.3 timeout 30s }'
sleep 2
nft -c -f "$tmp/rebuild.nft"
nft -f "$tmp/rebuild.nft"
nft list set inet routepolicy domain_policy4 >"$tmp/policy"
grep -Fq '192.0.2.1' "$tmp/policy"
grep -Fq '192.0.2.3' "$tmp/policy"
if grep -Fq '192.0.2.2' "$tmp/policy"; then printf 'expired DNS entry was resurrected\n' >&2; exit 1; fi
grep -Eq '192\.0\.2\.1 .*expires (4[0-3]s|[0-3]?[0-9]s)' "$tmp/policy"
grep -Eq '192\.0\.2\.3 .*expires (2[0-8]s|1[0-9]s|[0-9]s)' "$tmp/policy"
# A rejected batch and the subsequent old-rule restore retain later DNS answers.
{ cat "$tmp/rebuild.nft"; printf 'add rule inet routepolicy nonexistent counter\n'; } >"$tmp/rejected.nft"
if nft -f "$tmp/rejected.nft" >/dev/null 2>&1; then exit 1; fi
nft add element inet routepolicy domain_policy4 '{ 192.0.2.4 timeout 30s }'
rp_nft_rebuild "$tmp/old.nft" "$tmp/restore.nft"
nft -f "$tmp/restore.nft"
nft list set inet routepolicy domain_policy4 >"$tmp/policy"
grep -Fq '192.0.2.3' "$tmp/policy"
grep -Fq '192.0.2.4' "$tmp/policy"
if grep -Fq '192.0.2.2' "$tmp/policy"; then exit 1; fi
nft delete table inet routepolicy
nft -f - <<'EOF'
table inet routepolicy {
	set domain_policy4 { type ipv6_addr; flags timeout; }
	set domain_default4 { type ipv4_addr; flags timeout; }
}
EOF
if rp_nft_rebuild "$RP_NFT_FILE" "$tmp/incompatible.nft"; then exit 1; fi
nft list set inet routepolicy domain_policy4 | grep -Fq 'type ipv6_addr'
printf '%s\n' 'nft rebuild kernel test: passed (concurrent DNS insert, expiry, missing chain, rejected commit and rollback)'
