#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/routepolicy-init-topology.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/root/proc/sys/net/ipv4/conf" "$tmp/root/sys/class/net/eth3/device" "$tmp/root/etc/init.d" "$tmp/root/usr/sbin"
export TEST_TOPOLOGY_DIR=$tmp ROUTEPOLICY_ROOT="$tmp/root"
export ROUTEPOLICY_LIBEXEC="$ROOT/routepolicy/files/usr/libexec/routepolicy"
export PATH="$tmp/bin:$PATH"
tool="$ROUTEPOLICY_LIBEXEC/init-topology"
printf '#!/bin/sh\nexit 0\n' >"$tmp/root/etc/init.d/smartdns"
cp "$tmp/root/etc/init.d/smartdns" "$tmp/root/usr/sbin/smartdns"
chmod +x "$tmp/root/etc/init.d/smartdns" "$tmp/root/usr/sbin/smartdns"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/dig"
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" != -q ] || shift
case "$1" in
	export) exit 0 ;;
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
	'call network.interface.wan6 status') echo wan ;;
	'call network.interface.policy status') echo policy ;;
	'call network.interface.rp_init_policy status') echo new_policy ;;
	'call network.interface.rp_init_default status') echo new_policy ;;
	'call network.interface dump') echo '{"interface":[{"interface":"lan","proto":"static"}]}' ;;
	'call network.device status') echo '{"eth3":{"present":true}}' ;;
	'call service list')
		[ "${TEST_UBUS_SERVICE_FAIL:-0}" != 1 ] || exit 1
		printf '%s\n' "${TEST_SERVICE_JSON:-services}" ;;
	'call service list {"name":"smartdns"}') echo '{"smartdns":{"instances":{"main":{"running":false}}}}' ;;
	'call service list {"name":"dnsmasq"}') echo '{"dnsmasq":{}}' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
read -r data
if [ -n "${TEST_SERVICE_JSON:-}" ] && [ "$data" = "$TEST_SERVICE_JSON" ] && [ -n "${TEST_UCI_SDK_ROOT:-}" ]; then
	printf '%s\n' "$data" | "$TEST_UCI_SDK_ROOT/lib/ld-musl-x86_64.so.1" --library-path "$TEST_UCI_SDK_ROOT/lib:$TEST_UCI_SDK_ROOT/usr/lib" "$TEST_UCI_SDK_ROOT/usr/bin/jsonfilter" "$@"
	exit $?
fi
case "$data:$2" in
	'{"dropbear":':*) exit 1 ;;
	'services:@') echo '{}' ;;
	*:'@.up') echo true ;;
	*:'@["dns-server"][*]') [ "${TEST_NO_UPSTREAM:-0}" = 1 ] || echo 192.0.2.53 ;;
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
	*:'@dnsmasq.instances.*.running'|*:'@.dnsmasq.instances.*.running')
		if [ "${TEST_SERVICE_DOWN:-0}" = 1 ] || awk -F '\t' '$1~/^dhcp\.[^.]+\.disabled$/&&$2==1{found=1}END{exit !found}' "$TEST_TOPOLOGY_DIR/config"; then echo false; else echo true; fi ;;
	'services:@.dropbear.instances.*.running')
		if [ "${TEST_SERVICE_DOWN:-0}" = 1 ]; then echo false
		elif [ "${TEST_DROPBEAR_STATE:-true}" != missing ]; then echo "${TEST_DROPBEAR_STATE:-true}"; fi ;;
	'services:@.odhcpd.instances.*.running')
		[ "${TEST_ODHCPD_STATE:-true}" = absent ] || echo "${TEST_ODHCPD_STATE:-true}" ;;
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
if [ "${TEST_DNS_LISTENERS+x}" = x ]; then printf '%s\n' "$TEST_DNS_LISTENERS"
else printf '%s\n' 'udp 0 0 0.0.0.0:53 0.0.0.0:* 122/dnsmasq' 'tcp 0 0 0.0.0.0:53 0.0.0.0:* LISTEN 122/dnsmasq'; fi
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
	rm -rf "$tmp/root/etc/routepolicy/state/init-transaction"
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
dhcp.@dnsmasq[0]	dnsmasq
dhcp.lan	dhcp
dhcp.lan.interface	lan
dhcp.lan.ignore	0
dhcp.other	dhcp
dhcp.other.interface	other
dhcp.other.ignore	1
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
	# The mock commit publishes the same section-field evidence as an applied WAL.
	mock_wal="$tmp/root/etc/routepolicy/state/init-transaction/current"
	mkdir -p "$mock_wal/fields"; cp "$1" "$mock_wal/candidate"
	printf 'pending\n' >"$mock_wal/phase"
	mock_index=0
	while IFS="$(printf '\t')" read -r mock_action mock_key mock_value; do
		mock_index=$((mock_index+1))
		[ "$mock_action" = set ] || continue
		mock_entry="$mock_wal/fields/$mock_index"; mkdir -p "$mock_entry"
		printf '%s' "$mock_key" >"$mock_entry/key"; printf '%s' "$mock_value" >"$mock_entry/expected"
		printf scalar >"$mock_entry/expected-type"; : >"$mock_entry/attempted"
	done <"$1"
	awk -F '\t' '$1=="set"{print $2 "\t" $3}' "$1" >>"$tmp/config"
	awk -F '\t' '{if(!($1 in v))keys[++n]=$1;v[$1]=$2}END{for(i=1;i<=n;i++)print keys[i] "\t" v[keys[i]]}' "$tmp/config" >"$tmp/config.new"
	mv "$tmp/config.new" "$tmp/config"
}
insert_forward_rule() {
	TEST_RULE_TEXT="$1" awk '/chain forward_lan \{/{print;print ENVIRON["TEST_RULE_TEXT"];next}{print}' "$tmp/nft" >"$2"
}
insert_rule_pair() {
	TEST_CHAIN="$1" TEST_FIRST="$2" TEST_SECOND="$3" \
		awk '$1=="chain"&&$2==ENVIRON["TEST_CHAIN"]{print;print ENVIRON["TEST_FIRST"];print ENVIRON["TEST_SECOND"];next}{print}' "$tmp/nft" >"$4"
}
multidevice_config() {
	printf 'firewall.@zone[1].network\twan wan6\nfirewall.@zone[1].device\teth4\nfirewall.@zone[2].device\teth5\n' >>"$tmp/config"
	awk -F '\t' '{if(!($1 in v))keys[++n]=$1;v[$1]=$2}END{for(i=1;i<=n;i++)print keys[i] "\t" v[keys[i]]}' "$tmp/config" >"$tmp/config.new"
	mv "$tmp/config.new" "$tmp/config"
}
optional_service_test() {
	baseline
	printf 'dhcp.other.ra\tserver\ndhcp.other.dhcpv6\tserver\ndhcp.other.ndp\trelay\ndhcp.other.user_note\tKEEP\n' >>"$tmp/config"
	awk -F '\t' '$1~/^dhcp\.other(\.|$)/' "$tmp/config" >"$tmp/other-before"
	"$tool" plan lan wan policy >"$tmp/optional-plan"
	apply_mock_plan "$tmp/optional-plan"
	cp "$tmp/config" "$tmp/optional-config"
	printf '#!/bin/sh\nprintf "unexpected odhcpd lifecycle action\\n" >>"$TEST_TOPOLOGY_DIR/writes"\nexit 1\n' >"$tmp/odhcpd-installed"
	chmod +x "$tmp/odhcpd-installed"
	TEST_ODHCPD_STATE=absent "$tool" verify lan wan policy >"$tmp/verify-odhcpd-absent"
	cp "$tmp/odhcpd-installed" "$tmp/root/etc/init.d/odhcpd"
	TEST_ODHCPD_STATE=true "$tool" verify lan wan policy >"$tmp/verify-odhcpd-running"
	TEST_ODHCPD_STATE=false "$tool" verify lan wan policy >"$tmp/verify-odhcpd-stopped"
	for setting in ignore ra dhcpv6 ndp; do
		awk -F '\t' -v key="dhcp.lan.$setting" 'BEGIN{OFS="\t"}$1==key{$2=($1~/\.ignore$/?0:"server")}{print}' "$tmp/optional-config" >"$tmp/config"
		reject env TEST_ODHCPD_STATE=false "$tool" verify lan wan policy
		cp "$tmp/optional-config" "$tmp/config"
	done
	for rule in dhcp4 dhcp6 ra; do
		grep -vF "comment \"!fw4: routepolicy-init-$rule\"" "$tmp/nft" >"$tmp/missing-output-rule.nft"
		reject env TEST_ODHCPD_STATE=false TEST_NFT_FILE="$tmp/missing-output-rule.nft" "$tool" verify lan wan policy
		awk -v marker="!fw4: routepolicy-init-$rule\"" 'index($0,marker){sub(/jump drop_to_lan/,"accept")}{print}' "$tmp/nft" >"$tmp/allowed-output-rule.nft"
		reject env TEST_ODHCPD_STATE=false TEST_NFT_FILE="$tmp/allowed-output-rule.nft" "$tool" verify lan wan policy
	done
	reject env TEST_ODHCPD_STATE=false TEST_UBUS_SERVICE_FAIL=1 "$tool" verify lan wan policy
	reject env TEST_ODHCPD_STATE=false TEST_SERVICE_JSON='{"dropbear":' "$tool" verify lan wan policy
	for state in false missing; do reject env TEST_ODHCPD_STATE=false TEST_DROPBEAR_STATE="$state" "$tool" verify lan wan policy; done
	if [ -n "${TEST_UCI_SDK_ROOT:-}" ]; then
		for state in true false; do
			TEST_SERVICE_JSON="{\"dropbear\":{\"instances\":{\"main\":{\"running\":true}}},\"odhcpd\":{\"instances\":{\"main\":{\"running\":$state}}}}" "$tool" verify lan wan policy >"$tmp/verify-native-services-$state"
		done
		TEST_SERVICE_JSON='{"dropbear":{"instances":{"main":{"running":true}}}}' "$tool" verify lan wan policy >"$tmp/verify-native-services-absent"
		reject env TEST_SERVICE_JSON='{"dropbear":{"instances":{"main":{"running":false}}}}' "$tool" verify lan wan policy
		reject env TEST_SERVICE_JSON='{"odhcpd":{"instances":{"main":{"running":false}}}}' "$tool" verify lan wan policy
	fi
	cmp "$tmp/optional-config" "$tmp/config"
	awk -F '\t' '$1~/^dhcp\.other(\.|$)/' "$tmp/config" >"$tmp/other-after"; cmp "$tmp/other-before" "$tmp/other-after"
	[ ! -s "$tmp/writes" ]
	rm "$tmp/root/etc/init.d/odhcpd"
	printf '%s\n' 'optional odhcpd runtime: passed (absent/running/stopped, LAN disable and fw4 evidence, ubus/JSON/dropbear rejection, other network preserved, no lifecycle actions)'
}
if [ "${1:-}" = --optional-services ]; then optional_service_test; exit 0; fi
# base614 #17 wrote scalar set fields without expected-type. The optional real
# baseline planner lets the offline upgrade check use its original candidate too.
legacy_ownership_test() {
	baseline
	"${TEST_BASE17_TOPOLOGY:-$tool}" plan lan wan policy >"$tmp/base17-plan"
	apply_mock_plan "$tmp/base17-plan"
	printf 'confirmed\n' >"$mock_wal/phase"
	printf '0123456789abcdef0123456789abcdef\n' >"$mock_wal/token"
	for legacy_field in "$mock_wal"/fields/*; do
		[ -d "$legacy_field" ] || continue
		rm "$legacy_field/expected-type"
		printf scalar >"$legacy_field/type"; printf 0 >"$legacy_field/existed"; : >"$legacy_field/old"
	done
	cp "$tmp/config" "$tmp/legacy-config"
	if ! "$tool" plan lan wan policy >"$tmp/upgrade-plan" 2>"$tmp/upgrade-error"; then
		cat "$tmp/upgrade-error" >&2; printf 'legacy applied scalar WAL rejected\n' >&2; exit 1
	fi
	cmp "$tmp/config" "$tmp/legacy-config"
	legacy_index=$(awk -F '\t' '$2=="firewall.rp_init_default4"{print NR;exit}' "$mock_wal/candidate")
	legacy_entry="$mock_wal/fields/$legacy_index"
	for legacy_type in scalar list 0 ''; do
		printf '%s' "$legacy_type" >"$legacy_entry/expected-type"
		if [ "$legacy_type" = scalar ]; then "$tool" plan lan wan policy >"$tmp/upgrade-control"
		else reject "$tool" plan lan wan policy; fi
		cmp "$tmp/config" "$tmp/legacy-config"
	done
	rm "$legacy_entry/expected-type"
	printf scalar >"$tmp/legacy-scalar"; ln -s "$tmp/legacy-scalar" "$legacy_entry/expected-type"
	reject "$tool" plan lan wan policy; rm "$legacy_entry/expected-type"
	rm "$legacy_entry/attempted"; reject "$tool" plan lan wan policy; : >"$legacy_entry/attempted"
	for legacy_phase in prepared expired rolled_back applying; do
		printf '%s\n' "$legacy_phase" >"$mock_wal/phase"
		reject "$tool" plan lan wan policy; cmp "$tmp/config" "$tmp/legacy-config"
	done
	printf 'confirmed\n' >"$mock_wal/phase"
	"$tool" plan lan wan policy >"$tmp/upgrade-final"
	cmp "$tmp/config" "$tmp/legacy-config"
	printf '%s\n' 'legacy section ownership: passed (base17 scalar WAL, explicit types, attempted/phase/symlink protection, unchanged configuration)'
}
legacy_ownership_test
if [ "${1:-}" = --legacy-upgrade ]; then exit 0; fi
optional_service_test
# A candidate with no committed section fields is never ownership evidence.
for ownership_phase in prepared expired rolled_back applying pending; do
	baseline
	"$tool" plan lan wan policy >"$tmp/preview"
	wal="$tmp/root/etc/routepolicy/state/init-transaction/current"
	mkdir -p "$wal/fields"; cp "$tmp/preview" "$wal/candidate"
	printf '%s\n' "$ownership_phase" >"$wal/phase"
	printf 'firewall.rp_init_dns\trule\nfirewall.rp_init_dns.name\tLiving Room Printer\nfirewall.rp_init_dns.dest_port\t9100\nfirewall.rp_init_dns.target\tREJECT\n' >>"$tmp/config"
	cp "$tmp/config" "$tmp/before"
	reject "$tool" plan lan wan policy
	grep -Fq 'reserved section already exists: firewall.rp_init_dns' "$tmp/error"
	cmp "$tmp/config" "$tmp/before"
done
printf '%s\n' 'topology section provenance: passed (unwritten previews cannot adopt printer rules)'
baseline
cp "$tmp/config" "$tmp/before"
"$tool" discover >"$tmp/discover"
grep -Fq '"dhcp_roles":[' "$tmp/discover"
grep -Fq '"devices":{"eth3"' "$tmp/discover"
grep -Fq 'existing conntrack sessions are not forcibly cut off' "$tmp/discover"
"$tool" plan lan wan policy >"$tmp/plan"
cmp "$tmp/config" "$tmp/before"
# Standard fw4 zone device sets: shared wan/wan6 is deduplicated, and
# both selected zones retain exact literal membership in helper/dispatch rules.
awk '{gsub(/oifname "eth1"/,"oifname { \"eth4\", \"eth1\" }");gsub(/iifname "eth1"/,"iifname { \"eth1\", \"eth4\" }");gsub(/oifname "eth2"/,"oifname { \"eth2\", \"eth5\" }");print;
	if($1=="chain"&&$2=="accept_to_wan")print "meta nfproto 2 oifname { \"eth1\", \"eth4\" } ct state 0x1 counter packets 0 bytes 0 drop comment \"!fw4: Prevent NAT leakage\"";
	if($1=="chain"&&$2=="forward")print "iifname { \"eth4\", \"eth1\" } jump forward_wan comment \"!fw4: Handle wan IPv4/IPv6 forward traffic\""
}' "$tmp/nft" >"$tmp/multidevice.nft"
sed 's/"eth4"/"eth9"/g' "$tmp/multidevice.nft" >"$tmp/multidevice-extra.nft"
sed 's/{ "eth4", "eth1" }/"eth1"/g;s/{ "eth1", "eth4" }/"eth1"/g' "$tmp/multidevice.nft" >"$tmp/multidevice-missing.nft"
sed 's/{ "eth4", "eth1" }/{ "eth1", "eth1" }/g;s/{ "eth1", "eth4" }/{ "eth1", "eth1" }/g' "$tmp/multidevice.nft" >"$tmp/multidevice-duplicate.nft"
sed 's/{ "eth4", "eth1" }/@unknown/g;s/{ "eth1", "eth4" }/@unknown/g' "$tmp/multidevice.nft" >"$tmp/multidevice-unknown.nft"
multidevice_config
TEST_NFT_FILE="$tmp/multidevice.nft" "$tool" plan lan wan policy >"$tmp/multidevice-plan"
cmp "$tmp/plan" "$tmp/multidevice-plan"
for invalid in extra missing duplicate unknown; do reject env TEST_NFT_FILE="$tmp/multidevice-$invalid.nft" "$tool" plan lan wan policy; done
printf 'firewall.@zone[1].device\teth2\n' >>"$tmp/config"
reject env TEST_NFT_FILE="$tmp/multidevice.nft" "$tool" plan lan wan policy
grep -Fq 'share a device' "$tmp/error"
baseline
awk '/chain forward_lan \{/{print;print "meta nfproto 2 counter packets 0 bytes 0 drop comment \"!fw4: existing IPv4 deny-all\"";next}{print}' "$tmp/nft" >"$tmp/early-ipv4-drop.nft"
reject env TEST_NFT_FILE="$tmp/early-ipv4-drop.nft" "$tool" plan lan wan policy
grep -Fq 'IPv4 forwarding' "$tmp/error"
# Candidate management DNS must remain reachable through INPUT, separately
# for TCP/UDP. Existing rules are inspected without changing their config.
dns_bad=0
for rule in \
	'ip daddr 192.168.1.2 tcp dport 53 counter drop comment "!fw4: existing-tcp-dns-block"' \
	'ip daddr 192.168.1.2 udp dport 53 counter log prefix "DNS blocked: " reject comment "!fw4: existing-udp-dns-block"' \
	'ip saddr 192.168.1.99 ip daddr 192.168.1.2 udp dport 53 counter drop' \
	'ip daddr 192.168.1.2 meta l4proto 6 counter drop' \
	'tcp dport 53 counter jump custom_dns_filter'; do
	dns_bad=$((dns_bad + 1))
	insert_rule_pair input_lan "$rule" '' "$tmp/dns-bad-$dns_bad.nft"
	reject env TEST_NFT_FILE="$tmp/dns-bad-$dns_bad.nft" "$tool" plan lan wan policy - - - - - - 192.168.1.2 24
	grep -Fq 'DNS INPUT blocked or unproven (input_lan)' "$tmp/error"
	case "$rule" in *existing-tcp-dns-block*) grep -Fq 'existing-tcp-dns-block' "$tmp/error" ;; esac
done
insert_rule_pair input 'ip daddr 192.168.1.2 udp dport 53 counter drop comment "!fw4: root-dns-block"' '' "$tmp/dns-root-block.nft"
reject env TEST_NFT_FILE="$tmp/dns-root-block.nft" "$tool" plan lan wan policy - - - - - - 192.168.1.2 24
grep -Fq 'DNS INPUT blocked or unproven (input)' "$tmp/error"
dns_safe=0
for rule in \
	'ip daddr 192.168.1.1 tcp dport 53 counter drop' \
	'ip saddr 192.168.2.0/24 udp dport 53 counter drop' \
	'ip daddr 192.168.1.2 tcp dport 80 counter drop' \
	'ip daddr 192.168.1.2 udp sport 67 udp dport 68 counter accept' \
	'meta nfproto 10 tcp dport 53 counter drop' \
	'iifname "eth1" udp dport 53 counter drop'; do
	dns_safe=$((dns_safe + 1))
	insert_rule_pair input_lan "$rule" '' "$tmp/dns-safe-$dns_safe.nft"
	TEST_NFT_FILE="$tmp/dns-safe-$dns_safe.nft" "$tool" plan lan wan policy - - - - - - 192.168.1.2 24 >"$tmp/dns-management-plan"
done
awk '/chain input \{/{print;print "iif \"lo\" accept comment \"!fw4: Accept traffic from loopback\"";print "ct state vmap { 0x2 : accept, 0x4 : accept } comment \"!fw4: Handle inbound flows\"";print "tcp flags & (0x1 | 0x2 | 0x4 | 0x10) == 0x2 jump syn_flood comment \"!fw4: Rate limit TCP syn packets\"";next}
	/chain handle_reject \{/{print "chain syn_flood {";print "limit rate 25/second burst 50 packets return comment \"!fw4: Accept SYN packets below rate-limit\"";print "drop comment \"!fw4: Drop excess packets\"";print "}"}{print}' "$tmp/nft" >"$tmp/dns-stock-input.nft"
TEST_NFT_FILE="$tmp/dns-stock-input.nft" "$tool" plan lan wan policy >"$tmp/dns-stock-plan"
cmp "$tmp/plan" "$tmp/dns-stock-plan"
sed '/routepolicy-init-dns/d;/routepolicy-init-default4/d;/routepolicy-init-policy4/d;/routepolicy-init-ipv6/d;s/jump handle_reject comment "!fw4: Reject any other traffic"/reject comment "!fw4: Reject any other traffic"/' "$tmp/dns-stock-input.nft" >"$tmp/dns-stock-before.nft"
awk '/chain input_lan \{/{print;print "jump accept_from_lan";next}{print}' "$tmp/dns-stock-before.nft" >"$tmp/dns-stock-fresh.nft"
TEST_NFT_FILE="$tmp/dns-stock-fresh.nft" "$tool" plan lan wan policy >"$tmp/dns-stock-fresh-plan"
cmp "$tmp/plan" "$tmp/dns-stock-fresh-plan"
# Nonmatching or partial ACCEPT must not hide a later DROP on the same path.
coverage_bad=0
for first in \
	'ip saddr 198.51.100.0/24 oifname "eth1" counter accept' \
	'ip saddr 198.51.0.0/16 oifname "eth1" counter accept' \
	'ip saddr 192.168.1.0/25 oifname "eth1" counter accept' \
	'meta nfproto 2 meta l4proto 6 oifname "eth1" counter accept' \
	'meta nfproto 2 tcp dport 80 oifname "eth1" counter accept' \
	'meta nfproto 2 iifname "br-other" oifname "eth1" counter accept' \
	'meta nfproto 2 oifname "eth9" counter accept' \
	'meta nfproto 2 ct state 0x1 oifname "eth1" counter accept' \
	'ip saddr 192.168.1.0/24 ip saddr 198.51.100.0/24 oifname "eth1" counter accept'; do
	coverage_bad=$((coverage_bad + 1))
	insert_rule_pair accept_to_wan "$first" 'meta nfproto 2 oifname "eth1" counter log prefix "LAN blocked" drop' "$tmp/coverage-bad-$coverage_bad.nft"
done
for tuple in 'wan eth1' 'policy eth2'; do
	set -- $tuple; zone=$1; dev=$2
	coverage_bad=$((coverage_bad + 1))
	insert_rule_pair "accept_to_$zone" "ip saddr 198.51.100.0/24 oifname \"$dev\" counter accept" "meta nfproto 2 oifname \"$dev\" counter log prefix \"LAN blocked\" drop" "$tmp/coverage-bad-$coverage_bad.nft"
	coverage_bad=$((coverage_bad + 1))
	insert_rule_pair "accept_to_$zone" '' "meta nfproto 2 oifname \"$dev\" counter log prefix \"LAN blocked\" drop" "$tmp/coverage-bad-$coverage_bad.nft"
	coverage_bad=$((coverage_bad + 1))
	insert_rule_pair forward_lan "ip saddr 198.51.100.0/24 counter jump accept_to_$zone" "meta nfproto 2 oifname \"$dev\" counter log prefix \"LAN blocked\" drop" "$tmp/coverage-bad-$coverage_bad.nft"
done
coverage_bad=$((coverage_bad + 1))
insert_rule_pair forward_lan 'ip saddr 198.51.100.0/24 counter accept' 'meta nfproto 2 counter log prefix "LAN blocked" drop' "$tmp/coverage-bad-$coverage_bad.nft"
for blocked in "$tmp"/coverage-bad-*.nft; do
	reject env TEST_NFT_FILE="$blocked" "$tool" plan lan wan policy
	grep -Fq 'IPv4 forwarding' "$tmp/error"
done
grep -v 'routepolicy-init-' "$tmp/coverage-bad-1.nft" >"$tmp/coverage-fresh-helper.nft"
reject env TEST_NFT_FILE="$tmp/coverage-fresh-helper.nft" "$tool" plan lan wan policy
coverage_safe=0
for tuple in 'wan eth1' 'policy eth2'; do
	set -- $tuple; zone=$1; dev=$2
	for source in 192.168.1.0/24 192.168.0.0/16; do
		coverage_safe=$((coverage_safe + 1))
		insert_rule_pair "accept_to_$zone" "ip saddr $source oifname \"$dev\" counter accept" "meta nfproto 2 oifname \"$dev\" counter log prefix \"already accepted\" drop" "$tmp/coverage-safe-$coverage_safe.nft"
		TEST_NFT_FILE="$tmp/coverage-safe-$coverage_safe.nft" "$tool" plan lan wan policy >"$tmp/coverage-safe-plan"
		cmp "$tmp/plan" "$tmp/coverage-safe-plan"
	done
done
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
multidevice_config
TEST_NFT_FILE="$tmp/multidevice.nft" "$tool" verify lan wan policy >"$tmp/verify-multidevice"
for invalid in extra missing duplicate unknown; do reject env TEST_NFT_FILE="$tmp/multidevice-$invalid.nft" "$tool" verify lan wan policy; done
baseline
apply_mock_plan "$tmp/plan"
TEST_NFT_FILE="$tmp/dns-stock-input.nft" "$tool" verify lan wan policy >"$tmp/verify-dns-stock"
apply_mock_plan "$tmp/dns-management-plan"
for blocked in "$tmp"/dns-bad-*.nft "$tmp/dns-root-block.nft"; do
	reject env TEST_MANAGEMENT_IP=192.168.1.2 TEST_NFT_FILE="$blocked" "$tool" verify lan wan policy - - - - - - 192.168.1.2 24
	grep -Fq 'DNS INPUT blocked or unproven' "$tmp/error"
done
for safe in "$tmp"/dns-safe-*.nft; do TEST_MANAGEMENT_IP=192.168.1.2 TEST_NFT_FILE="$safe" "$tool" verify lan wan policy - - - - - - 192.168.1.2 24 >"$tmp/verify-dns-safe"; done
baseline
apply_mock_plan "$tmp/plan"
for blocked in "$tmp"/coverage-bad-*.nft; do
	reject env TEST_NFT_FILE="$blocked" "$tool" verify lan wan policy
	grep -Fq 'IPv4 forwarding' "$tmp/error"
done
for safe in "$tmp"/coverage-safe-*.nft; do TEST_NFT_FILE="$safe" "$tool" verify lan wan policy >"$tmp/verify-coverage-safe"; done
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
tcp4='tcp 0 0 0.0.0.0:53 0.0.0.0:* LISTEN 122/dnsmasq'
udp4='udp 0 0 0.0.0.0:53 0.0.0.0:* 122/dnsmasq'
for listeners in \
	"$tcp4" \
	"$udp4" \
	"$(printf '%s\n' 'tcp 0 0 :::53 :::* LISTEN 122/dnsmasq' 'udp 0 0 :::53 :::* 122/dnsmasq')" \
	"$(printf '%s\n' 'tcp 0 0 192.168.1.2:53 0.0.0.0:* LISTEN 122/dnsmasq' 'udp 0 0 192.168.1.2:53 0.0.0.0:* 122/dnsmasq')" \
	"$(printf '%s\n' "$udp4" 'tcp 0 0 :::53 :::* LISTEN 122/dnsmasq')" \
	"$(printf '%s\n' "$udp4" 'tcp 0 0 0.0.0.0:53 192.0.2.5:12345 ESTABLISHED 122/dnsmasq')"; do
	reject env TEST_DNS_LISTENERS="$listeners" "$tool" verify lan wan policy
	grep -Fq 'TCP LISTEN and UDP DNS listeners must both bind access IPv4 or 0.0.0.0' "$tmp/error"
done
TEST_DNS_LISTENERS="$(printf '%s\n' 'tcp 0 0 192.168.1.1:53 0.0.0.0:* LISTEN 122/dnsmasq' 'udp 0 0 192.168.1.1:53 0.0.0.0:* 122/dnsmasq')" "$tool" verify lan wan policy >"$tmp/verify-bound-dns"
TEST_DNS_LISTENERS="$(printf '%s\n' "$tcp4" 'udp 0 0 192.168.1.1:53 0.0.0.0:* 122/dnsmasq')" "$tool" verify lan wan policy >"$tmp/verify-mixed-dns"
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
# The direct DNS/IPv4-only plan is explicit and refuses unrelated duties.
baseline
"$tool" plan lan wan policy >"$tmp/dns-direct"
grep -Fq 'set	dhcp.@dnsmasq[0].port	0' "$tmp/dns-direct"
grep -Fq 'set	smartdns.rp_init.port	53' "$tmp/dns-direct"
grep -Fq 'set	smartdns.rp_init.bind_device_name	br-lan' "$tmp/dns-direct"
grep -Fq 'set	smartdns.rp_init.force_aaaa_soa	1' "$tmp/dns-direct"
grep -Fq 'set	smartdns.rp_init.cache_file	/tmp/routepolicy/smartdns.cache' "$tmp/dns-direct"
reject env TEST_NO_UPSTREAM=1 "$tool" plan lan wan policy
TEST_NO_UPSTREAM=1 "$tool" plan lan wan policy - - - - - - - - '192.0.2.53#5353,192.0.2.54' '198.51.100.53#53' >"$tmp/dns-explicit"
grep -Fq 'set	smartdns.rp_init_default_1.port	5353' "$tmp/dns-explicit"
for invalid in '127.0.0.1' '224.0.0.1' '192.0.2.53#0' '192.0.2.53#65536' '192.0.2.53,,192.0.2.54'; do
	reject "$tool" plan lan wan policy - - - - - - - - "$invalid" 198.51.100.53
done
printf 'network.wan6	interface\nnetwork.wan6.proto	dhcpv6\nnetwork.wan6.device	@wan\n' >>"$tmp/config"
"$tool" plan lan wan policy >"$tmp/ipv4-only"
grep -Fq 'set	network.wan6.disabled	1' "$tmp/ipv4-only"
grep -Fq 'set	network.wan6.auto	0' "$tmp/ipv4-only"
baseline
printf 'network.foreign	interface\nnetwork.foreign.proto	static\nnetwork.foreign.device	eth1\n' >>"$tmp/config"
reject "$tool" plan lan wan policy
baseline
sed 's/dhcp.other.ignore	1/dhcp.other.ignore	0/' "$tmp/config" >"$tmp/config.new"; mv "$tmp/config.new" "$tmp/config"
reject "$tool" plan lan wan policy
grep -Fq '其他 DHCP' "$tmp/error"
baseline
printf 'dhcp.@dnsmasq[0].enable_tftp	1\n' >>"$tmp/config"
reject "$tool" plan lan wan policy
baseline
[ ! -e "$tmp/writes" ] || { cat "$tmp/writes" >&2; exit 1; }
for setting in route_table:0200 rule_priority:012000; do
	baseline
	printf 'routepolicy.main.%s\t%s\n' "${setting%:*}" "${setting#*:}" >>"$tmp/config"
	cp "$tmp/config" "$tmp/numeric-before"
	reject "$tool" plan lan wan policy
	grep -Fq '无前导零的十进制整数' "$tmp/error"
	cmp "$tmp/config" "$tmp/numeric-before"
done
baseline
"$tool" plan lan wan policy >"$tmp/canonical-id-plan"
[ ! -e "$tmp/writes" ] || { cat "$tmp/writes" >&2; exit 1; }
printf '%s\n' 'init topology tests: passed'
