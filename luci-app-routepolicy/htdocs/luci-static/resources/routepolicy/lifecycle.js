'use strict';
'require baseclass';

/* Pure helpers shared by the lifecycle wizard views. Every value rendered by
 * these helpers is plain text; callers must keep using text nodes only. */

var IPV4_RE = /^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9][0-9]?)$/;
var FIELD_RE = /^[A-Za-z0-9_.:/,#-]{1,256}$/;
var EXPORT_LIMIT = 2097152;

var PHASES = {
	absent:       { label: _('未初始化'), tone: 'notice', text: _('尚未执行初始化接管。现有页面照常可用，默认启用开关保持 0，不需要重新初始化。') },
	prepared:     { label: _('候选已准备'), tone: 'notice', text: _('已有一份待应用的候选。只有开始应用后才进入连接确认窗口。') },
	expired:      { label: _('候选已过期'), tone: 'error', text: _('已准备的候选已失效，请重新生成预览并准备。') },
	applying:     { label: _('应用中'), tone: 'notice', text: _('后端正在按候选修改接口、DHCP、DNS 与防火墙。请勿关闭页面或断电。') },
	pending:      { label: _('待重连确认'), tone: 'notice', text: _('请在新的管理地址重新登录本页面后确认连通；超过窗口未确认会自动回滚。') },
	confirming:   { label: _('确认中'), tone: 'notice', text: _('后端正在完成确认与健康检查。') },
	confirmed:    { label: _('已生效'), tone: 'notice', text: _('初始化已确认。健康项只展示后端的真实检查结果。') },
	rolling_back: { label: _('回滚中'), tone: 'notice', text: _('后端正在恢复原值。') },
	rolled_back:  { label: _('已回滚'), tone: 'notice', text: _('配置已恢复到本次变更之前，可以重新尝试。') },
	conflict:     { label: _('冲突'), tone: 'error', text: _('存在外部修改或恢复冲突，请按提示处理后再继续。') },
	exited:       { label: _('已退出'), tone: 'notice', text: _('退出恢复已完成，RoutePolicy 不再接管 DNS、DHCP 与分流。') }
};

var POLL_PHASES = { applying: true, pending: true, confirming: true, rolling_back: true };

function phaseInfo(phase) {
	var info = PHASES[phase];
	if (!info)
		return {
			label: _('未知状态') + '（' + String(phase == null ? '' : phase) + '）',
			tone: 'error',
			text: _('后端返回了未知的生命周期状态，或与后端暂时失联。状态未知时本页面不会声称成功或继续应用。')
		};
	return info;
}

function isIPv4(text) {
	return typeof text === 'string' && IPV4_RE.test(text);
}

function isPrefix(text) {
	if (typeof text !== 'string' || !/^[0-9]{1,2}$/.test(text))
		return false;
	var value = Number(text);
	return value >= 1 && value <= 30;
}

/* Each role takes at most four IPv4 upstreams separated by commas; an entry is
 * either IPv4 or IPv4#port (default 53, 1..65535). '-' inherits the logical
 * interface's netifd IPv4 DNS servers. A newly created DHCP egress has nothing
 * to inherit, so callers must reject '-' there. */
function dnsSpec(text) {
	if (text == null || text === '' || text === '-')
		return { ok: true, inherit: true, entries: [] };
	if (typeof text !== 'string' || text.length > 128)
		return { ok: false, error: _('DNS 列表格式无效或过长') };
	var parts = text.split(',');
	if (parts.length > 4)
		return { ok: false, error: _('每路 DNS 最多 4 个上游') };
	var entries = [];
	for (var i = 0; i < parts.length; i++) {
		var match = /^([0-9.]{7,15})(?:#([0-9]{1,5}))?$/.exec(parts[i]);
		if (!match || !isIPv4(match[1]))
			return { ok: false, error: _('DNS 条目必须是 IPv4，可选 #端口：') + parts[i] };
		var port = match[2] == null ? 53 : Number(match[2]);
		if (port < 1 || port > 65535)
			return { ok: false, error: _('DNS 条目端口必须在 1..65535：') + parts[i] };
		entries.push(match[1] + '#' + port);
	}
	return { ok: true, inherit: false, entries: entries };
}

function dashValue(value) {
	var text = value == null ? '' : String(value).trim();
	return text === '' ? '-' : text;
}

/* fields: {
 *   access, defaultMode ('existing'|'create'), defaultIf,
 *   policyMode, policyIf, device, proto, newIp, newPrefix, newGateway,
 *   mgmtIp, mgmtPrefix, dnsDefault, dnsPolicy }
 * Returns { ok, content } or { ok: false, errors: [message] }. */
function buildInitContent(fields) {
	var errors = [];
	var f = fields || {};

	var access = dashValue(f.access);
	var defaultMode = f.defaultMode === 'create' ? 'create' : 'existing';
	var policyMode = f.policyMode === 'create' ? 'create' : 'existing';
	var defaultIf = dashValue(f.defaultIf);
	var policyIf = dashValue(f.policyIf);
	var newRole = '-';
	var device = dashValue(f.device);
	var proto = dashValue(f.proto);
	var newIp = dashValue(f.newIp);
	var newPrefix = dashValue(f.newPrefix);
	var newGateway = dashValue(f.newGateway);
	var mgmtIp = dashValue(f.mgmtIp);
	var mgmtPrefix = dashValue(f.mgmtPrefix);
	var dnsDefault = dashValue(f.dnsDefault);
	var dnsPolicy = dashValue(f.dnsPolicy);

	if (access === '-')
		errors.push(_('请选择接入（管理）逻辑接口。'));
	if (defaultMode === 'create' && policyMode === 'create')
		errors.push(_('一次只能新建一个出口（默认或策略），另一个必须选择现有逻辑接口。'));

	if (defaultMode === 'create') {
		newRole = 'default';
		defaultIf = 'rp_init_default';
	} else if (defaultIf === '-') {
		errors.push(_('请选择默认出口逻辑接口。'));
	}

	if (policyMode === 'create') {
		newRole = 'policy';
		policyIf = 'rp_init_policy';
	} else if (policyIf === '-') {
		errors.push(_('请选择策略出口逻辑接口。'));
	}

	if (policyIf !== 'rp_init_policy' && policyIf !== '-') {
		if (policyIf === access)
			errors.push(_('策略出口必须与接入接口相互独立。'));
		if (policyIf === defaultIf)
			errors.push(_('策略出口必须与默认出口相互独立。'));
	}

	if (newRole === '-') {
		device = proto = newIp = newPrefix = newGateway = '-';
	} else {
		if (device === '-')
			errors.push(_('请为新建出口选择一块已识别且未配置的网卡。'));
		if (proto !== 'dhcp' && proto !== 'static') {
			errors.push(_('新建出口协议只支持 DHCP 客户端或静态地址。'));
		} else if (proto === 'dhcp') {
			newIp = newPrefix = newGateway = '-';
		} else {
			if (!isIPv4(newIp))
				errors.push(_('新建出口的 IPv4 地址格式无效。'));
			if (!isPrefix(newPrefix))
				errors.push(_('新建出口的前缀长度必须在 1..30。'));
			if (!isIPv4(newGateway))
				errors.push(_('新建出口的网关必须是 IPv4 地址。'));
		}
	}

	if (mgmtIp === '-' && mgmtPrefix === '-') {
		/* keep the current management address */
	} else if (mgmtIp === '-' || mgmtPrefix === '-') {
		errors.push(_('管理地址与前缀必须同时填写，或同时留空保持当前地址。'));
	} else if (!isIPv4(mgmtIp) || !isPrefix(mgmtPrefix)) {
		errors.push(_('管理地址必须是 IPv4，前缀长度必须在 1..30。'));
	}

	var dnsDefaultSpec = dnsSpec(dnsDefault);
	var dnsPolicySpec = dnsSpec(dnsPolicy);
	if (!dnsDefaultSpec.ok)
		errors.push(_('默认出口 DNS：') + dnsDefaultSpec.error);
	if (!dnsPolicySpec.ok)
		errors.push(_('策略出口 DNS：') + dnsPolicySpec.error);
	if (newRole === 'default' && proto === 'dhcp' && dnsDefaultSpec.inherit)
		errors.push(_('新建 DHCP 默认出口在预检期没有可继承的 DNS，请显式填写默认出口 DNS。'));
	if (newRole === 'policy' && proto === 'dhcp' && dnsPolicySpec.inherit)
		errors.push(_('新建 DHCP 策略出口在预检期没有可继承的 DNS，请显式填写策略出口 DNS。'));

	var values = [ access, defaultIf, policyIf, newRole, device, proto,
		newIp, newPrefix, newGateway, mgmtIp, mgmtPrefix, dnsDefault, dnsPolicy ];
	for (var i = 0; i < values.length; i++)
		if (!FIELD_RE.test(values[i]))
			errors.push(_('输入包含制表符、空格或其他不允许的字符：') + values[i]);

	if (errors.length)
		return { ok: false, errors: errors };
	return { ok: true, content: values.join('\t') };
}

/* restore_prepare carries the same 13 mapping fields plus an explicit danger
 * confirmation and a 1/0 confirmation for non-portable SmartDNS fields. */
function appendRestoreConfirmations(content, dangerConfirmed, unportableConfirmed, unportableRequired) {
	var errors = [];
	if (typeof content !== 'string' || content.split('\t').length !== 13)
		errors.push(_('映射字段尚未通过校验，不能准备恢复候选。'));
	if (dangerConfirmed !== true)
		errors.push(_('必须勾选危险确认才能准备恢复候选。'));
	if (unportableRequired && unportableConfirmed !== true)
		errors.push(_('必须逐项确认列出的不可移植 SmartDNS 字段。'));
	if (errors.length)
		return { ok: false, errors: errors };
	return { ok: true, content: content + '\t1\t' + (unportableConfirmed === true ? '1' : '0') };
}

function buildRestoreContent(fields, dangerConfirmed, unportableConfirmed, unportableRequired) {
	var base = buildInitContent(fields);
	if (!base.ok)
		return base;
	return appendRestoreConfirmations(base.content, dangerConfirmed, unportableConfirmed, unportableRequired);
}

function parseTsvRecords(text) {
	var rows = [];
	if (typeof text !== 'string' || text === '')
		return rows;
	var lines = text.split(/\r?\n/);
	for (var i = 0; i < lines.length; i++) {
		var line = lines[i];
		if (line === '')
			continue;
		rows.push(line.split('\t'));
	}
	return rows;
}

/* exit_prepare services evidence: service \t kind(enabled|running) \t
 * current 0/1 \t restore 0/1. */
function parseServicesTsv(text) {
	var rows = [];
	var records = parseTsvRecords(text);
	for (var i = 0; i < records.length; i++) {
		var record = records[i];
		if (record.length < 4)
			continue;
		rows.push({
			service: record[0],
			kind: record[1],
			current: record[2],
			restore: record[3]
		});
	}
	return rows;
}

var DNSMASQ_KEY = /^dhcp\.(?:dnsmasq|@dnsmasq\[[0-9]+\])(?:\.[^.]+)?$/;

function groupOfKey(key) {
	if (key.indexOf('routepolicy.') === 0)
		return 'routepolicy';
	if (key.indexOf('network.') === 0)
		return 'network';
	if (key.indexOf('dhcp.') === 0)
		return DNSMASQ_KEY.test(key) ? 'dnsmasq' : 'dhcp';
	if (key.indexOf('firewall.') === 0)
		return 'firewall';
	if (key.indexOf('smartdns.') === 0)
		return 'smartdns';
	return 'other';
}

var GROUP_LABELS = {
	routepolicy: _('RoutePolicy 自身配置'),
	network: _('接口与地址'),
	dhcp: _('接入侧 DHCP/DHCPv6/RA/NDP'),
	dnsmasq: _('dnsmasq'),
	firewall: _('fw4/防火墙'),
	smartdns: _('SmartDNS'),
	other: _('其他')
};

/* candidate lines: action \t key \t value; baseline lines: key \t type \t value
 * (type '0' with value '-' marks a previously absent field). */
function candidateRows(candidateText, baselineText) {
	var base = {};
	var baseRows = parseTsvRecords(baselineText);
	for (var i = 0; i < baseRows.length; i++) {
		var row = baseRows[i];
		if (row.length >= 3)
			base[row[0]] = { type: row[1], value: row[2] };
	}
	var rows = [];
	var candRows = parseTsvRecords(candidateText);
	for (var j = 0; j < candRows.length; j++) {
		var entry = candRows[j];
		if (entry.length < 3)
			continue;
		var old = base[entry[1]];
		rows.push({
			group: groupOfKey(entry[1]),
			key: entry[1],
			action: entry[0],
			value: entry[2],
			old: old ? (old.type === '0' ? null : old.value) : undefined
		});
	}
	return rows;
}

/* Checklist derived from the real candidate text; unmatched items are shown as
 * "无证据" instead of being claimed. */
function candidateChecks(candidateText) {
	var rows = parseTsvRecords(candidateText);
	var found = function(test) {
		var hits = [];
		for (var i = 0; i < rows.length; i++) {
			var row = rows[i];
			if (row.length >= 3 && test(row[1], row[2], row[0]))
				hits.push(row[1] + '=' + row[2]);
		}
		return hits;
	};
	return [
		{ label: _('接入接口关闭 DHCPv4（ignore=1）'), hits: found(function(k, v) { return /^dhcp\.[^.]+\.ignore$/.test(k) && v === '1'; }) },
		{ label: _('接入接口关闭 RA / DHCPv6 / NDP'), hits: found(function(k, v) { return /^dhcp\.[^.]+\.(ra|dhcpv6|ndp)$/.test(k) && v === 'disabled'; }) },
		{ label: _('所选接口转为 IPv4-only'), hits: found(function(k, v) { return /^network\.[^.]+\.ipv6$/.test(k) && v === '0'; }) },
		{ label: _('SmartDNS 监听 TCP/UDP 53'), hits: found(function(k, v) { return /^smartdns\.[^.]+\.(port|tcp_server)$/.test(k) && (v === '53' || v === '1'); }) },
		{ label: _('SmartDNS 设置开机自启'), hits: found(function(k, v) { return /^smartdns\.[^.]+\.enabled$/.test(k) && v === '1'; }) },
		{ label: _('dnsmasq 配置关闭 DNS 监听（port=0）'), hits: found(function(k, v, action) {
			return action === 'set' && DNSMASQ_KEY.test(k) && k.endsWith('.port') && v === '0';
		}) },
		{ label: _('dnsmasq 配置禁用实例（disabled=1）'), hits: found(function(k, v, action) {
			return action === 'set' && DNSMASQ_KEY.test(k) && k.endsWith('.disabled') && v === '1';
		}) },
		{ label: _('NAT/分流与 DNS 重定向规则登记'), hits: found(function(k) { return /^firewall\.rp_init_(default_nat|policy_nat|dns|dhcp4|dhcp6|ra|redirects|ipv6)/.test(k); }) }
	];
}

function egressPolicyLabel(value) {
	if (value === 'fail-closed')
		return _('fail-closed（策略出口失败时拒绝流量，不回落默认出口）');
	if (value === 'fallback')
		return _('fallback（策略出口失败时允许回落默认出口）');
	return value == null || value === '' ? _('后端未返回') : String(value);
}

function netifdInterfaces(discover) {
	var list = [];
	var netifd = discover && discover.netifd;
	var entries = netifd && Array.isArray(netifd.interface) ? netifd.interface : [];
	for (var i = 0; i < entries.length; i++) {
		var itf = entries[i];
		if (!itf || typeof itf.interface !== 'string' || itf.interface === '')
			continue;
		var addr = '';
		var first = Array.isArray(itf['ipv4-address']) ? itf['ipv4-address'][0] : null;
		if (first && isIPv4(first.address))
			addr = first.address + (first.mask != null ? '/' + first.mask : '');
		list.push({
			name: itf.interface,
			up: itf.up === true,
			device: typeof itf.l3_device === 'string' && itf.l3_device !== '' ? itf.l3_device : null,
			proto: typeof itf.proto === 'string' && itf.proto !== '' ? itf.proto : null,
			address: addr
		});
	}
	list.sort(function(a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0; });
	return list;
}

/* netifd only reports devices it knows about. The core checks eligibility against the system. */
function unclaimedDevices(discover) {
	var devices = discover && discover.unclaimed_devices;
	return Array.isArray(devices) && devices.every(function(device) {
		return device && typeof device.name === 'string' && device.name !== '' && typeof device.up === 'boolean';
	}) ? devices : null;
}

function jobInfo(status) {
	var job = status && status.job;
	if (!job || typeof job !== 'object')
		return null;
	return {
		kind: typeof job.kind === 'string' ? job.kind : null,
		token: typeof job.token === 'string' ? job.token : null,
		state: typeof job.state === 'string' ? job.state : null,
		error: typeof job.error === 'string' && job.error !== '' ? job.error : null
	};
}

function exportSizeOk(text) {
	return typeof text === 'string' && text.length > 0 && text.length <= EXPORT_LIMIT;
}

return baseclass.extend({
	phaseInfo: phaseInfo,
	isIPv4: isIPv4,
	isPrefix: isPrefix,
	dnsSpec: dnsSpec,
	buildInitContent: buildInitContent,
	buildRestoreContent: buildRestoreContent,
	appendRestoreConfirmations: appendRestoreConfirmations,
	parseTsvRecords: parseTsvRecords,
	parseServicesTsv: parseServicesTsv,
	candidateRows: candidateRows,
	candidateChecks: candidateChecks,
	groupOfKey: groupOfKey,
	groupLabels: GROUP_LABELS,
	egressPolicyLabel: egressPolicyLabel,
	netifdInterfaces: netifdInterfaces,
	unclaimedDevices: unclaimedDevices,
	jobInfo: jobInfo,
	exportSizeOk: exportSizeOk,
	pollPhases: POLL_PHASES
});
