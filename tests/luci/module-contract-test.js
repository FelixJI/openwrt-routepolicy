'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

function createBaseClass() {
	function BaseClass() {}

	BaseClass.extend = function(properties) {
		function Subclass() {}

		Subclass.prototype = Object.create(BaseClass.prototype);
		Object.assign(Subclass.prototype, properties);
		return Subclass;
	};

	BaseClass.isSubclass = function(value) {
		return typeof value === 'function' && value.prototype instanceof BaseClass;
	};

	return BaseClass;
}

function loadModule(name, filename, options = {}) {
	const source = fs.readFileSync(filename, 'utf8');
	const baseclass = createBaseClass();
	const dependencies = {
		baseclass: baseclass,
		rpc: {
			declare: function(spec) {
				return function(...args) {
					if (args.length === 0)
						return spec.method;

					const params = {};
					if (Array.isArray(spec.params)) {
						for (let i = 0; i < spec.params.length; i++)
							params[spec.params[i]] = args[i];
					}
					else if (spec.params && typeof spec.params === 'object') {
						const values = args[0];
						if (values && typeof values === 'object') {
							for (const key of Object.keys(spec.params))
								if (Object.prototype.hasOwnProperty.call(values, key))
									params[key] = values[key];
						}
					}

					if (options.call && spec.object === 'uci')
						return options.call(spec, params);
					return { method: spec.method, params: params };
				};
			}
		}
	};
	const aliases = [];
	const instances = [];
	const directive = /^'(use strict|require\s+(\S+)(?:\s+as\s+([a-zA-Z_]\S*))?)';\s*/;
	let remaining = source;

	while (true) {
		const match = directive.exec(remaining);

		if (!match)
			break;

		remaining = remaining.substring(match[0].length);
		if (!match[2])
			continue;

		if (!Object.prototype.hasOwnProperty.call(dependencies, match[2]))
			throw new Error('Unsupported test dependency: ' + match[2]);

		aliases.push(match[3] || match[2].replace(/[^a-zA-Z0-9_]/g, '_'));
		instances.push(dependencies[match[2]]);
	}

	const factory = new Function('window', 'document', 'L', '_', ...aliases, source);
	const constructor = factory({ crypto: options.crypto }, {}, {}, function(value) { return value; }, ...instances);

	if (!baseclass.isSubclass(constructor))
		throw new TypeError('"' + name + '" factory yields invalid constructor');

	return new constructor();
}

const repo = path.resolve(__dirname, '../..');
const api = loadModule(
	'routepolicy/api',
	path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/routepolicy/api.js')
);

if (typeof api.status !== 'function' || api.status() !== 'status')
	throw new Error('Loaded API instance must expose the status RPC method');
if (typeof api.smartdnsApply !== 'function' || api.smartdnsApply() !== 'smartdns_apply')
	throw new Error('Loaded API instance must expose the SmartDNS apply RPC method');
if (typeof api.observeInterfaces !== 'function' || api.observeInterfaces() !== 'observe_interfaces')
	throw new Error('Loaded API instance must expose the bounded interface snapshot RPC method');
if (typeof api.observeSets !== 'function' || api.observeSets() !== 'observe_sets')
	throw new Error('Loaded API instance must expose the bounded set summary RPC method');
if (api.safeText(null) !== '—')
	throw new Error('Loaded API instance must retain safeText behavior');
assert.deepStrictEqual(api.readUserList({ list: 'domain-policy' }), {
	method: 'read_user_list',
	params: { list: 'domain-policy' }
});
assert.deepStrictEqual(api.writeUserList({ list: 'domain-default', content: 'example.com\n' }), {
	method: 'write_user_list',
	params: { list: 'domain-default', content: 'example.com\n' }
});
assert.deepStrictEqual(api.smartdnsSave('enabled\t1\n'), {
	method: 'smartdns_save',
	params: { content: 'enabled\t1\n' }
});
assert.deepStrictEqual(api.observeQuery({
	dataset: 'source_ingress4', query: '192.168.', cursor: 'v1:source_ingress4:g1:50',
	limit: 50, device: 'br-lan', sort: 'bytes'
}), {
	method: 'observe_query',
	params: {
		dataset: 'source_ingress4', query: '192.168.', cursor: 'v1:source_ingress4:g1:50',
		limit: 50, device: 'br-lan', sort: 'bytes'
	}
});

/* Lifecycle RPC surface: snake_case ubus methods behind camelCase helpers. */
for (const method of [ 'init_discover', 'init_candidate', 'init_status', 'init_recover',
	'config_export', 'restore_status', 'restore_recover', 'exit_preview', 'exit_prepare', 'exit_candidate' ]) {
	const camel = method.replace(/_([a-z])/g, function(_, c) { return c.toUpperCase(); });
	if (typeof api[camel] !== 'function' || api[camel]() !== method)
		throw new Error('Loaded API instance must expose the lifecycle RPC method: ' + method);
}
assert.deepStrictEqual(api.initPreview('a\tb'), { method: 'init_preview', params: { content: 'a\tb' } });
assert.deepStrictEqual(api.initPrepare('c\td'), { method: 'init_prepare', params: { content: 'c\td' } });
assert.deepStrictEqual(api.configImport('e\tf'), { method: 'config_import', params: { content: 'e\tf' } });
assert.deepStrictEqual(api.restorePrepare('g\th'), { method: 'restore_prepare', params: { content: 'g\th' } });
assert.deepStrictEqual(api.initApply('0123456789abcdef0123456789abcdef'), {
	method: 'init_apply', params: { token: '0123456789abcdef0123456789abcdef' }
});
assert.deepStrictEqual(api.initCancel('0123456789abcdef0123456789abcdef'), {
	method: 'init_cancel', params: { token: '0123456789abcdef0123456789abcdef' }
});
assert.deepStrictEqual(api.initFinish('0123456789abcdef0123456789abcdef'), {
	method: 'init_finish', params: { token: '0123456789abcdef0123456789abcdef' }
});
assert.deepStrictEqual(api.exitApply('fedcba0987654321fedcba0987654321'), {
	method: 'exit_apply', params: { token: 'fedcba0987654321fedcba0987654321' }
});

/* Shared lifecycle helper module. */
const lifecycle = loadModule(
	'routepolicy/lifecycle',
	path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/routepolicy/lifecycle.js')
);

assert.strictEqual(lifecycle.phaseInfo('pending').label, '待重连确认');
assert.strictEqual(lifecycle.phaseInfo('confirmed').label, '已生效');
assert.strictEqual(lifecycle.phaseInfo('bogus-phase').tone, 'error',
	'an unknown backend phase must render as an explicit unknown state, never as success');

assert.deepStrictEqual(lifecycle.dnsSpec('-'), { ok: true, inherit: true, entries: [] });
assert.deepStrictEqual(lifecycle.dnsSpec('223.5.5.5,119.29.29.29#5353').entries,
	[ '223.5.5.5#53', '119.29.29.29#5353' ]);
for (const bad of [ '8.8.8.8,1.1.1.1,9.9.9.9,64.6.64.6,4.4.4.4', '10.0.0.1#0', '10.0.0.1#70000', 'abc', '1.1.1.1,,2.2.2.2', '1.1.1.1,', ',1.1.1.1', ' 8.8.8.8', '999.1.1.1' ])
	assert.strictEqual(lifecycle.dnsSpec(bad).ok, false, 'DNS spec must reject: ' + bad);

const validCreate = lifecycle.buildInitContent({
	access: 'lan', defaultMode: 'existing', defaultIf: 'wan',
	policyMode: 'create', policyIf: '', device: 'eth2', proto: 'dhcp',
	newIp: '', newPrefix: '', newGateway: '', mgmtIp: '', mgmtPrefix: '',
	dnsDefault: '', dnsPolicy: '223.5.5.5'
});
assert.strictEqual(validCreate.ok, true);
assert.strictEqual(validCreate.content, 'lan\twan\trp_init_policy\tpolicy\teth2\tdhcp\t-\t-\t-\t-\t-\t-\t223.5.5.5');

assert.strictEqual(lifecycle.buildInitContent({
	access: 'lan', defaultMode: 'create', defaultIf: '', policyMode: 'create', policyIf: '',
	device: 'eth1', proto: 'dhcp', dnsDefault: '1.1.1.1', dnsPolicy: '2.2.2.2'
}).ok, false, 'creating both egress interfaces at once must be rejected');
assert.match(lifecycle.buildInitContent({
	access: 'lan', defaultMode: 'create', defaultIf: '', policyMode: 'existing', policyIf: 'usbwan',
	device: 'eth1', proto: 'dhcp', dnsDefault: '', dnsPolicy: '1.1.1.1'
}).errors.join(';'), /新建 DHCP/, 'a new DHCP egress without explicit DNS must be rejected client-side');
assert.strictEqual(lifecycle.buildInitContent({
	access: 'lan', defaultMode: 'create', defaultIf: '', policyMode: 'existing', policyIf: 'usbwan',
	device: 'eth1', proto: 'static', newIp: '203.0.113.2', newPrefix: '24', newGateway: '',
	dnsDefault: '-', dnsPolicy: '-'
}).ok, false, 'a static egress without a gateway must be rejected');
assert.strictEqual(lifecycle.buildInitContent({
	access: 'lan', defaultMode: 'existing', defaultIf: 'wan', policyMode: 'existing', policyIf: 'usbwan',
	dnsDefault: '-', dnsPolicy: '-', mgmtIp: '192.0.2.9', mgmtPrefix: ''
}).ok, false, 'a half-filled management address must be rejected');
assert.strictEqual(lifecycle.buildInitContent({
	access: 'la n', defaultMode: 'existing', defaultIf: 'wan', policyMode: 'existing', policyIf: 'usbwan',
	dnsDefault: '-', dnsPolicy: '-'
}).ok, false, 'field values containing spaces or tabs must never reach the backend');

const restore = lifecycle.buildRestoreContent({
	access: 'lan', defaultMode: 'existing', defaultIf: 'wan', policyMode: 'existing', policyIf: 'usbwan',
	dnsDefault: '-', dnsPolicy: '-', mgmtIp: '', mgmtPrefix: ''
}, true, true, true);
assert.strictEqual(restore.ok, true);
assert.strictEqual(restore.content.split('\t').length, 15, 'restore_prepare takes 15 fields');
assert.ok(/\t1\t1$/.test(restore.content), 'restore content must end with both confirmations');
assert.strictEqual(lifecycle.buildRestoreContent({
	access: 'lan', defaultMode: 'existing', defaultIf: 'wan', policyMode: 'existing', policyIf: 'usbwan',
	dnsDefault: '-', dnsPolicy: '-' }, false, true, true).ok, false,
	'restore without the danger confirmation must be rejected');
assert.strictEqual(lifecycle.appendRestoreConfirmations('only\ttwo', true, true, false).ok, false,
	'restore confirmation may only be appended to a validated 13-field mapping');

const candidateSample = 'set\troutepolicy.main.enabled\t1\nset\tdhcp.lan.ignore\t1\nset\tdhcp.lan.ra\tdisabled\nset\tnetwork.lan.ipv6\t0\nset\tsmartdns.rp_init.port\t53\nset\tsmartdns.rp_init.tcp_server\t1\nset\tdhcp.dnsmasq.disabled\t1\ndelete\tnetwork.lan.ip6addr\t-\n';
const baselineSample = 'dhcp.lan.ignore\t0\t0\nnetwork.lan.ip6addr\tscalar\tfd00::1\n';
const rows = lifecycle.candidateRows(candidateSample, baselineSample);
const ignoreRow = rows.find(function(row) { return row.key === 'dhcp.lan.ignore'; });
assert.ok(ignoreRow && ignoreRow.old === null && ignoreRow.value === '1',
	'a previously absent field must show an absent baseline');
const deleted = rows.find(function(row) { return row.key === 'network.lan.ip6addr'; });
assert.ok(deleted && deleted.old === 'fd00::1' && deleted.action === 'delete',
	'deleted fields must keep their real baseline value');
assert.strictEqual(lifecycle.groupOfKey('dhcp.dnsmasq.port'), 'dnsmasq');
assert.strictEqual(lifecycle.groupOfKey('dhcp.@dnsmasq[0].port'), 'dnsmasq');
assert.strictEqual(lifecycle.groupOfKey('smartdns.rp_init.port'), 'smartdns');

const checks = lifecycle.candidateChecks(candidateSample);
const check = function(label) { return checks.find(function(item) { return item.label === label; }); };
assert.ok(check('接入接口关闭 DHCPv4（ignore=1）').hits.length === 1, 'the checklist must be derived from the real candidate');
assert.ok(check('接入接口关闭 RA / DHCPv6 / NDP').hits.length === 1);
assert.ok(check('SmartDNS 监听 TCP/UDP 53').hits.length === 2);
const dnsmasqPort = 'dnsmasq 配置关闭 DNS 监听（port=0）';
const dnsmasqDisabled = 'dnsmasq 配置禁用实例（disabled=1）';
assert.deepStrictEqual(check(dnsmasqDisabled).hits, [ 'dhcp.dnsmasq.disabled=1' ]);
assert.deepStrictEqual(check(dnsmasqPort).hits, []);
const anonymous = lifecycle.candidateChecks('set\tdhcp.@dnsmasq[0].port\t0\nset\tdhcp.@dnsmasq[0].disabled\t1\n');
assert.deepStrictEqual(anonymous.find(function(item) { return item.label === dnsmasqPort; }).hits, [ 'dhcp.@dnsmasq[0].port=0' ]);
assert.deepStrictEqual(anonymous.find(function(item) { return item.label === dnsmasqDisabled; }).hits, [ 'dhcp.@dnsmasq[0].disabled=1' ]);
const stillEnabled = lifecycle.candidateChecks('set\tdhcp.@dnsmasq[0].port\t53\ndelete\tdhcp.@dnsmasq[0].disabled\t1\n');
assert.deepStrictEqual(stillEnabled.find(function(item) { return item.label === dnsmasqPort; }).hits, []);
assert.deepStrictEqual(stillEnabled.find(function(item) { return item.label === dnsmasqDisabled; }).hits, []);
assert.ok(check('接入接口关闭 DHCPv4（ignore=1）') && checks.every(function(item) { return Array.isArray(item.hits); }));

assert.match(lifecycle.egressPolicyLabel('fail-closed'), /^fail-closed/, 'the egress policy label must show the actual backend value');
assert.ok(checks.every(function(item) { return !item.label.includes('出口失败策略'); }),
	'new firewall zone fields must not be used as evidence of the independent egress failure policy');

const discoverSample = {
	devices: {
		lo: { exists: true, up: true },
		'br-lan': { up: true, type: 'bridge', devtype: 'bridge', 'bridge-members': [ 'eth0' ] },
		eth0: { up: true, type: 'Network device', devtype: 'ethernet' },
		eth1: { up: true, type: 'Network device', devtype: 'ethernet' }
	},
	netifd: { interface: [
		{ interface: 'loopback', up: true, l3_device: 'lo', proto: 'static' },
		{ interface: 'lan', up: true, l3_device: 'br-lan', proto: 'static', 'ipv4-address': [ { address: '192.168.1.1', mask: 24 } ] },
		{ interface: 'wan', up: true, l3_device: 'eth1', proto: 'dhcp', 'ipv4-address': [ { address: '198.51.100.2', mask: 24 } ] },
		{ interface: 'wan6', up: false, device: 'eth1', proto: 'dhcpv6' }
	] },
	unclaimed_devices: [ { name: 'eth2', up: false, carrier: null } ],
	missing_dependencies: [], observations: {}, ok: true
};
assert.deepStrictEqual(lifecycle.netifdInterfaces(discoverSample).map(function(itf) { return itf.name; }),
	[ 'lan', 'loopback', 'wan', 'wan6' ]);
assert.strictEqual(lifecycle.netifdInterfaces(discoverSample)[0].address, '192.168.1.1/24');
assert.deepStrictEqual(lifecycle.unclaimedDevices(discoverSample), [ { name: 'eth2', up: false, carrier: null } ],
	'offer the standalone down NIC from the core even when absent from netifd');
assert.strictEqual(lifecycle.unclaimedDevices(Object.assign({}, discoverSample, { unclaimed_devices: undefined })), null,
	'a legacy device list cannot prove eth0 is free');
assert.deepStrictEqual(lifecycle.unclaimedDevices(Object.assign({}, discoverSample, { unclaimed_devices: [] })), []);

assert.deepStrictEqual(lifecycle.parseServicesTsv('smartdns\tenabled\t1\t0\ndnsmasq\trunning\t1\t1'), [
	{ service: 'smartdns', kind: 'enabled', current: '1', restore: '0' },
	{ service: 'dnsmasq', kind: 'running', current: '1', restore: '1' }
]);
assert.deepStrictEqual(lifecycle.jobInfo({ job: { kind: 'init', token: 't'.repeat(32), state: 'running' } }).state, 'running');
assert.strictEqual(lifecycle.jobInfo({}), null);
assert.strictEqual(lifecycle.exportSizeOk(''), false);
assert.strictEqual(lifecycle.exportSizeOk('x'.repeat(10)), true);
assert.strictEqual(lifecycle.exportSizeOk('x'.repeat(2097153)), false, 'the client must reject import payloads above 2 MiB before sending');

async function sourceIdentityContract() {
	const events = [];
	const name = byte => 'rp_src_' + byte.repeat(12);
	const random = [ 0x11, 0x22, 0x33, 0x33, 0x44, 0x55 ];
	const sections = [
		{ '.name': name('11'), '.type': 'main', '.anonymous': false },
		{ '.name': 'cfg01', '.type': 'source', '.anonymous': true, enabled: '0', extra: [ 'a', 'b' ] },
		{ '.name': name('22'), '.type': 'source', '.anonymous': false, custom: 'unchanged' },
		{ '.name': 'cfg02', '.type': 'source', '.anonymous': true, enabled: '1' }
	];
	let cache = sections.map(section => Object.assign({}, section));
	let rejectSecond = true;
	let failNextLoad = false;
	let loadPromise;
	const sourceApi = loadModule('routepolicy/api', path.join(repo,
		'luci-app-routepolicy/htdocs/luci-static/resources/routepolicy/api.js'), {
		crypto: { getRandomValues(bytes) {
			assert.ok(random.length, 'unexpected extra random name');
			return bytes.fill(random.shift());
		} },
		call(spec, params) {
			assert.strictEqual(spec.method, 'rename');
			assert.strictEqual(spec.reject, true, 'nonzero ubus status must reject');
			assert.deepStrictEqual(Object.keys(params), [ 'config', 'section', 'name' ]);
			assert.strictEqual(params.config, 'routepolicy');
			events.push([ 'rename', params.section, params.name ]);
			if (params.section === 'cfg02' && rejectSecond) {
				failNextLoad = true;
				return Promise.reject(new Error('rename blocked'));
			}
			const section = sections.find(section => section['.name'] === params.section);
			assert.strictEqual(section['.anonymous'], true);
			section['.name'] = params.name;
			section['.anonymous'] = false;
			return Promise.resolve(0);
		}
	});
	const uci = {
		get: (config, id) => cache.find(section => section['.name'] === id),
		sections: (config, type) => cache.filter(section => section['.type'] === type),
		unload: () => { events.push('unload'); cache = []; loadPromise = null; },
		load: () => {
			events.push('load');
			if (loadPromise)
				return loadPromise;
			if (failNextLoad) {
				failNextLoad = false;
				return (loadPromise = Promise.reject(new Error('read failed')));
			}
			cache = sections.map(section => Object.assign({}, section));
			return (loadPromise = Promise.resolve());
		}
	};
	assert.strictEqual(sourceApi.newSourceName(uci), name('33'), 'current sections of every type reserve their names');
	random.unshift(0x33);
	await assert.rejects(sourceApi.nameAnonymousSources(uci), /rename blocked/);
	assert.deepStrictEqual(events, [ 'unload', 'load', [ 'rename', 'cfg01', name('33') ],
		[ 'rename', 'cfg02', name('44') ], 'unload', 'load', 'unload' ],
		'reserve names before the cache reload and discard a cached load rejection');
	assert.deepStrictEqual(cache, [], 'the failed reload leaves no cached sections, like LuCI uci.load');
	assert.deepStrictEqual(sections[1], { '.name': name('33'), '.type': 'source', '.anonymous': false, enabled: '0', extra: [ 'a', 'b' ] });
	assert.deepStrictEqual(sections[2], { '.name': name('22'), '.type': 'source', '.anonymous': false, custom: 'unchanged' });
	rejectSecond = false;
	assert.strictEqual(await sourceApi.nameAnonymousSources(uci), true, 'a retry with an empty cache still converts the remaining source');
	assert.deepStrictEqual(events.slice(7), [ 'unload', 'load', [ 'rename', 'cfg02', name('55') ], 'unload', 'load' ]);
	failNextLoad = true;
	await assert.rejects(sourceApi.nameAnonymousSources(uci), /read failed/, 'a failed fresh read cannot certify the migration');
	assert.strictEqual(await sourceApi.nameAnonymousSources(uci), false, 'named sources must never be renamed again');
}

sourceIdentityContract().then(function() {
	console.log('LuCI module constructor contract passed.');
}, function(error) {
	console.error(error);
	process.exitCode = 1;
});
