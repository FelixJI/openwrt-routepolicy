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
	'new_policy:@.l3_device') echo eth3 ;;
	'lan:@["ipv4-address"][0].address') echo "${TEST_MANAGEMENT_IP:-192.168.1.1}" ;;
	'wan:@["ipv4-address"][0].address') echo 10.1.0.2 ;;
	'policy:@["ipv4-address"][0].address') echo 10.2.0.2 ;;
	'new_policy:@["ipv4-address"][0].address') echo 10.3.0.2 ;;
	*:'@["ipv4-address"][0].mask') echo 24 ;;
	'lan:@.route[@.target="0.0.0.0"].nexthop') echo 192.168.1.254 ;;
	'wan:@.route[@.target="0.0.0.0"].nexthop') echo "${TEST_GATEWAY:-10.1.0.1}" ;;
	'policy:@.route[@.target="0.0.0.0"].nexthop') echo 10.2.0.1 ;;
	'new_policy:@.route[@.target="0.0.0.0"].nexthop') echo 10.3.0.1 ;;
	'services:@dnsmasq.instances.*.running'|'services:@.dnsmasq.instances.*.running'|'services:@.dropbear.instances.*.running'|'services:@.odhcpd.instances.*.running') [ "${TEST_SERVICE_DOWN:-0}" != 1 ] && echo true || echo false ;;
esac
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
	'-4 rule show') printf '%s\n' '0: from all lookup local' '32766: from all lookup main'; [ "${TEST_RULE_CONFLICT:-0}" = 0 ] || echo '12000: from all lookup 250' ;;
	'-4 route show table 200')
		case "${TEST_TABLE_ERROR:-none}" in
			absent) printf '%s\n' 'Error: ipv4: FIB table does not exist.' 'Dump terminated' >&2; exit 2 ;;
			permission) echo 'RTNETLINK answers: Operation not permitted' >&2; exit 2 ;;
		esac
		[ "${TEST_TABLE_CONFLICT:-0}" = 0 ] || echo 'default via 10.9.0.1 dev eth9' ;;
	'-4 -o addr show'|'-o addr show') printf '%s\n' '2: br-lan inet 192.168.1.1/24 brd 192.168.1.255' '3: eth1 inet 10.1.0.2/24 brd 10.1.0.255' ;;
	'-4 route show table all'|'-6 rule show') : ;;
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
[ "${TEST_ADDRESS_CONFLICT:-0}" = 0 ]
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
baseline
cp "$tmp/config" "$tmp/before"
"$tool" discover >"$tmp/discover"
grep -Fq '"dhcp_roles":[' "$tmp/discover"
grep -Fq '"devices":{"eth3"' "$tmp/discover"
grep -Fq 'existing conntrack sessions are not forcibly cut off' "$tmp/discover"
"$tool" plan lan wan policy >"$tmp/plan"
cmp "$tmp/config" "$tmp/before"
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
"$tool" plan lan lan policy >"$tmp/one-arm"
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
# Simulate the coordinator's allowed writes without any runtime network changes.
awk -F '\t' '$1=="set"{print $2 "\t" $3}' "$tmp/plan" >>"$tmp/config"
awk -F '\t' '{if(!($1 in v))keys[++n]=$1;v[$1]=$2}END{for(i=1;i<=n;i++)print keys[i] "\t" v[keys[i]]}' "$tmp/config" >"$tmp/config.new"
mv "$tmp/config.new" "$tmp/config"
"$tool" verify lan wan policy >"$tmp/verify"
grep -Fq '"packet_evidence":"EVIDENCE_MISSING"' "$tmp/verify"
grep -Fq 'preserve-existing-conntrack-and-management' "$tmp/verify"
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
[ ! -e "$tmp/writes" ] || { cat "$tmp/writes" >&2; exit 1; }
printf '%s\n' 'init topology tests: passed'
