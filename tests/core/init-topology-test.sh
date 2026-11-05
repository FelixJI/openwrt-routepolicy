#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-topology.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/root/proc/sys/net/ipv4/conf" "$tmp/root/sys/class/net/eth3/device"
export TEST_TOPOLOGY_DIR=$tmp ROUTEPOLICY_ROOT="$tmp/root"
export ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
export PATH="$tmp/bin:$PATH"
tool="$ROUTEPOLICY_LIBEXEC/init-topology"
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" != -q ] || shift
case "$1" in
	get) awk -F '\t' -v key="$2" '$1==key{print $2;found=1}END{exit !found}' "$TEST_TOPOLOGY_DIR/config" ;;
	show) awk -F '\t' -v p="$2." 'index($1,p)==1{if($1 ~ /\.[^.]+\./)printf "%s=\047%s\047\n",$1,$2;else printf "%s=%s\n",$1,$2}' "$TEST_TOPOLOGY_DIR/config" ;;
	*) printf 'unexpected UCI write: %s\n' "$*" >>"$TEST_TOPOLOGY_DIR/writes"; exit 1 ;;
esac
EOF
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
case "$*" in
	'call network.interface.lan status') echo lan ;;
	'call network.interface.wan status') echo wan ;;
	'call network.interface.policy status') echo policy ;;
	'call network.interface.rp_init_policy status') echo new_policy ;;
	'call network.interface.rp_init_default status') echo new_policy ;;
	'call network.interface dump') echo '{"interface":[{"interface":"lan","proto":"static"}]}' ;;
	'call network.device status') echo '{"eth3":{"present":true}}' ;;
	'call service list') echo services ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
read -r data
case "$data:$2" in
	*:'@.up') echo true ;;
	'lan:@.l3_device') echo br-lan ;;
	'wan:@.l3_device') echo eth1 ;;
	'policy:@.l3_device') echo eth2 ;;
	'new_policy:@.l3_device') echo "${TEST_NEW_DEVICE:-eth3}" ;;
	'lan:@["ipv4-address"][0].address') echo "${TEST_MANAGEMENT_IP:-192.168.1.1}" ;;
	'wan:@["ipv4-address"][0].address') echo 10.1.0.2 ;;
	'policy:@["ipv4-address"][0].address') echo "${TEST_POLICY_ADDRESS:-10.2.0.2}" ;;
	'new_policy:@["ipv4-address"][0].address') echo "${TEST_NEW_ADDRESS:-10.3.0.2}" ;;
	'lan:@["ipv4-address"][0].mask') echo "${TEST_ACCESS_PREFIX:-24}" ;;
	*:'@["ipv4-address"][0].mask') echo 24 ;;
	'lan:@.route[@.target="0.0.0.0"].nexthop') echo "${TEST_ACCESS_GATEWAY:-192.168.1.254}" ;;
	'wan:@.route[@.target="0.0.0.0"].nexthop') echo "${TEST_GATEWAY:-10.1.0.1}" ;;
	'policy:@.route[@.target="0.0.0.0"].nexthop') echo "${TEST_POLICY_GATEWAY:-10.2.0.1}" ;;
	'new_policy:@.route[@.target="0.0.0.0"].nexthop') echo 10.3.0.1 ;;
	'services:@dnsmasq.instances.*.running'|'services:@.dnsmasq.instances.*.running'|'services:@.dropbear.instances.*.running'|'services:@.odhcpd.instances.*.running') [ "${TEST_SERVICE_DOWN:-0}" != 1 ] && echo true || echo false ;;
	*:'@.interface[*].l3_device') [ -z "${TEST_DYNAMIC_CLAIM:-}" ] || echo "$TEST_DYNAMIC_CLAIM" ;;
	*:'@.interface[*].device') : ;;
	*:'@.interface') echo '[]' ;;
esac
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
	'-4 rule show')
		printf '%s\n' '0: from all lookup local' '32766: from all lookup main'
		[ "${TEST_RULE_CONFLICT:-0}" = 0 ] || echo '12000: from all lookup 250'
		[ "${TEST_UNMARKED_RULE:-0}" = 0 ] || echo '1000: from all lookup 123' ;;
	'-4 route show table 200')
		case "${TEST_TABLE_ERROR:-none}" in
			absent) printf '%s\n' 'Error: ipv4: FIB table does not exist.' 'Dump terminated' >&2; exit 2 ;;
			permission) echo 'RTNETLINK answers: Operation not permitted' >&2; exit 2 ;;
		esac
		[ "${TEST_TABLE_CONFLICT:-0}" = 0 ] || echo 'default via 10.9.0.1 dev eth9' ;;
	'-4 -o addr show'|'-o addr show')
		if [ -n "${TEST_LOCAL_ADDRESS_LINES:-}" ]; then printf '%s\n' "$TEST_LOCAL_ADDRESS_LINES"
		else printf '%s\n' '2: br-lan inet 192.168.1.1/24 brd 192.168.1.255' '3: eth1 inet 10.1.0.2/24 brd 10.1.0.255'; fi
		[ -z "${TEST_OTHER_ADDRESS:-}" ] || echo "$TEST_OTHER_ADDRESS" ;;
	'-4 route show table main default')
		echo "default via ${TEST_DEFAULT_GATEWAY:-10.1.0.1} dev ${TEST_DEFAULT_DEVICE:-eth1} proto static metric ${TEST_DEFAULT_METRIC:-0}"
		echo "default via 10.2.0.1 dev eth2 proto static metric ${TEST_POLICY_METRIC:-200}"
		[ -z "${TEST_THIRD_DEFAULT:-}" ] || echo "$TEST_THIRD_DEFAULT" ;;
	'-4 route get fibmatch '*)
		printf '%s\n' "$*" >>"$TEST_TOPOLOGY_DIR/fib.log"
		if [ "${TEST_FIB_CONNECTED:-0}" = 1 ]; then echo '198.18.0.0/15 dev eth9 proto kernel'; exit 0; fi
		device=${TEST_FIB_DEVICE:-${TEST_DEFAULT_DEVICE:-eth1}}
		case "$*" in *' from '*)
			device=${TEST_FORWARDED_DEVICE:-$device}
			source=$(printf '%s\n' "$*" | awk '{for(i=1;i<NF;i++)if($i=="from")print $(i+1)}')
			if [ -n "${TEST_EXPECT_FIB_SOURCE:-}" ] && [ "$source" != "$TEST_EXPECT_FIB_SOURCE" ]; then echo "unexpected FIB source: $source" >&2; exit 2; fi
			if [ "${TEST_FAIL_LOCAL_FIB:-0}" = 1 ] && "$0" -4 -o addr show | awk -v ip="$source" '{split($4,a,"/");if(a[1]==ip)found=1}END{exit !found}'; then echo 'RTNETLINK answers: Invalid argument' >&2; exit 2; fi
			;; esac
		echo "default via ${TEST_DEFAULT_GATEWAY:-10.1.0.1} dev $device proto static ${TEST_FIB_TABLE:-}" ;;
	'-4 route show table all') [ -z "${TEST_EXTRA_ROUTE:-}" ] || echo "$TEST_EXTRA_ROUTE" ;;
	'-6 rule show') : ;;
	'-4 -o addr show dev eth3') [ -z "${TEST_LINK_IPV4:-}" ] || echo "$TEST_LINK_IPV4" ;;
	'-6 -o addr show dev eth3') echo "${TEST_LINK_IPV6:-5: eth3 inet6 fe80::1/64 scope link proto kernel_ll}" ;;
	'-4 route show table all dev eth3') [ -z "${TEST_LINK_ROUTE4:-}" ] || echo "$TEST_LINK_ROUTE4" ;;
	'-6 route show table all dev eth3')
		printf '%s\n' 'fe80::/64 proto kernel metric 256 pref medium' 'anycast fe80:: table local proto kernel metric 0 pref medium' 'local fe80::1 table local proto kernel metric 0 pref medium' 'multicast ff00::/8 table local proto kernel metric 256 pref medium'
		[ -z "${TEST_LINK_ROUTE6:-}" ] || echo "$TEST_LINK_ROUTE6" ;;
	*) printf 'unexpected ip command: %s\n' "$*" >>"$TEST_TOPOLOGY_DIR/writes"; exit 1 ;;
esac
exit 0
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list ruleset') [ "${TEST_NFT_MARK:-0}" = 0 ] || echo 'meta mark set 0x100' ;;
	'-n list table inet fw4')
		[ "${TEST_MISSING_RULE:-0}" = 0 ] || exit 1
		cat "${TEST_NFT_FILE:-$TEST_TOPOLOGY_DIR/nft}"
		;;
	*) printf 'unexpected nft write: %s\n' "$*" >>"$TEST_TOPOLOGY_DIR/writes"; exit 1 ;;
esac
exit 0
EOF
cat >"$tmp/bin/fw4" <<'EOF'
#!/bin/sh
[ "$*" = check ] || { echo 'unexpected fw4 write' >>"$TEST_TOPOLOGY_DIR/writes"; exit 1; }
[ "${TEST_FW4_INVALID:-0}" = 0 ]
EOF
cat >"$tmp/bin/netstat" <<'EOF'
#!/bin/sh
[ "$*" = -lnptu ] || exit 1
[ "${TEST_NO_DNS:-0}" = 0 ] || exit 0
echo 'udp 0 0 0.0.0.0:53 0.0.0.0:* 122/dnsmasq'
EOF
cat >"$tmp/bin/arping" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_TOPOLOGY_DIR/arping.log"
[ "${TEST_ARPING_FORBIDDEN:-0}" = 0 ] || exit 99
[ "${TEST_IDENTITY_DURING_ARP:-0}" = 0 ] || echo '02:00:00:00:00:04' >"$ROUTEPOLICY_ROOT/sys/class/net/eth3/address"
[ "${TEST_ADDRESS_CONFLICT:-0}" = 0 ]
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_TOPOLOGY_DIR/sleep.log"
[ "${TEST_CARRIER_AFTER_SLEEP:-0}" = 0 ] || echo 1 >"$ROUTEPOLICY_ROOT/sys/class/net/eth3/carrier"
[ "${TEST_IDENTITY_AFTER_SLEEP:-0}" = 0 ] || echo 6 >"$ROUTEPOLICY_ROOT/sys/class/net/eth3/ifindex"
exit 0
EOF
chmod +x "$tmp/bin/"*
baseline() {
	cat >"$tmp/config" <<'EOF'
network.lan	interface
network.lan.proto	static
network.lan.device	br-lan
network.wan	interface
network.wan.proto	dhcp
network.wan.device	eth1
network.policy	interface
network.policy.proto	dhcp
network.policy.device	eth2
dhcp.lan	dhcp
dhcp.lan.interface	lan
dhcp.lan.ignore	0
dhcp.other	dhcp
dhcp.other.interface	other
dhcp.other.ignore	0
firewall.@zone[0]	zone
firewall.@zone[0].name	lan
firewall.@zone[0].network	lan
firewall.@zone[0].input	ACCEPT
firewall.@zone[1]	zone
firewall.@zone[1].name	wan
firewall.@zone[1].network	wan
firewall.@zone[1].input	REJECT
firewall.@zone[2]	zone
firewall.@zone[2].name	policy
firewall.@zone[2].network	policy
firewall.@zone[2].input	REJECT
EOF
	for dev in all br-lan eth1 eth2 eth3; do
		mkdir -p "$tmp/root/proc/sys/net/ipv4/conf/$dev"
		echo 0 >"$tmp/root/proc/sys/net/ipv4/conf/$dev/rp_filter"
	done
	echo 1 >"$tmp/root/proc/sys/net/ipv4/ip_forward"
	echo 5 >"$tmp/root/sys/class/net/eth3/ifindex"
	echo 5 >"$tmp/root/sys/class/net/eth3/iflink"
	echo '02:00:00:00:00:03' >"$tmp/root/sys/class/net/eth3/address"
	echo 0x1003 >"$tmp/root/sys/class/net/eth3/flags"
	echo 1 >"$tmp/root/sys/class/net/eth3/carrier"
	# Numeric families, ICMP types and drop jumps mirror OpenWrt 25.12 / nft 1.1.6.
	cat >"$tmp/nft" <<'RULES'
table inet fw4 {
	chain input {
		type filter hook input priority 0; policy drop;
		iifname "br-lan" jump input_lan comment "!fw4: Handle lan IPv4/IPv6 input traffic"
	}
	chain forward {
		type filter hook forward priority 0; policy drop;
		iifname "br-lan" jump forward_lan comment "!fw4: Handle lan IPv4/IPv6 forward traffic"
	}
	chain output {
		type filter hook output priority 0; policy accept;
		oifname "br-lan" jump output_lan comment "!fw4: Handle lan IPv4/IPv6 output traffic"
	}
	chain forward_lan {
		ip saddr 192.168.1.0/24 counter packets 0 bytes 0 jump accept_to_wan comment "!fw4: routepolicy-init-default4"
		ip saddr 192.168.1.0/24 counter packets 0 bytes 0 jump accept_to_policy comment "!fw4: routepolicy-init-policy4"
		meta nfproto 10 counter packets 0 bytes 0 jump handle_reject comment "!fw4: routepolicy-init-ipv6"
		jump accept_to_wan comment "!fw4: Accept lan to wan forwarding"
		jump accept_to_lan
	}
	chain accept_to_wan {
		oifname "eth1" counter packets 0 bytes 0 accept comment "!fw4: accept wan IPv4/IPv6 traffic"
	}
	chain accept_from_wan {
		iifname "eth1" counter packets 0 bytes 0 accept comment "!fw4: accept wan IPv4/IPv6 traffic"
	}
	chain accept_to_policy {
		oifname "eth2" counter packets 0 bytes 0 accept comment "!fw4: accept policy IPv4/IPv6 traffic"
	}
	chain handle_reject {
		reject comment "!fw4: Reject any other traffic"
	}
	chain srcnat_wan {
		ip saddr 192.168.1.0/24 counter packets 0 bytes 0 masquerade comment "!fw4: routepolicy-init-default-nat"
	}
	chain srcnat_policy {
		ip saddr 192.168.1.0/24 counter packets 0 bytes 0 masquerade comment "!fw4: routepolicy-init-policy-nat"
	}
	chain srcnat {
		type nat hook postrouting priority 100; policy accept;
		oifname "eth1" jump srcnat_wan comment "!fw4: Handle wan IPv4/IPv6 srcnat traffic"
		oifname "eth2" jump srcnat_policy comment "!fw4: Handle policy IPv4/IPv6 srcnat traffic"
	}
	chain input_lan {
		ip saddr 192.168.1.0/24 tcp dport 53 counter packets 0 bytes 0 accept comment "!fw4: routepolicy-init-dns"
		ip saddr 192.168.1.0/24 udp dport 53 counter packets 0 bytes 0 accept comment "!fw4: routepolicy-init-dns"
	}
	chain output_lan {
		meta nfproto 2 udp sport 67 udp dport 68 counter packets 0 bytes 0 jump drop_to_lan comment "!fw4: routepolicy-init-dhcp4"
		meta nfproto 10 udp sport 547 udp dport 546 counter packets 0 bytes 0 jump drop_to_lan comment "!fw4: routepolicy-init-dhcp6"
		icmpv6 type 134 counter packets 1 bytes 104 jump drop_to_lan comment "!fw4: routepolicy-init-ra"
		icmp type 5 counter packets 0 bytes 0 jump drop_to_lan comment "!fw4: routepolicy-init-redirects"
	}
	chain drop_to_lan {
		oifname "br-lan" counter packets 1 bytes 104 drop comment "!fw4: drop lan IPv4/IPv6 traffic"
	}
	chain input_wan {
		meta nfproto 2 udp sport 67 udp dport 68 counter packets 0 bytes 0 accept comment "!fw4: routepolicy-init-default_dhcp_client"
	}
	chain input_policy {
		meta nfproto 2 udp sport 67 udp dport 68 counter packets 0 bytes 0 accept comment "!fw4: routepolicy-init-policy_dhcp_client"
	}
}
RULES
}
reject() {
	if "$@" >"$tmp/rejected" 2>"$tmp/error"; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi
}
apply_mock_plan() {
	awk -F '\t' '$1=="set"{print $2 "\t" $3}' "$1" >>"$tmp/config"
	awk -F '\t' '{if(!($1 in v))keys[++n]=$1;v[$1]=$2}END{for(i=1;i<=n;i++)print keys[i] "\t" v[keys[i]]}' "$tmp/config" >"$tmp/config.new"
	mv "$tmp/config.new" "$tmp/config"
}
insert_forward_rule() {
	TEST_RULE_TEXT="$1" awk '/chain forward_lan \{/{print;print ENVIRON["TEST_RULE_TEXT"];next}{print}' "$tmp/nft" >"$2"
}
baseline
cp "$tmp/config" "$tmp/before"
"$tool" discover >"$tmp/discover"
grep -Fq '"dhcp_roles":[' "$tmp/discover"
grep -Fq '"devices":{"eth3"' "$tmp/discover"
grep -Fq 'existing conntrack sessions are not forcibly cut off' "$tmp/discover"
"$tool" plan lan wan policy >"$tmp/plan"
cmp "$tmp/config" "$tmp/before"
awk '/chain forward_lan \{/{print;print "meta nfproto 2 counter packets 0 bytes 0 drop comment \"!fw4: existing IPv4 deny-all\"";next}{print}' "$tmp/nft" >"$tmp/early-ipv4-drop.nft"
reject env TEST_NFT_FILE="$tmp/early-ipv4-drop.nft" "$tool" plan lan wan policy
grep -Fq 'IPv4 forwarding' "$tmp/error"
ipv4_bad=0
for verdict in \
	'meta nfproto ipv4 counter drop' \
	'meta nfproto 2 drop' \
	'meta nfproto 2 counter packets 9 bytes 1500 reject with icmp type admin-prohibited' \
	'meta nfproto 2 counter jump handle_reject' \
	'meta nfproto 2 counter jump drop_to_wan' \
	'meta nfproto 2 counter jump reject_to_policy' \
	'meta nfproto 2 counter name "deny_stats" drop' \
	'ip saddr 0.0.0.0/0 counter drop' \
	'ip daddr 0.0.0.0/0 counter reject' \
	'meta nfproto 2 counter packets 0 bytes 0 log prefix "review-existing-lan-all-drop: " drop comment "!fw4: review-existing-lan-all-drop"' \
	'meta nfproto ipv4 log prefix "quoted \"drop\" and \\ slash" counter packets 9 bytes 1500 reject with icmp type admin-prohibited' \
	'meta nfproto 2 log prefix "comment \"!fw4: routepolicy-init-default4\" accept jump return" counter drop' \
	'meta nfproto 2 counter log prefix "meta nfproto ipv6 } chain forward_lan {" drop' \
	'meta nfproto 2 log counter drop' \
	'ip saddr 192.168.1.0/24 counter log prefix "LAN deny" drop' \
	'ip saddr 192.168.0.0/16 log prefix "overlap" counter reject' \
	'ip saddr 192.168.1.9 counter drop' \
	'meta nfproto 2 iifname "br-lan" counter log prefix "deny" drop' \
	'meta nfproto 2 counter log prefix "return" return' \
	'meta nfproto 2 counter log prefix "jump" jump custom_path' \
	'meta nfproto 2 counter goto accept_to_wan' \
	'meta nfproto 2 meta mark set 0x100 counter accept' \
	'ip saddr 198.51.100.0/24 ip daddr { 1.1.1.1, 2.2.2.2 } counter drop' \
	'meta nfproto 2 limit rate 10/second log prefix "limited" drop' \
	'meta nfproto 2 log group 1 counter drop'; do
	ipv4_bad=$((ipv4_bad + 1))
	insert_forward_rule "$verdict" "$tmp/blocked4-$ipv4_bad.nft"
	reject env TEST_NFT_FILE="$tmp/blocked4-$ipv4_bad.nft" "$tool" plan lan wan policy
	grep -Fq 'IPv4 forwarding' "$tmp/error"
done
ipv4_safe=0
for rule in \
	'meta nfproto 2 log prefix "drop reject return \"quoted\" \\ slash" counter packets 1 bytes 50' \
	'meta nfproto ipv4 counter name "drop" log prefix "comment \"!fw4: routepolicy-init-default4\""' \
	'ip saddr 198.51.100.0/24 log prefix "drop" counter drop' \
	'ip saddr 192.168.2.0/24 counter log prefix "reject" reject' \
	'meta nfproto 2 ip saddr 198.51.100.0/24 udp dport 53 log prefix "drop" drop' \
	'meta nfproto 2 iifname "br-other" log prefix "drop" counter drop' \
	'meta nfproto 2 oifname "eth9" counter log prefix "drop" drop' \
	'meta nfproto 2 oifname "eth1" tcp dport 80 counter log prefix "drop is data" accept'; do
	ipv4_safe=$((ipv4_safe + 1))
	insert_forward_rule "$rule" "$tmp/safe4-$ipv4_safe.nft"
	TEST_NFT_FILE="$tmp/safe4-$ipv4_safe.nft" "$tool" plan lan wan policy >"$tmp/safe4-plan"
	cmp "$tmp/plan" "$tmp/safe4-plan"
done
for rule in \
	'meta nfproto 10 counter log prefix "drop is IPv6-only" drop' \
	'ip6 saddr 2001:db8::/64 log prefix "IPv6 drop" counter drop' \
	'icmpv6 type 134 counter log prefix "IPv6 reject" drop'; do
	ipv4_safe=$((ipv4_safe + 1))
	TEST_RULE_TEXT="$rule" awk '{print} /comment "!fw4: routepolicy-init-ipv6"/{print ENVIRON["TEST_RULE_TEXT"]}' "$tmp/nft" >"$tmp/safe4-$ipv4_safe.nft"
	TEST_NFT_FILE="$tmp/safe4-$ipv4_safe.nft" "$tool" plan lan wan policy >"$tmp/safe4-plan"
	cmp "$tmp/plan" "$tmp/safe4-plan"
done
grep -Fq 'set	dhcp.lan.ignore	1' "$tmp/plan"
grep -Fq 'set	dhcp.lan.ra	disabled' "$tmp/plan"
grep -Fq 'set	firewall.rp_init_default4.src_ip	192.168.1.0/24' "$tmp/plan"
grep -Fq 'set	firewall.rp_init_policy_nat.target	MASQUERADE' "$tmp/plan"
grep -Fq 'set	firewall.rp_init_ipv6.dest	*' "$tmp/plan"
grep -Fq 'set	firewall.rp_init_policy_dhcp_client.src_port	67' "$tmp/plan"
grep -Fq 'set	firewall.rp_init_policy_dhcp_client.dest_port	68' "$tmp/plan"
if grep -Fq '.rpfilter' "$tmp/plan"; then echo 'plan wrote ineffective interface rpfilter' >&2; exit 1; fi
for global in 0 1 2; do
	for specific in 0 1 2; do
		echo "$global" >"$tmp/root/proc/sys/net/ipv4/conf/all/rp_filter"
		for dev in br-lan eth1 eth2; do echo "$specific" >"$tmp/root/proc/sys/net/ipv4/conf/$dev/rp_filter"; done
		case "$global:$specific" in
			0:1|1:0|1:1)
				reject "$tool" plan lan wan policy
				[ ! -s "$tmp/rejected" ]
				grep -Fq 'effective=1' "$tmp/error"
				;;
			*) "$tool" plan lan wan policy >"$tmp/rp-filter-plan"; cmp "$tmp/plan" "$tmp/rp-filter-plan" ;;
		esac
		[ "$(cat "$tmp/root/proc/sys/net/ipv4/conf/all/rp_filter")" = "$global" ]
		[ "$(cat "$tmp/root/proc/sys/net/ipv4/conf/br-lan/rp_filter")" = "$specific" ]
	done
done
baseline
if grep -Eq 'dhcp\.other|network\.(wan|policy)\.proto|firewall\.@zone' "$tmp/plan"; then echo 'plan changed an unowned boundary' >&2; exit 1; fi
reject "$tool" plan 'lan;touch bad' wan policy
reject "$tool" plan lan wan lan
reject env TEST_GATEWAY=192.168.1.1 "$tool" plan lan wan policy
reject env TEST_RULE_CONFLICT=1 "$tool" plan lan wan policy
reject env TEST_TABLE_CONFLICT=1 "$tool" plan lan wan policy
reject env TEST_TABLE_ERROR=permission "$tool" plan lan wan policy
TEST_TABLE_ERROR=absent "$tool" plan lan wan policy >"$tmp/empty-table"
cmp "$tmp/plan" "$tmp/empty-table"
reject env TEST_NFT_MARK=1 "$tool" plan lan wan policy
reject env TEST_FW4_INVALID=1 "$tool" plan lan wan policy
TEST_DEFAULT_DEVICE=br-lan TEST_DEFAULT_GATEWAY=192.168.1.254 "$tool" plan lan lan policy >"$tmp/one-arm"
grep -Fq 'set	firewall.rp_init_default4.dest	lan' "$tmp/one-arm"
grep -Fq 'set	firewall.rp_init_redirects.icmp_type	redirect' "$tmp/one-arm"
"$tool" plan lan wan policy - - - - - - 192.168.1.2 24 >"$tmp/management"
grep -Fq 'set	network.lan.ipaddr	192.168.1.2' "$tmp/management"
reject env TEST_ADDRESS_CONFLICT=1 "$tool" plan lan wan policy - - - - - - 192.168.1.2 24
reject "$tool" plan lan wan policy - - - - - - 192.168.1.255 24
bad_address=$(printf '192.168.1.2\n192.168.1.3')
reject "$tool" plan lan wan policy - - - - - - "$bad_address" 24
"$tool" plan lan wan rp_init_policy policy eth3 dhcp - - - - - >"$tmp/new-dhcp"
grep -Fq 'set	network.rp_init_policy.proto	dhcp' "$tmp/new-dhcp"
grep -Fq 'set	firewall.rp_init_policy.input	REJECT' "$tmp/new-dhcp"
"$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - - >"$tmp/new-static"
grep -Fq 'set	network.rp_init_policy.gateway	10.3.0.1' "$tmp/new-static"
"$tool" link-plan lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - - >"$tmp/link-up"
grep -Fxq 'dad	clear' "$tmp/link-up"
echo 0x1002 >"$tmp/root/sys/class/net/eth3/flags"
echo 0 >"$tmp/root/sys/class/net/eth3/carrier"
TEST_ARPING_FORBIDDEN=1 "$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - - >"$tmp/new-static-down" 2>"$tmp/link-warning"
cmp "$tmp/new-static" "$tmp/new-static-down"
grep -Fq 'ARP-DAD pending' "$tmp/link-warning"
[ "$(cat "$tmp/root/sys/class/net/eth3/flags")" = 0x1002 ]
TEST_ARPING_FORBIDDEN=1 "$tool" link-plan lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - - >"$tmp/link-down"
grep -Fxq 'up	0' "$tmp/link-down"
grep -Fxq 'dad	pending-link-up' "$tmp/link-down"
grep -Fxq 'mac	02:00:00:00:00:03' "$tmp/link-down"
reject "$tool" link-dad lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
echo 0x1003 >"$tmp/root/sys/class/net/eth3/flags"
reject "$tool" link-dad lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
[ "$(wc -l <"$tmp/sleep.log" | tr -d ' ')" = 10 ]
TEST_CARRIER_AFTER_SLEEP=1 "$tool" link-dad lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - - >"$tmp/link-dad"
grep -Fxq 'dad	clear' "$tmp/link-dad"
reject env TEST_ADDRESS_CONFLICT=1 "$tool" link-dad lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
reject env TEST_IDENTITY_DURING_ARP=1 "$tool" link-dad lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
echo '02:00:00:00:00:03' >"$tmp/root/sys/class/net/eth3/address"
echo 0 >"$tmp/root/sys/class/net/eth3/carrier"
reject env TEST_IDENTITY_AFTER_SLEEP=1 "$tool" link-dad lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
echo 5 >"$tmp/root/sys/class/net/eth3/ifindex"
echo 1 >"$tmp/root/sys/class/net/eth3/carrier"
"$tool" link-unclaimed lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - - >"$tmp/unclaimed"
grep -Fxq 'unclaimed	1' "$tmp/unclaimed"
reject env TEST_DYNAMIC_CLAIM=eth3 "$tool" link-unclaimed lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
reject env TEST_LINK_IPV4='5: eth3 inet 10.3.0.5/24 scope global' "$tool" link-unclaimed lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
reject env TEST_LINK_IPV6='5: eth3 inet6 2001:db8::1/64 scope global' "$tool" link-unclaimed lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
reject env TEST_LINK_ROUTE4='default via 10.3.0.1' "$tool" link-unclaimed lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
reject env TEST_LINK_ROUTE6='2001:db8::/64 proto static metric 10' "$tool" link-unclaimed lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
reject env TEST_LINK_ROUTE6='multicast ff00::/8 table local proto static metric 256' "$tool" link-unclaimed lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
printf 'network.rp_init_policy\tinterface\nnetwork.rp_init_policy.device\teth3\nnetwork.rp_init_policy.proto\tstatic\n' >>"$tmp/config"
[ "$("$tool" management-address lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -)" = 192.168.1.1 ]
reject env TEST_NEW_DEVICE=eth9 "$tool" management-address lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
reject env TEST_NEW_ADDRESS=10.3.0.3 "$tool" management-address lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
baseline
printf 'network.other\tdevice\nnetwork.other.ports\teth3\n' >>"$tmp/config"
reject "$tool" link-unclaimed lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
baseline
reject "$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.4.0.1 - -
mkdir "$tmp/root/sys/class/net/eth3/bridge"
reject "$tool" plan lan wan rp_init_policy policy eth3 dhcp - - - - -
rmdir "$tmp/root/sys/class/net/eth3/bridge"
printf 'firewall.rp_init_dns\trule\n' >>"$tmp/config"
reject "$tool" plan lan wan policy
baseline
sed 's/\.network	lan$/.network	lan other/' "$tmp/config" >"$tmp/config.new"
mv "$tmp/config.new" "$tmp/config"
reject "$tool" plan lan wan policy
baseline
cat >>"$tmp/config" <<'EOF'
firewall.custom	rule
firewall.custom.src	lan
firewall.custom.dest	wan
firewall.custom.target	ACCEPT
EOF
reject "$tool" plan lan wan policy
baseline
# A clean official chain is safe before the managed IPv6 rule exists.
grep -v 'routepolicy-init-' "$tmp/nft" >"$tmp/official-before.nft"
TEST_NFT_FILE="$tmp/official-before.nft" "$tool" plan lan wan policy >"$tmp/official-before-plan"
cmp "$tmp/plan" "$tmp/official-before-plan"
mkdir -p "$tmp/root/etc/nftables.d"
cat >"$tmp/root/etc/nftables.d/10-custom-filter-chains.nft" <<'EOF'
## Official firewall4 ships this file as comments and whitespace only.
# chain user_pre_forward {
#     type filter hook forward priority -1; policy accept;
#     meta nfproto ipv6 accept
# }
EOF
"$tool" plan lan wan policy >"$tmp/official-comment-include-plan"
cmp "$tmp/plan" "$tmp/official-comment-include-plan"
printf 'chain forward_lan { meta nfproto ipv6 accept; }\n' >>"$tmp/root/etc/nftables.d/10-custom-filter-chains.nft"
reject "$tool" plan lan wan policy
rm "$tmp/root/etc/nftables.d/10-custom-filter-chains.nft"
awk '/chain forward_lan \{/{print;print "meta nfproto ipv6 accept";next}{print}' "$tmp/nft" >"$tmp/early-access-accept.nft"
awk '/chain forward \{/{print;print "meta nfproto 10 accept";next}{print}' "$tmp/nft" >"$tmp/early-root-accept.nft"
awk '/chain handle_reject \{/{print;print "meta nfproto 10 accept";next}{print}' "$tmp/nft" >"$tmp/early-reject-accept.nft"
for poisoned in early-access-accept early-root-accept early-reject-accept; do
	reject env TEST_NFT_FILE="$tmp/$poisoned.nft" "$tool" plan lan wan policy
	grep -Fq 'IPv6 control flow' "$tmp/error"
done
printf 'firewall.early\tinclude\nfirewall.early.type\tnftables\nfirewall.early.chain\tforward_lan\n' >>"$tmp/config"
reject "$tool" plan lan wan policy
baseline
reject env TEST_POLICY_METRIC=0 "$tool" plan lan wan policy
reject env TEST_UNMARKED_RULE=1 "$tool" plan lan wan policy
reject env TEST_FIB_DEVICE=eth2 "$tool" plan lan wan policy
reject env TEST_FORWARDED_DEVICE=eth2 "$tool" plan lan wan policy
reject env TEST_FIB_CONNECTED=1 "$tool" plan lan wan policy
reject env TEST_FIB_TABLE='table 123' "$tool" plan lan wan policy
reject env TEST_DEFAULT_METRIC=300 TEST_POLICY_METRIC=400 "$tool" plan lan wan rp_init_policy policy eth3 dhcp - - - - -
TEST_DEFAULT_DEVICE=eth2 TEST_DEFAULT_GATEWAY=10.2.0.1 TEST_POLICY_METRIC=0 "$tool" plan lan rp_init_default policy default eth3 dhcp - - - - - >"$tmp/new-default"
grep -Fxq 'set	network.policy.metric	200' "$tmp/new-default"
grep -Fxq 'set	network.rp_init_default.metric	10' "$tmp/new-default"
reject env TEST_DEFAULT_DEVICE=eth2 TEST_DEFAULT_GATEWAY=10.2.0.1 TEST_POLICY_METRIC=0 TEST_THIRD_DEFAULT='default via 10.9.0.1 dev eth9 metric 0' "$tool" plan lan rp_init_default policy default eth3 dhcp - - - - -
"$tool" link-plan lan wan rp_init_policy policy eth3 dhcp - - - - - >"$tmp/dhcp-identity"
grep -Fxq 'required	1' "$tmp/dhcp-identity"
grep -Fxq 'dad_required	0' "$tmp/dhcp-identity"
grep -Fxq 'target	-' "$tmp/dhcp-identity"
grep -Fxq 'dad	not-required' "$tmp/dhcp-identity"
echo '02:00:00:00:00:04' >"$tmp/root/sys/class/net/eth3/address"
"$tool" link-plan lan wan rp_init_policy policy eth3 dhcp - - - - - >"$tmp/dhcp-identity-new-mac"
if cmp -s "$tmp/dhcp-identity" "$tmp/dhcp-identity-new-mac"; then echo 'DHCP physical identity was not captured' >&2; exit 1; fi
baseline
printf 'network.other\tinterface\nnetwork.other.ipaddr\t10.3.0.1/24\n' >>"$tmp/config"
reject "$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.200 25 10.3.0.129 - -
baseline
printf 'network.other\tinterface\nnetwork.other.ipaddr\t10.3.0.129/25\n' >>"$tmp/config"
reject "$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
baseline
printf 'network.other\tinterface\nnetwork.other.ipaddr\t10.3.0.1\nnetwork.other.netmask\t255.255.255.0\n' >>"$tmp/config"
reject "$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.200 25 10.3.0.129 - -
baseline
printf 'network.other\tinterface\nnetwork.other.ipaddr\t10.3.0.1/25\n' >>"$tmp/config"
"$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.200 25 10.3.0.129 - - >"$tmp/adjacent"
baseline
reject env TEST_OTHER_ADDRESS='9: eth9 inet 10.3.0.1/24 brd 10.3.0.255' "$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.200 25 10.3.0.129 - -
reject env TEST_EXTRA_ROUTE='10.3.0.0/24 via 10.1.0.1 dev eth1 proto static' "$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.200 25 10.3.0.129 - -
reject env TEST_EXTRA_ROUTE='10.3.0.128/25 dev eth9 proto kernel scope link' "$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.2 24 10.3.0.1 - -
TEST_EXTRA_ROUTE='10.3.0.0/25 dev eth9 proto kernel scope link' "$tool" plan lan wan rp_init_policy policy eth3 static 10.3.0.200 25 10.3.0.129 - - >"$tmp/adjacent-route"
# DHCP overlap becomes knowable after obtaining the lease and must block verify.
printf 'network.rp_init_policy\tinterface\nnetwork.rp_init_policy.device\teth3\nnetwork.rp_init_policy.proto\tdhcp\nnetwork.other\tinterface\nnetwork.other.ipaddr\t10.3.0.1/24\n' >>"$tmp/config"
reject "$tool" verify lan wan rp_init_policy policy eth3 dhcp - - - - -
grep -Fq 'address overlap' "$tmp/error"
baseline
# Simulate the coordinator's allowed writes without any runtime network changes.
apply_mock_plan "$tmp/plan"
"$tool" verify lan wan policy >"$tmp/verify"
grep -Fq '"packet_evidence":"EVIDENCE_MISSING"' "$tmp/verify"
grep -Fq 'preserve-existing-conntrack-and-management' "$tmp/verify"
reject env TEST_NFT_FILE="$tmp/early-ipv4-drop.nft" "$tool" verify lan wan policy
grep -Fq 'IPv4 forwarding' "$tmp/error"
for blocked in "$tmp"/blocked4-*.nft; do
	reject env TEST_NFT_FILE="$blocked" "$tool" verify lan wan policy
	grep -Fq 'IPv4 forwarding' "$tmp/error"
done
for safe in "$tmp"/safe4-*.nft; do TEST_NFT_FILE="$safe" "$tool" verify lan wan policy >"$tmp/verify-safe4"; done
TEST_RULE_TEXT='meta nfproto 2 oifname "eth1" ct state 0x1 counter packets 0 bytes 0 log prefix "NAT leakage drop: " drop' \
	awk '/chain accept_to_wan \{/{print;print ENVIRON["TEST_RULE_TEXT"];next}{print}' "$tmp/nft" >"$tmp/official-nat-leak.nft"
TEST_NFT_FILE="$tmp/official-nat-leak.nft" "$tool" verify lan wan policy >"$tmp/verify-nat-leak"
TEST_RULE_TEXT='meta nfproto 2 counter log prefix "hidden drop" drop' \
	awk '/chain accept_to_wan \{/{print;print ENVIRON["TEST_RULE_TEXT"];next}{print}' "$tmp/nft" >"$tmp/early-helper-drop.nft"
reject env TEST_NFT_FILE="$tmp/early-helper-drop.nft" "$tool" verify lan wan policy
grep -Fq 'IPv4 forwarding' "$tmp/error"
awk '{print} /comment "!fw4: routepolicy-init-default4"/{print "meta nfproto 2 counter drop"}' "$tmp/nft" >"$tmp/between-ipv4-allows.nft"
reject env TEST_NFT_FILE="$tmp/between-ipv4-allows.nft" "$tool" verify lan wan policy
grep -Fq 'IPv4 forwarding' "$tmp/error"
awk '{print} /comment "!fw4: routepolicy-init-policy4"/{print "meta nfproto 2 counter drop"}' "$tmp/nft" >"$tmp/after-ipv4-allows.nft"
TEST_NFT_FILE="$tmp/after-ipv4-allows.nft" "$tool" verify lan wan policy >"$tmp/verify-after-ipv4-allows"
awk '/chain forward_lan \{/{print;print "ip saddr 198.51.100.0/24 counter drop";next}{print}' "$tmp/nft" >"$tmp/conditional-ipv4-drop.nft"
TEST_NFT_FILE="$tmp/conditional-ipv4-drop.nft" "$tool" verify lan wan policy >"$tmp/verify-conditional-ipv4"
for poisoned in early-access-accept early-root-accept early-reject-accept; do
	reject env TEST_NFT_FILE="$tmp/$poisoned.nft" "$tool" verify lan wan policy
	grep -Fq 'IPv6 control flow' "$tmp/error"
done
reject env TEST_FIB_DEVICE=eth2 "$tool" verify lan wan policy
reject env TEST_FORWARDED_DEVICE=eth2 "$tool" verify lan wan policy
sed -e 's/meta nfproto 2 /meta nfproto ipv4 /g' -e 's/meta nfproto 10 /meta nfproto ipv6 /g' \
	-e 's/icmpv6 type 134 /icmpv6 type nd-router-advert /g' -e 's/icmp type 5 /icmp type redirect /g' "$tmp/nft" >"$tmp/symbolic.nft"
TEST_NFT_FILE="$tmp/symbolic.nft" "$tool" verify lan wan policy >"$tmp/verify-symbolic"
sed 's/meta nfproto 10 counter/meta nfproto 2 counter/' "$tmp/nft" >"$tmp/wrong-family.nft"
reject env TEST_NFT_FILE="$tmp/wrong-family.nft" "$tool" verify lan wan policy
sed 's/chain forward_lan {/chain wrong_direction {/' "$tmp/nft" >"$tmp/wrong-chain.nft"
reject env TEST_NFT_FILE="$tmp/wrong-chain.nft" "$tool" verify lan wan policy
sed 's/hook forward /hook output /' "$tmp/nft" >"$tmp/wrong-hook.nft"
reject env TEST_NFT_FILE="$tmp/wrong-hook.nft" "$tool" verify lan wan policy
sed 's/oifname "eth2" jump srcnat_policy/oifname "eth9" jump srcnat_policy/' "$tmp/nft" >"$tmp/wrong-egress.nft"
reject env TEST_NFT_FILE="$tmp/wrong-egress.nft" "$tool" verify lan wan policy
sed 's/counter packets 1 bytes 104 drop /counter packets 1 bytes 104 accept /' "$tmp/nft" >"$tmp/wrong-action.nft"
reject env TEST_NFT_FILE="$tmp/wrong-action.nft" "$tool" verify lan wan policy
sed 's/reject comment "!fw4: Reject any other traffic"/accept comment "!fw4: Reject any other traffic"/' "$tmp/nft" >"$tmp/wrong-reject-target.nft"
reject env TEST_NFT_FILE="$tmp/wrong-reject-target.nft" "$tool" verify lan wan policy
sed 's/ip saddr 192.168.1.0\/24 counter/ip saddr 192.168.2.0\/24 counter/' "$tmp/nft" >"$tmp/wrong-source.nft"
reject env TEST_NFT_FILE="$tmp/wrong-source.nft" "$tool" verify lan wan policy
grep -v 'tcp dport 53' "$tmp/nft" >"$tmp/missing-tcp.nft"
reject env TEST_NFT_FILE="$tmp/missing-tcp.nft" "$tool" verify lan wan policy
awk '{print} /routepolicy-init-ipv6"/{print}' "$tmp/nft" >"$tmp/duplicate.nft"
reject env TEST_NFT_FILE="$tmp/duplicate.nft" "$tool" verify lan wan policy
awk '
	/routepolicy-init-ipv6"/ {
		print "meta nfproto 10 counter accept comment \"!fw4: routepolicy-init-ipv6\""
		print "meta nfproto 2 counter jump handle_reject comment \"!fw4: routepolicy-init-ipv6\""
		next
	}
	{print}
' "$tmp/nft" >"$tmp/split-rules.nft"
reject env TEST_NFT_FILE="$tmp/split-rules.nft" "$tool" verify lan wan policy
[ "$("$tool" management-address lan wan policy)" = 192.168.1.1 ]
echo 1 >"$tmp/root/proc/sys/net/ipv4/conf/all/rp_filter"
reject "$tool" verify lan wan policy
echo 2 >"$tmp/root/proc/sys/net/ipv4/conf/br-lan/rp_filter"
reject "$tool" verify lan wan policy
echo 2 >"$tmp/root/proc/sys/net/ipv4/conf/all/rp_filter"
"$tool" verify lan wan policy >"$tmp/verify-loose-global"
echo 0 >"$tmp/root/proc/sys/net/ipv4/conf/all/rp_filter"
echo 1 >"$tmp/root/proc/sys/net/ipv4/conf/br-lan/rp_filter"
reject "$tool" verify lan wan policy
echo 0 >"$tmp/root/proc/sys/net/ipv4/conf/br-lan/rp_filter"
printf 'unknown\n' >"$tmp/root/proc/sys/net/ipv4/conf/all/rp_filter"
reject "$tool" verify lan wan policy
echo 0 >"$tmp/root/proc/sys/net/ipv4/conf/all/rp_filter"
reject env TEST_SERVICE_DOWN=1 "$tool" verify lan wan policy
reject env TEST_MISSING_RULE=1 "$tool" verify lan wan policy
reject env TEST_NO_DNS=1 "$tool" verify lan wan policy
baseline
apply_mock_plan "$tmp/new-default"
sed -e 's/wan/rp_init_default/g' -e 's/eth1/eth3/g' "$tmp/nft" >"$tmp/default-runtime.nft"
TEST_NFT_FILE="$tmp/default-runtime.nft" TEST_DEFAULT_DEVICE=eth3 TEST_DEFAULT_GATEWAY=10.3.0.1 TEST_DEFAULT_METRIC=10 "$tool" verify lan rp_init_default policy default eth3 dhcp - - - - - >"$tmp/verify-new-default"
reject env TEST_NFT_FILE="$tmp/default-runtime.nft" TEST_DEFAULT_DEVICE=eth3 TEST_DEFAULT_GATEWAY=10.3.0.1 TEST_DEFAULT_METRIC=10 TEST_FIB_DEVICE=eth2 "$tool" verify lan rp_init_default policy default eth3 dhcp - - - - -
baseline
"$tool" plan lan wan rp_init_policy policy eth3 dhcp - - - - - >"$tmp/new-policy-final"
apply_mock_plan "$tmp/new-policy-final"
sed -e 's/_policy/_rp_init_policy/g' -e 's/Handle policy /Handle rp_init_policy /g' -e 's/accept policy /accept rp_init_policy /g' -e 's/eth2/eth3/g' "$tmp/nft" >"$tmp/policy-runtime.nft"
TEST_EXTRA_ROUTE='10.3.0.0/24 dev eth3 proto static scope link metric 200' TEST_NFT_FILE="$tmp/policy-runtime.nft" "$tool" verify lan wan rp_init_policy policy eth3 dhcp - - - - - >"$tmp/verify-new-policy"
reject env TEST_EXTRA_ROUTE='10.3.0.0/24 via 10.3.0.1 dev eth3 proto static scope link metric 200' TEST_NFT_FILE="$tmp/policy-runtime.nft" "$tool" verify lan wan rp_init_policy policy eth3 dhcp - - - - -
baseline
TEST_DEFAULT_DEVICE=br-lan TEST_DEFAULT_GATEWAY=192.168.1.254 "$tool" plan lan lan policy >"$tmp/single-arm-final"
apply_mock_plan "$tmp/single-arm-final"
sed -e 's/wan/lan/g' -e 's/eth1/br-lan/g' "$tmp/nft" >"$tmp/single-arm-runtime.nft"
TEST_NFT_FILE="$tmp/single-arm-runtime.nft" TEST_DEFAULT_DEVICE=br-lan TEST_DEFAULT_GATEWAY=192.168.1.254 "$tool" verify lan lan policy >"$tmp/verify-single-arm"
reject env TEST_NFT_FILE="$tmp/single-arm-runtime.nft" TEST_DEFAULT_DEVICE=br-lan TEST_DEFAULT_GATEWAY=192.168.1.254 TEST_FIB_DEVICE=eth2 "$tool" verify lan lan policy
baseline
# Prepare must use current access subnet and avoid both old local and candidate IPs.
TEST_FAIL_LOCAL_FIB=1 TEST_EXPECT_FIB_SOURCE=192.168.1.3 "$tool" plan lan wan policy - - - - - - 192.168.1.2 24 >"$tmp/management-two"
alias_addresses=$(printf '%s\n' '2: br-lan inet 192.168.1.1/24 scope global' '2: br-lan inet 192.168.1.3/24 scope global' '3: eth1 inet 10.1.0.2/24 scope global')
TEST_FAIL_LOCAL_FIB=1 TEST_EXPECT_FIB_SOURCE=192.168.1.4 TEST_LOCAL_ADDRESS_LINES="$alias_addresses" "$tool" plan lan wan policy - - - - - - 192.168.1.2 24 >"$tmp/management-alias"
TEST_FAIL_LOCAL_FIB=1 TEST_EXPECT_FIB_SOURCE=192.168.1.2 "$tool" plan lan wan policy - - - - - - 192.168.2.1 24 >"$tmp/management-new-subnet"
sed 's/192.168.1.0\/24/192.168.2.0\/24/g' "$tmp/nft" >"$tmp/management-new-subnet.nft"
apply_mock_plan "$tmp/management-new-subnet"
TEST_MANAGEMENT_IP=192.168.2.1 TEST_LOCAL_ADDRESS_LINES='2: br-lan inet 192.168.2.1/24 scope global' TEST_FAIL_LOCAL_FIB=1 TEST_EXPECT_FIB_SOURCE=192.168.2.2 TEST_NFT_FILE="$tmp/management-new-subnet.nft" "$tool" verify lan wan policy - - - - - - 192.168.2.1 24 >"$tmp/verify-new-subnet"
baseline
: >"$tmp/fib.log"
TEST_ACCESS_PREFIX=30 TEST_LOCAL_ADDRESS_LINES='2: br-lan inet 192.168.1.1/30 scope global' "$tool" plan lan wan policy - - - - - - 192.168.1.2 30 >"$tmp/management-thirty" 2>"$tmp/deferred-fib"
grep -Fq 'forwarded FIB check deferred to verify' "$tmp/deferred-fib"
if grep -Fq ' from ' "$tmp/fib.log"; then echo 'prepare fabricated a /30 forwarded FIB source' >&2; exit 1; fi
apply_mock_plan "$tmp/management-thirty"
sed 's/192.168.1.0\/24/192.168.1.0\/30/g' "$tmp/nft" >"$tmp/management-thirty.nft"
TEST_MANAGEMENT_IP=192.168.1.2 TEST_ACCESS_PREFIX=30 TEST_LOCAL_ADDRESS_LINES='2: br-lan inet 192.168.1.2/30 scope global' TEST_FAIL_LOCAL_FIB=1 TEST_EXPECT_FIB_SOURCE=192.168.1.1 TEST_NFT_FILE="$tmp/management-thirty.nft" "$tool" verify lan wan policy - - - - - - 192.168.1.2 30 >"$tmp/verify-management-thirty"
exhausted_sources=$(printf '%s\n' '2: br-lan inet 192.168.1.1/30 scope global' '2: br-lan inet 192.168.1.2/30 scope global')
reject env TEST_MANAGEMENT_IP=192.168.1.2 TEST_ACCESS_PREFIX=30 TEST_LOCAL_ADDRESS_LINES="$exhausted_sources" TEST_FAIL_LOCAL_FIB=1 TEST_NFT_FILE="$tmp/management-thirty.nft" "$tool" verify lan wan policy - - - - - - 192.168.1.2 30
grep -Fq 'EVIDENCE_MISSING' "$tmp/error"
baseline
TEST_MANAGEMENT_IP=10.17.1.1 TEST_ACCESS_PREFIX=1 TEST_LOCAL_ADDRESS_LINES='2: br-lan inet 10.17.1.1/1 scope global' TEST_ACCESS_GATEWAY=10.17.1.2 TEST_POLICY_ADDRESS=203.0.113.2 TEST_POLICY_GATEWAY=203.0.113.1 TEST_DEFAULT_DEVICE=br-lan TEST_DEFAULT_GATEWAY=10.17.1.2 TEST_FAIL_LOCAL_FIB=1 TEST_EXPECT_FIB_SOURCE=1.0.0.0 "$tool" plan lan lan policy >"$tmp/wide-source"
[ ! -e "$tmp/writes" ] || { cat "$tmp/writes" >&2; exit 1; }
printf '%s\n' 'init topology tests: passed'
