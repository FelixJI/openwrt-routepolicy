'use strict';

/* Executable interaction contract for the lifecycle wizard view. It drives the
 * real view source with a DOM harness: load must stay read-only, previews show
 * real candidate/baseline data, danger steps require explicit confirmations,
 * repeated clicks never re-apply, offline polling degrades to "unknown", and
 * every backend value renders as plain text. */

const assert = require('assert');
const fs = require('fs');
const path = require('path');

class Element {
	constructor(tagName) {
		this.tagName = tagName;
		this.attributes = {};
		this.children = [];
		this.listeners = {};
		this.style = {};
		this.value = '';
		this.checked = false;
		this.disabled = false;
		this.textContent = '';
		this.selectedIndex = -1;
	}
	addEventListener(name, listener) { this.listeners[name] = listener; }
	getAttribute(name) {
		return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null;
	}
	setAttribute(name, value) {
		this.attributes[name] = String(value);
		if (name === 'value') this.value = String(value);
		if (name === 'checked') this.checked = true;
	}
	appendChild(child) {
		if (child == null)
			return child;
		this.children.push(child);
		if (child instanceof Element) {
			child.parentNode = this;
			if (this.tagName === 'select' && child.tagName === 'option') {
				if (this.selectedIndex === -1 || child.getAttribute('selected') != null) {
					this.children.forEach(function(option) {
						if (option instanceof Element && option.tagName === 'option')
							option.selected = false;
					});
					child.selected = true;
					this.selectedIndex = this.children.indexOf(child);
					this.value = child.value;
				}
			}
		}
		return child;
	}
	replaceChildren() {
		this.children = [];
		for (let i = 0; i < arguments.length; i++)
			this.appendChild(arguments[i]);
	}
	contains(node) {
		return this === node || this.children.some(function(child) { return child instanceof Element && child.contains(node); });
	}
	get firstChild() { return this.children[0] || null; }
	click() {
		if (typeof this.listeners.click === 'function')
			return this.listeners.click();
	}
}

function makeElement(tagName, attributes, children) {
	const element = new Element(tagName);
	for (const key of Object.keys(attributes || {})) {
		const value = attributes[key];
		if (value == null) continue;
		if (typeof value === 'function') element.addEventListener(key, value);
		else element.setAttribute(key, value);
	}
	const items = Array.isArray(children) ? children : [ children ];
	items.forEach(element.appendChild.bind(element));
	return element;
}

function nodeText(node) {
	if (node == null) return '';
	if (!(node instanceof Element)) return String(node);
	return node.textContent + node.children.map(nodeText).join('');
}

function findAll(node, predicate, found) {
	found = found || [];
	if (!(node instanceof Element)) return found;
	if (predicate(node)) found.push(node);
	node.children.forEach(function(child) { findAll(child, predicate, found); });
	return found;
}

function button(root, action) {
	return findAll(root, function(node) {
		return node.tagName === 'button' && node.getAttribute('data-action') === action;
	})[0] || null;
}

function acceptConfirmation(rendered, pending) {
	const confirm = button(rendered.root, 'confirmation-accept');
	assert.ok(confirm, 'expected a page confirmation');
	confirm.click();
	return pending;
}

function confirmedClick(rendered, action) {
	const trigger = typeof action === 'string' ? button(rendered.body, action) : action;
	return acceptConfirmation(rendered, trigger.click());
}

function hasEventAttribute(node) {
	return Object.keys(node.attributes).some(function(name) { return /^on/i.test(name); });
}

function flush() {
	return new Promise(function(resolve) { setImmediate(resolve); });
}

async function settle() {
	for (let i = 0; i < 8; i++)
		await flush();
}

const repo = path.resolve(__dirname, '../..');

function loadSource(filename, dependencies, globals) {
	const source = fs.readFileSync(filename, 'utf8');
	const aliases = [];
	const instances = [];
	const directive = /^'(use strict|require\s+(\S+)(?:\s+as\s+([a-zA-Z_]\S*))?)';\s*/;
	let remaining = source;
	while (true) {
		const match = directive.exec(remaining);
		if (!match) break;
		remaining = remaining.substring(match[0].length);
		if (!match[2]) continue;
		if (!Object.prototype.hasOwnProperty.call(dependencies, match[2]))
			throw new Error('Unsupported dependency: ' + match[2]);
		aliases.push(match[3] || match[2].replace(/[^a-zA-Z0-9_]/g, '_'));
		instances.push(dependencies[match[2]]);
	}
	const factory = new Function('window', 'document', 'L', 'E', '_', ...aliases, source);
	return factory(globals.window, globals.document, globals.L || {}, makeElement, function(value) { return value; }, ...instances);
}

/* Real lifecycle helper module, loaded like the module contract test does. */
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

const lifecycleModule = loadSource(
	path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/routepolicy/lifecycle.js'),
	{ baseclass: createBaseClass() },
	{ window: {}, document: {} }
);
const lifecycle = new lifecycleModule();

const API_METHODS = [
	'init_status', 'restore_status', 'init_discover', 'init_preview', 'init_prepare',
	'init_candidate', 'init_apply', 'init_cancel', 'init_finish', 'init_recover', 'config_export', 'config_import',
	'restore_prepare', 'restore_recover', 'exit_preview', 'exit_prepare', 'exit_candidate',
	'exit_apply', 'read_user_list', 'write_user_list'
];

function camel(name) {
	return name.replace(/_([a-z])/g, function(_, c) { return c.toUpperCase(); });
}

function createHarness(queue) {
	const apiLog = [];
	const api = {
		safeText: function(value, fallback) {
			return value === null || value === undefined || value === '' ? (fallback || '—') : String(value);
		}
	};
	for (const method of API_METHODS) {
		api[camel(method)] = function() {
			const args = Array.prototype.slice.call(arguments);
			apiLog.push({ method: method, args: args });
			let value = queue && queue[method] && queue[method].length
				? queue[method].shift()
				: (queue && queue[method + '#last']);
			if (value === undefined)
				value = { ok: true };
			if (value && value.__reject)
				return Promise.reject(new Error(value.__reject));
			return Promise.resolve(value);
		};
	}
	const apiCalls = function() { return apiLog.map(function(entry) { return entry.method; }); };
	const apiArgs = function(method) {
		return apiLog.filter(function(entry) { return entry.method === method; }).map(function(entry) { return entry.args; });
	};

	const uciLog = [];
	const uciValues = {};
	let uciSections = [];
	const uci = {
		load: function(config) { uciLog.push([ 'load', config ]); return Promise.resolve(); },
		/* Target SDK uci.unload() is synchronous and returns nothing. */
		unload: function(config) { uciLog.push([ 'unload', config ]); },
		get: function(config, section, option) { return uciValues[config + '.' + section + '.' + option] || null; },
		set: function(config, section, option, value) { uciLog.push([ 'set', config, section, option, value ]); },
		add: function(config, type, name) { uciLog.push([ 'add', config, type, name ]); return name; },
		remove: function(config, section) { uciLog.push([ 'remove', config, section ]); },
		save: function() { uciLog.push([ 'save' ]); return Promise.resolve(); },
		apply: function() { uciLog.push([ 'apply' ]); return Promise.resolve(); },
		sections: function() { return uciSections; }
	};
	api.newSourceName = function() { return 'rp_src_0123456789abcdef01234567'; };
	api.nameAnonymousSources = function() { uciLog.push([ 'name-anonymous' ]); return Promise.resolve(false); };

	const notifications = [];
	const ui = {
		createHandlerFn: function(ctx, fn) {
			return function() { return Promise.resolve(fn.apply(ctx, arguments)); };
		},
		addNotification: function(title, content, level) {
			notifications.push({ text: nodeText(content), level: level });
		}
	};

	const posts = [];
	let postReply = { ok: true };
	const request = {
		post: function(url, data) {
			posts.push({ url: url, data: data });
			const reply = postReply;
			if (reply && reply.__reject)
				return Promise.reject(new Error(reply.__reject));
			return Promise.resolve(reply).then(function(body) { return { json: function() { return Promise.resolve(body); } }; });
		}
	};

	const timers = [];
	let timerSequence = 0;
	const windowObject = {
		setTimeout: function(callback, delay) {
			const timer = { id: ++timerSequence, callback: callback, delay: delay, cancelled: false };
			timers.push(timer);
			return timer.id;
		},
		clearTimeout: function(id) {
			timers.forEach(function(timer) { if (timer.id === id) timer.cancelled = true; });
		},
		location: { href: '' }
	};

	const L = {
		url: function(page) { return '/' + page; },
		env: { token: 'csrf-session-token' }
	};

	const dependencies = {
		view: { extend: function(properties) { return properties; } },
		ui: ui, uci: uci, request: request,
		'routepolicy/api': api,
		'routepolicy/lifecycle': lifecycle
	};
	const globals = { window: windowObject, document: {}, L: L };

	return {
		api: api, apiLog: apiLog, apiCalls: apiCalls, apiArgs: apiArgs,
		uci: uci, uciLog: uciLog, setUciSections: function(sections) { uciSections = sections; },
		notifications: notifications, posts: posts, setPostReply: function(reply) { postReply = reply; },
		timers: timers, window: windowObject, L: L,
		dependencies: dependencies, globals: globals
	};
}

function loadWizard(harness) {
	return loadSource(
		path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/wizard.js'),
		harness.dependencies,
		harness.globals
	);
}

async function renderPage(harness, status, restore) {
	const page = loadWizard(harness);
	const loaded = await page.load();
	const root = page.render(loaded);
	await settle();
	return { page: page, root: root, body: page.body };
}

function activeTimer(harness) {
	const candidates = harness.timers.filter(function(timer) {
		return !timer.cancelled && timer.delay === 2000;
	});
	return candidates[candidates.length - 1] || null;
}

async function runPoll(harness) {
	const timer = activeTimer(harness);
	assert.ok(timer, 'expected an active poll timer');
	timer.cancelled = true;
	timer.callback();
	await settle();
}

/* ---------- fixtures ---------- */

const TOKEN = 'a'.repeat(32);
const EXIT_TOKEN = 'b'.repeat(32);

const DISCOVER = {
	ok: true, schema: 1, missing_dependencies: [],
	unclaimed_devices: [ { name: 'eth1', up: false, carrier: null } ],
	devices: {
		lo: { exists: true, up: true },
		'br-lan': { exists: true, up: true, bridge: true, type: 'bridge' },
		eth0: { exists: true, up: true, type: 'ethernet' },
		eth1: { exists: true, up: false, type: 'ethernet' }
	},
	netifd: { interface: [
		{ interface: 'loopback', up: true, l3_device: 'lo', proto: 'static' },
		{ interface: 'lan', up: true, l3_device: 'br-lan', proto: 'static', 'ipv4-address': [ { address: '192.0.2.1', mask: 24 } ] },
		{ interface: 'wan', up: true, l3_device: 'eth0', proto: 'dhcp', 'ipv4-address': [ { address: '198.51.100.2', mask: 24 } ] },
		{ interface: 'usbwan', up: true, l3_device: 'eth0', proto: 'dhcp', 'ipv4-address': [ { address: '203.0.113.2', mask: 24 } ] }
	] },
	dhcp_roles: [],
	observations: {
		fw4: 'valid', mark_table_preflight: 'clear', dns_listeners: 'dnsmasq',
		warning: 'IPv6 forwarding through this router is rejected by the plan.'
	}
};

const CANDIDATE = [
	'set\troutepolicy.main.enabled\t1',
	'set\troutepolicy.main.lan_interface\tlan',
	'set\tdhcp.lan.ignore\t1',
	'set\tdhcp.lan.ra\tdisabled',
	'set\tdhcp.lan.dhcpv6\tdisabled',
	'set\tdhcp.lan.ndp\tdisabled',
	'set\tnetwork.lan.ipv6\t0',
	'set\tnetwork.wan.metric\t200',
	'set\tsmartdns.rp_init\tsmartdns',
	'set\tsmartdns.rp_init.port\t53',
	'set\tsmartdns.rp_init.tcp_server\t1',
	'set\tsmartdns.rp_init.enabled\t1',
	'set\tdhcp.@dnsmasq[0].port\t0',
	'set\tdhcp.@dnsmasq[0].disabled\t1',
	'set\tdhcp.@dnsmasq[0].localuse\t0',
	'set\tfirewall.rp_init_default.input\tREJECT',
	'set\tfirewall.rp_init_policy.input\tREJECT',
	'set\tfirewall.rp_init_default_nat.target\tMASQUERADE',
	'set\tfirewall.rp_init_dns.dest_port\t53'
].join('\n') + '\n';

const BASELINE = [
	'dhcp.lan.ignore\t0\t-',
	'network.wan.metric\tscalar\t10',
	'smartdns.rp_init.port\t0\t-',
	'dhcp.@dnsmasq[0].port\tscalar\t53'
].join('\n') + '\n';

const PREVIEW = {
	ok: true, operation: 'init-preview', candidate: CANDIDATE, baseline: BASELINE,
	confirmation_timeout: 180, management_address: '192.0.2.1',
	egress_failure_policy: 'fail-closed', link_preparation: 'required\t0\n'
};

const PREPARED = {
	ok: true, operation: 'init-prepare', token: TOKEN, candidate: CANDIDATE, baseline: BASELINE,
	confirmation_timeout: 180, management_address: '192.0.2.9',
	egress_failure_policy: 'fail-closed', link_preparation: 'required\t0\n'
};

const EXIT_PREPARED = {
	ok: true, token: EXIT_TOKEN,
	candidate: 'set\tdhcp.@dnsmasq[0].port\t53\nset\tdhcp.lan.ignore\t0\n',
	baseline: 'dhcp.@dnsmasq[0].port\tscalar\t0\ndhcp.lan.ignore\tscalar\t1\n',
	services: 'smartdns\tenabled\t1\t0\ndnsmasq\trunning\t0\t1'
};

const STATUS_ABSENT = { ok: true, operation: 'init-status', phase: 'absent' };
const STATUS_APPLYING = { ok: true, phase: 'applying', stage: 'dns', job: { kind: 'init', token: TOKEN, state: 'running' } };
const STATUS_PENDING_READY = {
	ok: true, phase: 'pending', token: TOKEN, management_address: '192.0.2.9',
	remaining_seconds: 120, http_confirmation_ready: true, confirmation_transport: 'trusted-luci-or-ssh'
};
const STATUS_PENDING_WAIT = {
	ok: true, phase: 'pending', token: TOKEN, management_address: '192.0.2.9',
	remaining_seconds: 42, http_confirmation_ready: false, confirmation_transport: 'trusted-luci-or-ssh'
};
const STATUS_CONFIRMING = { ok: true, phase: 'confirming', token: TOKEN };
const STATUS_CONFIRMED = {
	ok: true, phase: 'confirmed', token: TOKEN,
	health: {
		topology: {
			management_address: '192.0.2.9',
			interfaces: { access: 'lan', default: 'wan', policy: 'rp_init_policy' },
			default_egress: 'verified'
		},
		dns_queries: [
			{ group: 'rp_init_default', transport: 'udp', rcode: 'NOERROR' },
			{ group: 'rp_init_default', transport: 'tcp', rcode: 'NXDOMAIN' },
			{ group: 'rp_init_policy', transport: 'tcp', rcode: 'SERVFAIL' }
		],
		rules_loaded: true,
		sets_loaded: true,
		policy_egress: 'verified'
	}
};
const RESTORE_IDLE = { ok: true, schema: 1, candidate_pending: false, declaration_phase: 'absent', init_token: '', unportable_fields: '', runtime_imported: false };

/* ---------- scenarios ---------- */

async function loadReadOnlyContract() {
	const harness = createHarness({
		init_status: [ STATUS_ABSENT ],
		restore_status: [ RESTORE_IDLE ]
	});
	const rendered = await renderPage(harness, STATUS_ABSENT, RESTORE_IDLE);
	assert.ok((rendered.root.getAttribute('class') || '').split(/\s+/).includes('cbi-map'));
	for (const method of harness.apiCalls()) {
		assert.ok(method === 'init_status' || method === 'restore_status',
			'page load must stay read-only, got ' + method);
	}
	assert.deepStrictEqual(harness.uciLog, [ [ 'load', 'routepolicy' ] ]);
	const text = nodeText(rendered.root);
	for (const expected of [ '未初始化', '首次配置向导', '导入恢复', '退出', '重新检测状态', '默认启用开关' ])
		assert.ok(text.includes(expected), 'overview must show ' + expected);
	assert.strictEqual(findAll(rendered.body, node => nodeText(node) === '默认启用开关').length, 0,
		'the installation default must not be a current status row');
	assert.ok(button(rendered.root, 'open-init'), 'first-time wizard entry must render');
	assert.ok(!text.includes('[object'), 'no stringified objects in the rendered page');
}

async function standaloneDeviceDiscoveryContract() {
	/* The isolated OpenWrt device reported eth0 as a bridge member without a master field.
	 * The physically present, admin-down eth2 did not appear in netifd's device map. */
	const discovered = Object.assign({}, DISCOVER, {
		devices: {
			lo: { up: true },
			'br-lan': { up: true, type: 'bridge', devtype: 'bridge', 'bridge-members': [ 'eth0' ] },
			eth0: { up: true, type: 'Network device', devtype: 'ethernet' },
			eth1: { up: true, type: 'Network device', devtype: 'ethernet' }
		},
		netifd: { interface: [
			{ interface: 'loopback', up: true, l3_device: 'lo', proto: 'static', 'ipv4-address': [ { address: '127.0.0.1', mask: 8 } ] },
			{ interface: 'lan', up: true, l3_device: 'br-lan', proto: 'static', 'ipv4-address': [ { address: '192.0.2.1', mask: 24 } ] },
			{ interface: 'wan', up: true, l3_device: 'eth1', proto: 'dhcp', 'ipv4-address': [ { address: '198.51.100.2', mask: 24 } ] },
			{ interface: 'wan6', up: false, device: 'eth1', proto: 'dhcpv6' }
		] },
		unclaimed_devices: [ { name: 'eth2', up: false, carrier: null } ]
	});
	const optionValues = function(select) { return select.children.map(function(option) { return option.value; }); };
	for (const scenario of [
		[ discovered.unclaimed_devices, 'eth2（未启用）' ],
		[ undefined, '无法枚举，请核对 RoutePolicy 核心组件版本' ],
		[ [], '没有可确认的独立网卡' ]
	]) {
		const devices = scenario[0];
		const canCreate = !!(devices && devices.length);
		const harness = createHarness({
			init_status: [ STATUS_ABSENT ], restore_status: [ RESTORE_IDLE ],
			init_discover: [ Object.assign({}, discovered, { unclaimed_devices: devices }) ],
			init_preview: [ PREVIEW ]
		});
		const rendered = await renderPage(harness);
		await button(rendered.body, 'open-init').click();
		await settle();
		const form = rendered.page.form;
		const text = nodeText(rendered.body);
		assert.ok(text.includes(scenario[1]));
		assert.ok(text.includes('loopback') && text.includes('wan6'), 'diagnostics still show all discovered interfaces');
		assert.deepStrictEqual(optionValues(form.accessSelect), [ '-', 'lan' ]);
		const egress = canCreate ? [ '-', 'lan', 'wan', '---create---' ] : [ '-', 'lan', 'wan' ];
		assert.deepStrictEqual(optionValues(form.defaultSelect), egress, 'the default exit can share the access interface');
		assert.deepStrictEqual(optionValues(form.policySelect), egress);
		assert.strictEqual(form.defaultSelect.value, '-');
		assert.strictEqual(form.policySelect.value, '-');
		assert.deepStrictEqual(optionValues(form.deviceSelect), canCreate ? [ 'eth2' ] : [ '-' ]);
		assert.deepStrictEqual(harness.apiCalls(), [ 'init_status', 'restore_status', 'read_user_list', 'init_discover' ]);
		assert.deepStrictEqual(harness.uciLog, [ [ 'load', 'routepolicy' ] ]);
		if (canCreate) {
			form.defaultSelect.value = 'wan';
			form.policySelect.value = '---create---';
			form.dnsPolicy.value = '203.0.113.53';
			await button(rendered.body, 'make-preview').click();
			assert.deepStrictEqual(harness.apiArgs('init_preview'), [ [ 'lan\twan\trp_init_policy\tpolicy\teth2\tdhcp\t-\t-\t-\t-\t-\t-\t203.0.113.53' ] ]);
			assert.deepStrictEqual(harness.apiArgs('init_prepare'), []);
		}
	}
}

async function initHappyPathContract() {
	const harness = createHarness({
		init_status: [ STATUS_ABSENT, STATUS_ABSENT, STATUS_APPLYING, STATUS_PENDING_READY, STATUS_CONFIRMING, STATUS_CONFIRMED ],
		restore_status: [ RESTORE_IDLE ],
		init_discover: [ DISCOVER ],
		init_preview: [ PREVIEW ],
		init_prepare: [ PREPARED ],
		init_apply: [ { ok: true, message: 'accepted' } ]
	});
	const rendered = await renderPage(harness, STATUS_ABSENT, RESTORE_IDLE);
	const page = rendered.page;
	const body = rendered.body;

	await button(body, 'open-init').click();
	await settle();
	const formText = nodeText(body);
	for (const expected of [ 'lan', 'wan', 'usbwan', 'eth1', '已识别未配置的独立网卡', '生成只读预览', '人工规则与清单来源' ])
		assert.ok(formText.includes(expected), 'init form must show ' + expected);

	page.form.accessSelect.value = 'lan';
	page.form.defaultSelect.value = 'wan';
	page.form.policySelect.value = '---create---';
	page.form.deviceSelect.value = 'eth1';
	page.form.protoSelect.value = 'dhcp';
	page.form.dnsPolicy.value = '223.5.5.5';

	await button(body, 'make-preview').click();
	await settle();
	const expectedContent = 'lan\twan\trp_init_policy\tpolicy\teth1\tdhcp\t-\t-\t-\t-\t-\t-\t223.5.5.5';
	assert.deepStrictEqual(harness.apiArgs('init_preview'), [ [ expectedContent ] ],
		'preview must send the exact 13-field TSV line');
	const previewText = nodeText(body);
	for (const expected of [
		'只读预览', '180', '192.0.2.1', 'fail-closed', 'dhcp.lan.ignore', 'dhcp.@dnsmasq[0].disabled',
		'DHCPv4', 'IPv4-only', 'SmartDNS', 'dnsmasq', 'fw4', 'AAAA', '单人维护', '终端与主路由',
		'候选关键项', '（不存在或未提供）', '✓ dnsmasq 配置关闭 DNS 监听（port=0）', '✓ dnsmasq 配置禁用实例（disabled=1）'
	])
		assert.ok(previewText.includes(expected), 'preview must show ' + expected);

	/* Danger confirmation is required before prepare. */
	await button(body, 'do-prepare').click();
	await settle();
	assert.strictEqual(harness.apiArgs('init_prepare').length, 0, 'prepare must be blocked without the acknowledgement');
	assert.ok(nodeText(page.feedback).includes('请先勾选'), 'missing acknowledgement must stay visible');

	const previewAck = findAll(body, function(node) { return node.tagName === 'input' && node.getAttribute('id') === 'routepolicy-preview-ack'; })[0];
	previewAck.checked = true;
	await confirmedClick(rendered, 'do-prepare');
	await settle();
	assert.deepStrictEqual(harness.apiArgs('init_prepare'), [ [ expectedContent ] ]);
	const preparedText = nodeText(body);
	for (const expected of [ '候选已准备', '192.0.2.9', '开始应用（危险确认）', '确认超时窗口', '候选关键项' ])
		assert.ok(preparedText.includes(expected), 'prepared view must show ' + expected);

	/* Danger confirmation is required before apply; repeat clicks never re-apply. */
	await button(body, 'do-apply').click();
	await settle();
	assert.strictEqual(harness.apiArgs('init_apply').length, 0, 'apply must be blocked without the acknowledgement');
	const applyAck = findAll(body, function(node) { return node.tagName === 'input' && node.getAttribute('id') === 'routepolicy-apply-ack'; })[0];
	applyAck.checked = true;
	const firstClick = button(body, 'do-apply').click();
	const secondClick = button(body, 'do-apply').click();
	assert.deepStrictEqual(harness.apiArgs('init_apply'), [], 'opening confirmation must not apply');
	acceptConfirmation(rendered, firstClick);
	await Promise.all([ firstClick, secondClick ]);
	await settle();
	assert.deepStrictEqual(harness.apiArgs('init_apply'), [ [ TOKEN ] ],
		'double-clicking apply must send exactly one short request');

	assert.ok(nodeText(body).includes('应用中'), 'polling must show the applying phase');
	await runPoll(harness);
	const pendingText = nodeText(body);
	for (const expected of [ '待重连确认', '192.0.2.9', '120', 'trusted-luci-or-ssh', '我已重新连接，确认生效', '在新管理地址打开本页面' ])
		assert.ok(pendingText.includes(expected), 'pending view must show ' + expected);
	const reconnectLink = findAll(body, function(node) { return node.tagName === 'a' && String(node.getAttribute('href') || '').indexOf('https://192.0.2.9/') === 0; })[0];
	assert.ok(reconnectLink, 'the pending view must keep a direct re-login entry at the candidate address');

	await button(body, 'http-confirm').click();
	await settle();
	assert.strictEqual(harness.posts.length, 1, 'exactly one HTTP confirmation POST');
	assert.strictEqual(harness.posts[0].url, '/admin/services/routepolicy/confirm');
	assert.ok(harness.posts[0].data instanceof FormData,
		'the confirmation must use a real form body because http.formvalue does not parse JSON');
	assert.strictEqual(harness.posts[0].data.get('token'), 'csrf-session-token');
	assert.strictEqual(harness.posts[0].data.get('transaction_token'), TOKEN);
	assert.ok(harness.posts[0].url.indexOf(TOKEN) < 0, 'the transaction token must never appear in the URL');
	assert.strictEqual(harness.apiCalls().filter(function(m) { return m === 'init_confirm' || m === 'initConfirm'; }).length, 0,
		'the always-refused ubus confirm method must never be called');

	assert.ok(nodeText(body).includes('确认中'), 'the immediate poll after confirmation must show the confirming phase');
	await runPoll(harness);
	const confirmedText = nodeText(body);
	for (const expected of [ '已生效', 'SERVFAIL', '部分检查未通过', '事务验收', '无 A 结果', 'nft 域名/静态集合装载' ])
		assert.ok(confirmedText.includes(expected), 'confirmed view must show ' + expected);
	const checkRows = findAll(body, function(node) { return node.getAttribute && node.getAttribute('data-check'); });
	assert.ok(checkRows.some(function(row) { return row.getAttribute('data-check') === 'pass' && nodeText(row).includes('NXDOMAIN'); }),
		'NXDOMAIN on a reserved .test probe proves the DNS path answers and must not be misreported as a failure');
	const failedChecks = checkRows.filter(function(row) { return row.getAttribute('data-check') === 'fail'; });
	assert.ok(failedChecks.length >= 1 && failedChecks.every(function(row) { return nodeText(row).includes('SERVFAIL'); }),
		'a failing DNS probe must render as a failing row, not all-green');
	assert.strictEqual(activeTimer(harness), null, 'polling must stop once a terminal phase is reached');
}

async function confirmRejectionContract() {
	const harness = createHarness({
		init_status: [ STATUS_PENDING_READY ],
		'init_status#last': STATUS_PENDING_READY,
		restore_status: [ RESTORE_IDLE ]
	});
	const rendered = await renderPage(harness, STATUS_PENDING_READY, RESTORE_IDLE);
	harness.setPostReply({ ok: false, error: '确认来源地址与候选管理地址不符' });
	await button(rendered.body, 'http-confirm').click();
	await settle();
	assert.ok(nodeText(rendered.page.feedback).includes('确认来源地址与候选管理地址不符'),
		'a rejected HTTP confirmation must stay visible as a persistent error');
	assert.ok(nodeText(rendered.body).includes('待重连确认'), 'a rejected confirmation must leave the pending state visible');
}

async function confirmationTransportContract() {
	for (const scenario of [
		[ STATUS_CONFIRMED, 'success' ],
		[ Object.assign({}, STATUS_CONFIRMED, { token: EXIT_TOKEN }), 'different-token' ],
		[ Object.assign({}, STATUS_CONFIRMED, { confirmation_error: '收尾失败' }), 'finish-error' ],
		[ STATUS_CONFIRMED, 'new-feedback' ]
	]) {
		const harness = createHarness({
			init_status: [ STATUS_PENDING_READY, STATUS_CONFIRMING, scenario[0] ], 'restore_status#last': RESTORE_IDLE
		});
		harness.setPostReply({ __reject: 'XHR request timed out' });
		const rendered = await renderPage(harness);
		await button(rendered.body, 'http-confirm').click();
		assert.ok(nodeText(rendered.page.feedback).includes('连接确认结果待核实'));
		assert.ok(nodeText(rendered.body).includes('确认中'));
		assert.ok(!nodeText(rendered.page.feedback).includes('操作失败'));
		if (scenario[1] === 'new-feedback')
			rendered.page.fail('后发操作错误');
		await runPoll(harness);
		const feedback = nodeText(rendered.page.feedback);
		if (scenario[1] === 'success') {
			assert.ok(feedback.includes('设备已确认本次网络变更'));
			assert.ok(!feedback.includes('XHR request timed out'));
		} else if (scenario[1] === 'new-feedback') {
			assert.ok(feedback.includes('后发操作错误'));
		} else {
			assert.ok(feedback.includes('连接确认结果待核实'));
			if (scenario[1] === 'finish-error')
				assert.ok(nodeText(rendered.body).includes('收尾失败') && button(rendered.body, 'confirm-finish'));
		}
		assert.strictEqual(harness.posts.length, 1);
	}

	let rejectLate;
	const lateReply = new Promise(function(resolve, reject) { rejectLate = reject; });
	const different = Object.assign({}, STATUS_CONFIRMED, { token: EXIT_TOKEN });
	const harness = createHarness({
		init_status: [ STATUS_PENDING_READY, different ], 'init_status#last': different, 'restore_status#last': RESTORE_IDLE
	});
	harness.setPostReply(lateReply);
	const rendered = await renderPage(harness);
	const confirming = button(rendered.body, 'http-confirm').click();
	await runPoll(harness);
	rendered.page.fail('新事务错误');
	rejectLate(new Error('上一事务的迟到超时'));
	await confirming;
	assert.ok(nodeText(rendered.page.feedback).includes('新事务错误'));
	assert.ok(!nodeText(rendered.page.feedback).includes('上一事务的迟到超时'));
	assert.strictEqual(harness.posts.length, 1);
}

async function offlinePollingContract() {
	const harness = createHarness({
		init_status: [ STATUS_ABSENT, STATUS_APPLYING, { __reject: 'connection lost' }, STATUS_PENDING_READY ],
		restore_status: [ RESTORE_IDLE ],
		init_apply: [ { ok: true } ]
	});
	const rendered = await renderPage(harness, STATUS_ABSENT, RESTORE_IDLE);
	const page = rendered.page;
	/* Simulate an already prepared transaction via the prepared view API path. */
	page.renderPrepared(Object.assign({}, PREPARED), 'init');
	const applyAck = findAll(page.body, function(node) { return node.tagName === 'input' && node.getAttribute('id') === 'routepolicy-apply-ack'; })[0];
	applyAck.checked = true;
	await confirmedClick(rendered, 'do-apply');
	await settle();
	assert.ok(nodeText(page.body).includes('应用中'));
	await runPoll(harness);
	const unknownText = nodeText(page.body);
	assert.ok(unknownText.includes('状态未知'), 'a failed status poll must show the unknown state');
	assert.ok(button(page.body, 'refresh-status'), 'an explicit re-check entry must exist while offline');
	assert.ok(activeTimer(harness), 'polling must keep retrying while offline');
	await runPoll(harness);
	assert.ok(nodeText(page.body).includes('待重连确认'), 'polling must recover after the backend answers again');
}

function reviewedApplyButton(rendered, kind, token) {
	rendered.page.renderPrepared(Object.assign({}, PREPARED, { token: token }), kind);
	findAll(rendered.body, function(node) { return node.getAttribute('id') === 'routepolicy-apply-ack'; })[0].checked = true;
	return button(rendered.body, 'do-apply');
}

async function inlineConfirmationContract() {
	const prepared = { ok: true, phase: 'prepared', token: TOKEN };
	const harness = createHarness({
		init_status: [ prepared, STATUS_PENDING_READY ], 'restore_status#last': RESTORE_IDLE,
		init_apply: [ { ok: true } ]
	});
	const rendered = await renderPage(harness);
	const apply = reviewedApplyButton(rendered, 'init', TOKEN);
	const opening = apply.click();
	const staleAccept = button(rendered.root, 'confirmation-accept');
	assert.ok(rendered.body.inert && staleAccept);
	assert.ok(nodeText(rendered.page.confirmation).includes('即将应用候选'));
	await button(rendered.body, 'back-overview-prepared').click();
	assert.strictEqual(rendered.page.current, 'prepared');
	assert.deepStrictEqual(harness.apiArgs('init_apply'), []);
	button(rendered.root, 'confirmation-cancel').click();
	await opening;
	assert.strictEqual(rendered.body.inert, false);
	assert.strictEqual(button(rendered.root, 'confirmation-accept'), null);
	assert.ok(!apply.disabled && rendered.page.current === 'prepared');
	staleAccept.click();
	assert.deepStrictEqual(harness.apiArgs('init_apply'), [], 'a canceled confirmation cannot be submitted later');
	await confirmedClick(rendered, apply);
	assert.deepStrictEqual(harness.apiArgs('init_apply'), [ [ TOKEN ] ]);

	const changing = createHarness({
		init_status: [ prepared, STATUS_PENDING_READY ], 'restore_status#last': RESTORE_IDLE
	});
	const view = await renderPage(changing);
	const cancelCandidate = button(view.body, 'cancel-candidate').click();
	await runPoll(changing);
	await acceptConfirmation(view, cancelCandidate);
	assert.deepStrictEqual(changing.apiArgs('init_cancel'), [], 'an overview confirmation must not survive a change of phase');
	assert.ok(nodeText(view.page.feedback).includes('设备状态已变化'));
	assert.ok(button(view.body, 'http-confirm'));
}

async function applyReplyLossContract() {
	const prepared = { ok: true, phase: 'prepared', token: TOKEN };
	const rolled = { ok: true, phase: 'rolled_back', token: TOKEN };
	let harness = createHarness({
		init_status: [ prepared, STATUS_PENDING_READY, rolled ],
		'restore_status#last': RESTORE_IDLE,
		init_apply: [ { __reject: 'network response lost' } ]
	});
	let rendered = await renderPage(harness);
	await confirmedClick(rendered, reviewedApplyButton(rendered, 'init', TOKEN));
	assert.ok(button(rendered.body, 'http-confirm'), 'a lost reply must not hide the actual pending confirmation');
	assert.ok(nodeText(rendered.body).includes('在新管理地址打开本页面'));
	assert.ok(nodeText(rendered.page.feedback).includes('请求结果未知') && nodeText(rendered.page.feedback).includes('network response lost'));
	assert.ok(!nodeText(rendered.page.feedback).includes('操作失败'));
	assert.ok(!nodeText(rendered.body).includes('网络尚未修改'));
	assert.strictEqual(button(rendered.body, 'do-apply'), null);
	await runPoll(harness);
	assert.ok(nodeText(rendered.body).includes('已回滚'));
	assert.strictEqual(activeTimer(harness), null);
	assert.deepStrictEqual(harness.apiCalls(), [ 'init_status', 'restore_status', 'init_apply', 'init_status', 'restore_status', 'init_status', 'restore_status' ]);
	assert.deepStrictEqual(harness.apiArgs('init_apply'), [ [ TOKEN ] ]);
	assert.strictEqual(harness.posts.length, 0);

	const priorConfirmed = Object.assign({}, STATUS_CONFIRMED, { exit_candidate_available: true });
	const exiting = { ok: true, phase: 'rolling_back', token: EXIT_TOKEN };
	const exitRolled = Object.assign({}, rolled, { token: EXIT_TOKEN });
	harness = createHarness({
		init_status: [ priorConfirmed, { __reject: 'cannot reach device' }, exiting, exitRolled ],
		'restore_status#last': RESTORE_IDLE,
		exit_apply: [ { __reject: 'exit reply lost' } ]
	});
	rendered = await renderPage(harness);
	await confirmedClick(rendered, reviewedApplyButton(rendered, 'exit', EXIT_TOKEN));
	assert.ok(nodeText(rendered.body).includes('状态未知'));
	assert.ok(nodeText(rendered.page.feedback).includes('exit reply lost'));
	assert.strictEqual(button(rendered.body, 'do-apply'), null);
	assert.strictEqual(button(rendered.body, 'view-exit-candidate'), null, 'do not offer a stale exit candidate while offline');
	await runPoll(harness);
	assert.ok(nodeText(rendered.body).includes('回滚中'));
	await runPoll(harness);
	assert.ok(nodeText(rendered.body).includes('已回滚'));
	assert.strictEqual(activeTimer(harness), null);
	assert.deepStrictEqual(harness.apiCalls(), [ 'init_status', 'restore_status', 'exit_apply', 'init_status', 'restore_status', 'init_status', 'restore_status', 'init_status', 'restore_status' ]);
	assert.deepStrictEqual(harness.apiArgs('exit_apply'), [ [ EXIT_TOKEN ] ]);
	assert.strictEqual(harness.posts.length, 0);

	for (const scenario of [
		[ '预览已过期', { ok: true, phase: 'expired', token: TOKEN }, '候选已过期' ],
		[ '无法读取 RoutePolicy 生命周期响应', STATUS_PENDING_READY, '待重连确认' ]
	]) {
		harness = createHarness({
			init_status: [ prepared, scenario[1] ], 'restore_status#last': RESTORE_IDLE,
			init_apply: [ { ok: false, error: scenario[0] } ]
		});
		rendered = await renderPage(harness);
		await confirmedClick(rendered, reviewedApplyButton(rendered, 'init', TOKEN));
		const feedback = nodeText(rendered.page.feedback);
		assert.ok(feedback.includes(scenario[0]) && feedback.includes('实际进度以状态总览为准'));
		assert.ok(!feedback.includes('操作失败'));
		assert.ok(nodeText(rendered.body).includes(scenario[2]));
		assert.strictEqual(button(rendered.body, 'do-apply'), null);
	}
}

async function applyReplyNavigationContract() {
	const prepared = { ok: true, phase: 'prepared', token: TOKEN };
	const rolled = { ok: true, phase: 'rolled_back', token: TOKEN };
	for (const leaveBeforeReply of [ true, false ]) {
		let rejectApply, resolveOldStatus;
		const applyReply = new Promise(function(resolve, reject) { rejectApply = reject; });
		const oldStatus = new Promise(function(resolve) { resolveOldStatus = resolve; });
		const harness = createHarness({
			init_status: [ prepared, prepared, oldStatus, STATUS_PENDING_READY ],
			'restore_status#last': RESTORE_IDLE,
			'init_discover#last': DISCOVER,
			init_apply: [ applyReply ]
		});
		const rendered = await renderPage(harness);
		const apply = reviewedApplyButton(rendered, 'init', TOKEN);
		const waiting = confirmedClick(rendered, apply);
		await settle();
		assert.ok(apply.disabled && nodeText(rendered.body).includes('已发送应用请求'));
		assert.ok(!nodeText(rendered.body).includes('网络尚未修改'));
		await button(rendered.body, 'back-overview-prepared').click();
		await settle();
		if (!leaveBeforeReply) {
			rejectApply(new Error('late reply lost'));
			await settle();
		}
		await button(rendered.body, 'open-init').click();
		await settle();
		const form = rendered.page.form;
		const feedback = nodeText(rendered.page.feedback);
		assert.ok(form);
		if (leaveBeforeReply) {
			rejectApply(new Error('late reply lost'));
			await settle();
		}
		assert.strictEqual(harness.apiArgs('init_status').length, 3, 'a sent request always reads status after the reply');
		assert.strictEqual(rendered.page.form, form);
		assert.strictEqual(nodeText(rendered.page.feedback), feedback, 'late apply reply must not replace the form feedback');
		assert.ok(!nodeText(rendered.body).includes('刚审阅的候选管理地址'), 'the reconnect hint belongs to the overview');
		await button(rendered.body, 'back-overview-init').click();
		await settle();
		resolveOldStatus(rolled);
		await waiting;
		assert.ok(button(rendered.body, 'http-confirm'), 'an old post-apply read must not overwrite the newer overview');
		assert.ok(activeTimer(harness));
		await apply.click();
		assert.deepStrictEqual(harness.apiArgs('init_apply'), [ [ TOKEN ] ], 'a detached apply button must not submit again');
		assert.strictEqual(harness.posts.length, 0);
	}
}

async function applyRegistrationContract() {
	const prepared = { ok: true, phase: 'prepared', token: TOKEN };
	const split = Object.assign({}, prepared, { job: { kind: 'init', token: TOKEN, state: 'done' } });
	const rolled = { ok: true, phase: 'rolled_back', token: TOKEN };
	for (const scenario of [
		[ prepared, { __reject: 'reply lost before job registration' } ],
		[ prepared, { ok: false, error: '后台事务尚未登记，请刷新状态核对' } ],
		[ split, { ok: true } ]
	]) {
		const harness = createHarness({
			init_status: [ prepared, scenario[0], scenario[0], STATUS_PENDING_READY, rolled ],
			'restore_status#last': RESTORE_IDLE,
			init_apply: [ scenario[1] ]
		});
		const rendered = await renderPage(harness);
		await confirmedClick(rendered, reviewedApplyButton(rendered, 'init', TOKEN));
		for (let read = 0; read < 2; read++) {
			assert.ok(nodeText(rendered.body).includes('等待设备报告提交状态'));
			assert.ok(!nodeText(rendered.body).includes('尚未修改网络'));
			assert.strictEqual(button(rendered.body, 'view-candidate'), null);
			assert.strictEqual(button(rendered.body, 'http-confirm'), null);
			assert.ok(button(rendered.body, 'cancel-candidate'));
			await runPoll(harness);
		}
		assert.ok(button(rendered.body, 'http-confirm'));
		await runPoll(harness);
		assert.ok(nodeText(rendered.body).includes('已回滚'));
		assert.strictEqual(activeTimer(harness), null);
		assert.deepStrictEqual(harness.apiArgs('init_apply'), [ [ TOKEN ] ]);
		assert.deepStrictEqual(harness.apiArgs('init_recover'), []);
		assert.strictEqual(harness.posts.length, 0);
	}

	/* A newly loaded tab sees the same snapshots without knowing about the original click. */
	const fresh = createHarness({
		init_status: [ prepared, split, STATUS_PENDING_READY ], 'restore_status#last': RESTORE_IDLE
	});
	let rendered = await renderPage(fresh);
	assert.ok(button(rendered.body, 'view-candidate'), 'a freshly prepared candidate remains reviewable');
	await runPoll(fresh);
	assert.strictEqual(button(rendered.body, 'view-candidate'), null, 'a split phase/job reply must not offer apply');
	await runPoll(fresh);
	assert.ok(button(rendered.body, 'http-confirm'));
	assert.ok(fresh.apiCalls().every(function(method) { return method === 'init_status' || method === 'restore_status'; }));

	const expired = { ok: true, phase: 'expired', token: TOKEN, prepared_expired_reason: 'cancelled-unapplied' };
	const canceled = createHarness({
		init_status: [ prepared, prepared, expired ], 'restore_status#last': RESTORE_IDLE,
		init_apply: [ { __reject: 'reply lost' } ], init_cancel: [ expired ]
	});
	rendered = await renderPage(canceled);
	await confirmedClick(rendered, reviewedApplyButton(rendered, 'init', TOKEN));
	await confirmedClick(rendered, 'cancel-candidate');
	assert.deepStrictEqual(canceled.apiArgs('init_cancel'), [ [ TOKEN ] ]);
	assert.strictEqual(activeTimer(canceled), null, 'scoped cancellation ends the submitted intent once read back');
	assert.ok(!nodeText(rendered.body).includes('等待设备报告提交状态'));

	const newer = Object.assign({}, prepared, { token: 'c'.repeat(32) });
	const crossed = Object.assign({}, newer, { job: split.job });
	const replaced = createHarness({
		init_status: [ prepared, crossed, newer ], 'restore_status#last': RESTORE_IDLE,
		init_apply: [ { __reject: 'reply lost' } ]
	});
	rendered = await renderPage(replaced);
	await confirmedClick(rendered, reviewedApplyButton(rendered, 'init', TOKEN));
	assert.strictEqual(button(rendered.body, 'cancel-candidate'), null, 'crossed tokens cannot identify a candidate to cancel');
	await runPoll(replaced);
	assert.ok(button(rendered.body, 'view-candidate'), 'a coherent replacement releases the old submitted intent');
	assert.deepStrictEqual(replaced.apiArgs('init_apply'), [ [ TOKEN ] ]);

	/* Exit candidates have a separate token from the current network record. */
	const prior = Object.assign({}, STATUS_CONFIRMED, { exit_candidate_available: true });
	const exit = createHarness({
		'init_status#last': prior, 'restore_status#last': RESTORE_IDLE,
		exit_apply: [ { __reject: 'exit reply lost before job registration' } ],
		exit_candidate: [ { ok: true, token: EXIT_TOKEN }, { ok: true, token: 'c'.repeat(32) } ]
	});
	rendered = await renderPage(exit);
	await confirmedClick(rendered, reviewedApplyButton(rendered, 'exit', EXIT_TOKEN));
	assert.ok(nodeText(rendered.body).includes('等待设备报告提交状态'));
	assert.strictEqual(button(rendered.body, 'view-exit-candidate'), null);
	await runPoll(exit);
	assert.ok(button(rendered.body, 'view-exit-candidate'), 'a verified replacement candidate can be reviewed');
	assert.deepStrictEqual(exit.apiArgs('exit_apply'), [ [ EXIT_TOKEN ] ]);
}

async function exitLockRefusalReloadContract() {
	const prior = Object.assign({}, STATUS_CONFIRMED, { exit_candidate_available: true });
	const harness = createHarness({
		'init_status#last': prior, 'restore_status#last': RESTORE_IDLE,
		exit_apply: [ { ok: false, error: '统一写入门禁忙、owner 失效或已有 writer 未退出' } ],
		'exit_candidate#last': { ok: true, token: EXIT_TOKEN }
	});
	let reloads = 0;
	harness.window.location.reload = function() { reloads++; };
	const rendered = await renderPage(harness);
	await confirmedClick(rendered, reviewedApplyButton(rendered, 'exit', EXIT_TOKEN));
	await runPoll(harness);
	assert.ok(nodeText(rendered.body).includes('设备可能仍在处理'));
	assert.strictEqual(button(rendered.body, 'view-exit-candidate'), null);
	const reload = button(rendered.body, 'reload-page');
	assert.ok(reload && !reload.disabled);
	const calls = harness.apiCalls();
	await reload.click();
	assert.strictEqual(reloads, 1);
	assert.deepStrictEqual(harness.apiCalls(), calls, 'reloading does not call any RPC');
	const fresh = await renderPage(harness);
	assert.ok(button(fresh.body, 'view-exit-candidate'), 'a new page can review the candidate reported by the device');
	assert.strictEqual(button(fresh.body, 'reload-page'), null);
	assert.deepStrictEqual(harness.apiCalls().slice(calls.length), [ 'init_status', 'restore_status' ]);
	assert.deepStrictEqual(harness.apiArgs('exit_apply'), [ [ EXIT_TOKEN ] ]);
}

async function reviewedReconnectAddressContract() {
	const offline = { __reject: 'old management address unreachable' };
	const rolled = { ok: true, phase: 'rolled_back', token: TOKEN };
	const harness = createHarness({
		init_status: [ STATUS_ABSENT, STATUS_ABSENT, offline, offline, STATUS_PENDING_READY, rolled, offline ],
		restore_status: [ RESTORE_IDLE, offline, offline, RESTORE_IDLE, RESTORE_IDLE, offline ],
		init_discover: [ DISCOVER ],
		init_preview: [ Object.assign({}, PREVIEW, { management_address: PREPARED.management_address }) ],
		init_prepare: [ PREPARED ],
		init_apply: [ { __reject: 'connection reset while the address changed' } ]
	});
	harness.window.location = { protocol: 'http:', port: '8080' };
	const rendered = await renderPage(harness);
	const body = rendered.body;
	await button(body, 'open-init').click();
	await settle();
	const form = rendered.page.form;
	form.accessSelect.value = 'lan';
	form.defaultSelect.value = 'wan';
	form.policySelect.value = 'usbwan';
	form.mgmtUse.value = 'change';
	form.mgmtIp.value = PREPARED.management_address;
	form.mgmtPrefix.value = '24';
	await button(body, 'make-preview').click();
	findAll(body, function(node) { return node.getAttribute('id') === 'routepolicy-preview-ack'; })[0].checked = true;
	await confirmedClick(rendered, 'do-prepare');
	assert.ok(nodeText(body).includes(PREPARED.management_address));
	findAll(body, function(node) { return node.getAttribute('id') === 'routepolicy-apply-ack'; })[0].checked = true;
	await confirmedClick(rendered, 'do-apply');
	for (let read = 0; read < 2; read++) {
		assert.ok(nodeText(body).includes('状态未知') && nodeText(body).includes('刚审阅的候选管理地址'));
		assert.ok(findAll(body, function(node) {
			return node.tagName === 'a' && node.getAttribute('href') === 'http://192.0.2.9:8080/admin/services/routepolicy/wizard';
		}).length);
		assert.strictEqual(rendered.page.status.phase, 'absent');
		assert.strictEqual(button(body, 'http-confirm'), null, 'candidate address cannot authorize confirmation');
		await runPoll(harness);
	}
	assert.ok(button(body, 'http-confirm'));
	assert.ok(!nodeText(body).includes('刚审阅的候选管理地址'));
	await runPoll(harness);
	assert.ok(nodeText(body).includes('已回滚'));
	await button(body, 'refresh-status').click();
	assert.ok(nodeText(body).includes('状态未知'));
	assert.ok(!nodeText(body).includes('刚审阅的候选管理地址'), 'terminal status discards the reviewed address hint');
	assert.deepStrictEqual(harness.apiArgs('init_apply'), [ [ TOKEN ] ]);
	assert.strictEqual(harness.posts.length, 0);
}

async function httpNotReadyContract() {
	const harness = createHarness({
		init_status: [ STATUS_PENDING_WAIT ],
		'init_status#last': STATUS_PENDING_WAIT,
		restore_status: [ RESTORE_IDLE ]
	});
	const rendered = await renderPage(harness, STATUS_PENDING_WAIT, RESTORE_IDLE);
	const text = nodeText(rendered.body);
	assert.ok(text.includes('待重连确认'), 'pending must be visible');
	assert.ok(text.includes('42'), 'backend remaining seconds must be shown');
	assert.ok(text.includes('尚未就绪'), 'not-ready state must be explained');
	assert.strictEqual(button(rendered.body, 'http-confirm'), null, 'no confirm button before the backend allows HTTP confirmation');
	assert.strictEqual(harness.posts.length, 0);
}

async function phaseHandlingContract() {
	/* expired */
	let harness = createHarness({ init_status: [ { ok: true, phase: 'expired', prepared_expired_reason: 'superseded' } ], restore_status: [ RESTORE_IDLE ] });
	let rendered = await renderPage(harness, { ok: true, phase: 'expired' }, RESTORE_IDLE);
	assert.ok(nodeText(rendered.body).includes('候选已过期'));
	assert.ok(nodeText(rendered.body).includes('superseded'));
	assert.ok(button(rendered.body, 'restart-init'));

	/* rolled back */
	harness = createHarness({ init_status: [ { ok: true, phase: 'rolled_back' } ], restore_status: [ RESTORE_IDLE ] });
	rendered = await renderPage(harness, { ok: true, phase: 'rolled_back' }, RESTORE_IDLE);
	assert.ok(nodeText(rendered.body).includes('已回滚'));

	/* conflict with pending restore declaration */
	const conflictStatus = { ok: true, phase: 'conflict', conflicts: 'external dhcp.lan changes' };
	const conflictRestore = Object.assign({}, RESTORE_IDLE, { candidate_pending: true, declaration_phase: 'installed' });
	harness = createHarness({
		init_status: [ conflictStatus ],
		'init_status#last': conflictStatus,
		restore_status: [ conflictRestore ],
		'restore_status#last': conflictRestore,
		init_recover: [ { ok: true, message: '恢复完成' } ],
		restore_recover: [ { ok: true, message: '声明已撤销' } ]
	});
	rendered = await renderPage(harness, conflictStatus, conflictRestore);
	const conflictText = nodeText(rendered.body);
	assert.ok(conflictText.includes('external dhcp.lan changes'), 'conflict evidence must be visible');
	/* Fixed (F5): the undo entry no longer appears mid-conflict; the network
	 * must converge via init-recover first, matching the backend guard. */
	assert.strictEqual(button(rendered.body, 'restore-recover'), null,
		'the declaration undo must not be offered while the network transaction is in conflict');
	assert.ok(conflictText.includes('请先恢复网络事务让其收敛'),
		'the conflict panel must explain the network-first ordering in plain language');
	assert.ok(conflictText.includes('声明等待网络收敛'),
		'held declarations render a no-touch notice while the network is not quiescent');
	await confirmedClick(rendered, 'init-recover');
	await settle();
	assert.deepStrictEqual(harness.apiArgs('init_recover'), [ [] ]);
	assert.strictEqual(harness.apiArgs('restore_recover').length, 0,
		'conflict handling must not auto-trigger the declaration undo');
}

async function declarationPreparingCancelContract() {
	/* F5 supplement: frozen lifecycle:247 cancels a leftover 'preparing'
	 * declaration directly (nothing public was written); the UI must offer
	 * that explicit entry instead of assuming it is permanently running. */
	const preparing = Object.assign({}, RESTORE_IDLE, { candidate_pending: false, declaration_phase: 'preparing' });
	/* preparing + quiescent network (absent): explicit cancel entry. */
	let harness = createHarness({
		init_status: [ STATUS_ABSENT ], 'init_status#last': STATUS_ABSENT,
		restore_status: [ preparing ], 'restore_status#last': preparing,
		restore_recover: [ { ok: false, error: '统一写入门禁忙、owner 失效或已有 writer 未退出' } ]
	});
	let rendered = await renderPage(harness, STATUS_ABSENT, preparing);
	let cancel = button(rendered.body, 'restore-recover');
	assert.ok(cancel, 'a leftover preparing declaration must offer an explicit cancel entry');
	assert.ok(nodeText(rendered.body).includes('导入声明有未完成的准备'));
	assert.ok(nodeText(rendered.body).includes('取消残留的导入声明'));
	assert.ok(nodeText(rendered.body).includes('不会自行猜测'));
	await confirmedClick(rendered, cancel);
	await settle();
	assert.ok(nodeText(rendered.page.feedback).includes('统一写入门禁忙'),
		'a busy backend lock must surface as a persistent real error');
	assert.ok(!nodeText(rendered.page.feedback).includes('操作已受理'));

	/* preparing + rolled_back network: cancel succeeds and re-reads both statuses. */
	const rolled = { ok: true, phase: 'rolled_back' };
	const cancelled = Object.assign({}, RESTORE_IDLE, { candidate_pending: false, declaration_phase: 'rolled_back' });
	harness = createHarness({
		init_status: [ rolled, rolled ], 'init_status#last': rolled,
		restore_status: [ preparing, cancelled ],
		'restore_status#last': cancelled,
		restore_recover: [ { ok: true, message: '准备阶段未修改公共声明，已取消候选' } ]
	});
	rendered = await renderPage(harness, rolled, preparing);
	await confirmedClick(rendered, 'restore-recover');
	await settle();
	assert.ok(nodeText(rendered.page.feedback).includes('准备阶段未修改公共声明，已取消候选'));
	assert.ok(harness.apiCalls().filter(function(m) { return m === 'init_status'; }).length >= 2,
		'cancel must re-read the real init status');
	assert.ok(harness.apiCalls().filter(function(m) { return m === 'restore_status'; }).length >= 2,
		'cancel must re-read the real declaration status');
	assert.strictEqual(button(rendered.body, 'restore-recover'), null,
		'the cancel entry must disappear once the leftover is cancelled');

	/* preparing while the network is live: cautious no-touch notice only. */
	harness = createHarness({
		init_status: [ STATUS_APPLYING ], 'init_status#last': STATUS_APPLYING,
		restore_status: [ preparing ], 'restore_status#last': preparing
	});
	rendered = await renderPage(harness, STATUS_APPLYING, preparing);
	assert.strictEqual(button(rendered.body, 'restore-recover'), null,
		'no declaration action while the network transaction is live');
	assert.ok(nodeText(rendered.body).includes('声明等待网络收敛'));
}

async function restoreRecoverQuiescentContract() {
	/* Fixed (F5): after a failed/expired transaction rolls back (phase
	 * rolled_back) with the declaration still installed, the backend blocks
	 * new prepare/exit/restore until an explicit restore_recover. */
	const rolled = { ok: true, phase: 'rolled_back' };
	const installed = Object.assign({}, RESTORE_IDLE, { candidate_pending: false, declaration_phase: 'installed' });
	let harness = createHarness({
		init_status: [ rolled ], 'init_status#last': rolled,
		restore_status: [ installed ],
		'restore_status#last': installed,
		restore_recover: [ { ok: false, error: '声明存在外部修改，未覆盖: routepolicy' } ]
	});
	let rendered = await renderPage(harness, rolled, installed);
	const undo = button(rendered.body, 'restore-recover');
	assert.ok(undo, 'a quiescent rolled_back state with an installed declaration must offer the explicit undo entry');
	assert.ok(nodeText(rendered.body).includes('导入的恢复声明待处理'));
	await confirmedClick(rendered, undo);
	await settle();
	assert.deepStrictEqual(harness.apiArgs('restore_recover'), [ [] ]);
	assert.ok(nodeText(rendered.page.feedback).includes('声明存在外部修改，未覆盖: routepolicy'),
		'a rejected undo must surface the real backend error persistently');
	assert.ok(!nodeText(rendered.page.feedback).includes('操作已受理'),
		'an error reply must never be painted green');

	const recovered = Object.assign({}, RESTORE_IDLE, { candidate_pending: false, declaration_phase: 'rolled_back' });
	harness = createHarness({
		init_status: [ rolled, rolled ], 'init_status#last': rolled,
		restore_status: [ installed, recovered ],
		'restore_status#last': recovered,
		restore_recover: [ { ok: true, message: '应用声明已逐文件恢复；未覆盖外部值' } ]
	});
	rendered = await renderPage(harness, rolled, installed);
	await confirmedClick(rendered, 'restore-recover');
	await settle();
	assert.ok(harness.apiCalls().filter(function(m) { return m === 'init_status'; }).length >= 2,
		'a successful undo must re-read the real init status');
	assert.ok(harness.apiCalls().filter(function(m) { return m === 'restore_status'; }).length >= 2,
		'a successful undo must re-read the real declaration status');
	assert.strictEqual(button(rendered.body, 'restore-recover'), null,
		'the undo entry must disappear once the declaration is rolled back');
}

async function restoreMappingBlockedContract() {
	const rolled = { ok: true, phase: 'rolled_back', token: TOKEN };
	const installed = Object.assign({}, RESTORE_IDLE, { candidate_pending: true, declaration_phase: 'installed' });
	const harness = createHarness({ init_status: [ rolled ], 'init_status#last': rolled, 'restore_status#last': installed });
	const rendered = await renderPage(harness, rolled, installed);
	await button(rendered.body, 'open-restore').click();
	await settle();
	assert.ok(nodeText(rendered.body).includes('撤销已导入的声明，再准备恢复候选'));
	assert.strictEqual(button(rendered.body, 'restore-prepare'), null, 'an installed declaration must first be undone after network rollback');
	assert.deepStrictEqual(harness.apiArgs('restore_prepare'), []);
	assert.deepStrictEqual(harness.apiArgs('restore_recover'), [], 'rendering the guidance must stay read-only');
	await button(rendered.body, 'back-overview-restore').click();
	assert.ok(button(rendered.body, 'restore-recover'), 'the overview contains the explicit undo entry');
}

async function confirmationFinishContract() {
	const errored = { ok: true, phase: 'confirmed', token: TOKEN, confirmation_error: 'watcher 启动失败' };
	let harness = createHarness({
		init_status: [ errored ], 'init_status#last': errored,
		restore_status: [ RESTORE_IDLE ],
		init_finish: [ { ok: false, error: '收尾恢复被后端拒绝' } ]
	});
	let rendered = await renderPage(harness, errored, RESTORE_IDLE);
	const finish = button(rendered.body, 'confirm-finish');
	assert.ok(finish, 'confirmed + confirmation_error must offer the finishing action');
	assert.ok(nodeText(rendered.body).includes('确认收尾未完成'));
	assert.ok(nodeText(rendered.body).includes('不会自动回滚'));
	assert.strictEqual(button(rendered.body, 'http-confirm'), null,
		'a finished confirmation must never grow a pending confirm button');
	await confirmedClick(rendered, finish);
	await settle();
	assert.deepStrictEqual(harness.apiArgs('init_finish'), [ [ TOKEN ] ]);
	assert.strictEqual(harness.apiArgs('init_recover').length, 0);
	assert.ok(nodeText(rendered.page.feedback).includes('收尾恢复被后端拒绝'),
		'a rejected finishing action must stay visible as a persistent error');
	assert.ok(!nodeText(rendered.page.feedback).includes('操作已受理'));

	const healthy = STATUS_CONFIRMED;
	harness = createHarness({
		init_status: [ errored, healthy ], 'init_status#last': healthy,
		restore_status: [ RESTORE_IDLE, RESTORE_IDLE ],
		init_finish: [ healthy ]
	});
	rendered = await renderPage(harness, errored, RESTORE_IDLE);
	await confirmedClick(rendered, 'confirm-finish');
	await settle();
	assert.ok(nodeText(rendered.page.feedback).includes('确认收尾已完成'));
	const afterText = nodeText(rendered.body);
	assert.ok(afterText.includes('生效与健康检查'), 'a successful finish must reveal the real health panel');
	assert.ok(!afterText.includes('确认收尾未完成'), 'the stale error panel must clear after real recovery');
	assert.strictEqual(button(rendered.body, 'confirm-finish'), null);
}

async function freshRenderPollingContract() {
	/* Fixed (F3): a fresh render must resume polling for live phases and
	 * for prepared+job.running, and must stay silent for terminal phases. */
	const live = [
		STATUS_APPLYING,
		STATUS_PENDING_READY,
		STATUS_CONFIRMING,
		{ ok: true, phase: 'rolling_back' },
		{ ok: true, phase: 'prepared', job: { kind: 'init', token: TOKEN, state: 'running' } }
	];
	for (const status of live) {
		const harness = createHarness({
			init_status: [ status ], 'init_status#last': status,
			restore_status: [ RESTORE_IDLE ]
		});
		await renderPage(harness, status, RESTORE_IDLE);
		assert.ok(activeTimer(harness),
			'a fresh render must resume polling for phase ' + status.phase + (status.job ? ' + job.running' : ''));
		for (const method of harness.apiCalls())
			assert.ok(method === 'init_status' || method === 'restore_status',
				'polling must stay read-only, got ' + method);
		assert.deepStrictEqual(harness.uciLog, [ [ 'load', 'routepolicy' ] ]);
	}
	const terminal = [
		STATUS_ABSENT,
		STATUS_CONFIRMED,
		{ ok: true, phase: 'rolled_back' },
		{ ok: true, phase: 'exited' },
		{ ok: true, phase: 'conflict', conflicts: 'x' }
	];
	for (const status of terminal) {
		const harness = createHarness({
			init_status: [ status ], 'init_status#last': status,
			restore_status: [ RESTORE_IDLE ]
		});
		await renderPage(harness, status, RESTORE_IDLE);
		assert.strictEqual(activeTimer(harness), null,
			'a fresh render must not poll a terminal phase ' + status.phase);
	}
}

async function overviewRefreshPollingContract() {
	const rolled = { ok: true, phase: 'rolled_back', token: TOKEN };
	let settlePoll;
	const delayedPoll = new Promise(function(resolve) { settlePoll = resolve; });
	let harness = createHarness({
		init_status: [ STATUS_ABSENT, STATUS_PENDING_READY, delayedPoll ],
		'restore_status#last': RESTORE_IDLE
	});
	let rendered = await renderPage(harness);
	assert.strictEqual(activeTimer(harness), null);
	await button(rendered.body, 'refresh-status').click();
	assert.ok(button(rendered.body, 'http-confirm'));
	await runPoll(harness);
	const manual = button(rendered.body, 'refresh-status').click();
	assert.strictEqual(harness.apiArgs('init_status').length, 3, 'manual refresh must share the in-flight poll');
	settlePoll(rolled);
	await manual;
	assert.ok(nodeText(rendered.body).includes('已回滚'));
	assert.strictEqual(button(rendered.body, 'http-confirm'), null);
	assert.strictEqual(activeTimer(harness), null);
	assert.deepStrictEqual(harness.apiCalls(), [ 'init_status', 'restore_status', 'init_status', 'restore_status', 'init_status', 'restore_status' ]);

	let finishOldRead;
	const oldRead = new Promise(function(resolve) { finishOldRead = resolve; });
	harness = createHarness({
		init_status: [ STATUS_ABSENT, oldRead, STATUS_PENDING_READY, rolled ],
		'restore_status#last': RESTORE_IDLE,
		init_discover: [ DISCOVER ]
	});
	rendered = await renderPage(harness);
	const oldRefresh = button(rendered.body, 'refresh-status').click();
	await button(rendered.body, 'open-init').click();
	await settle();
	assert.ok(nodeText(rendered.body).includes('设备与接口自检'));
	assert.strictEqual(activeTimer(harness), null);
	await button(rendered.body, 'back-overview-init').click();
	await settle();
	assert.ok(button(rendered.body, 'http-confirm'), 'returning from the form must read the pending status');
	finishOldRead(rolled);
	await oldRefresh;
	assert.ok(button(rendered.body, 'http-confirm'), 'a reply from the previous overview must not overwrite this one');
	assert.strictEqual(harness.timers.filter(function(timer) { return !timer.cancelled; }).length, 1,
		'the current overview has exactly one poll timer');
	await runPoll(harness);
	assert.ok(nodeText(rendered.body).includes('已回滚'));
	assert.strictEqual(activeTimer(harness), null);
	assert.strictEqual(harness.posts.length, 0);
	assert.deepStrictEqual(harness.uciLog, [ [ 'load', 'routepolicy' ] ]);
}

async function reconnectUrlContract() {
	/* Fixed (F4): the re-login entry keeps the CURRENT scheme and port
	 * (http/https only) instead of hardcoding https and dropping ports. */
	const cases = [
		[ 'http:', '8080', 'http://192.0.2.9:8080/admin/services/routepolicy/wizard' ],
		[ 'http:', '', 'http://192.0.2.9/admin/services/routepolicy/wizard' ],
		[ 'http:', '80', 'http://192.0.2.9/admin/services/routepolicy/wizard' ],
		[ 'https:', '', 'https://192.0.2.9/admin/services/routepolicy/wizard' ],
		[ 'https:', '443', 'https://192.0.2.9/admin/services/routepolicy/wizard' ]
	];
	for (const scenario of cases) {
		const status = Object.assign({}, STATUS_PENDING_READY);
		const harness = createHarness({
			init_status: [ status ], 'init_status#last': status,
			restore_status: [ RESTORE_IDLE ]
		});
		harness.window.location = { protocol: scenario[0], port: scenario[1], href: '' };
		const rendered = await renderPage(harness, status, RESTORE_IDLE);
		const link = findAll(rendered.body, function(node) {
			return node.tagName === 'a' && String(node.getAttribute('href') || '').indexOf('://192.0.2.9') > 0;
		})[0];
		assert.ok(link, 'a reconnect link must render for ' + scenario[0] + ':' + scenario[1]);
		assert.strictEqual(link.getAttribute('href'), scenario[2]);
		assert.ok(nodeText(rendered.body).includes('192.0.2.9'),
			'the candidate address must stay visible as plain copyable text');
	}
}

async function restoreFlowContract() {
	const offline = { __reject: 'old address disconnected' };
	const installed = Object.assign({}, RESTORE_IDLE, { declaration_phase: 'installed', init_token: TOKEN });
	const harness = createHarness({
		init_status: [ STATUS_ABSENT, STATUS_ABSENT, offline, STATUS_PENDING_READY ],
		restore_status: [ RESTORE_IDLE, RESTORE_IDLE, Object.assign({}, RESTORE_IDLE, {
			candidate_pending: true, declaration_phase: 'prepared', unportable_fields: 'smartdns.forward smartdns.extra'
		}), offline, installed ],
		init_discover: [ DISCOVER ],
		config_import: [ { ok: true, schema: 1, candidate_pending: true } ],
		restore_prepare: [ PREPARED ],
		init_apply: [ { __reject: 'restore apply reply lost' } ]
	});
	const rendered = await renderPage(harness, STATUS_ABSENT, RESTORE_IDLE);
	await button(rendered.body, 'open-restore').click();
	await settle();
	const importText = findAll(rendered.body, function(node) { return node.tagName === 'textarea' && node.getAttribute('id') === 'routepolicy-restore-import'; })[0];
	importText.value = 'routepolicy-config\t1\nsensitive\t1\nmain\tenabled\t0\n';
	const canceled = button(rendered.body, 'config-import').click();
	assert.deepStrictEqual(harness.apiArgs('config_import'), []);
	button(rendered.root, 'confirmation-cancel').click();
	await canceled;
	assert.ok(importText.value.includes('routepolicy-config'));
	await confirmedClick(rendered, 'config-import');
	await settle();
	assert.deepStrictEqual(harness.apiArgs('config_import'), [ [ 'routepolicy-config\t1\nsensitive\t1\nmain\tenabled\t0\n' ] ]);
	const mappingText = nodeText(rendered.body);
	for (const expected of [ 'smartdns.forward', 'smartdns.extra', '准备恢复候选（危险确认）', '危险确认' ])
		assert.ok(mappingText.includes(expected), 'restore mapping must show ' + expected);

	const page = rendered.page;
	page.form.accessSelect.value = 'lan';
	page.form.defaultSelect.value = 'wan';
	page.form.policySelect.value = 'usbwan';

	/* Both confirmations are required before restore_prepare. */
	await button(rendered.body, 'restore-prepare').click();
	await settle();
	assert.strictEqual(harness.apiArgs('restore_prepare').length, 0);
	findAll(rendered.body, function(node) { return node.getAttribute('id') === 'routepolicy-restore-danger-ack'; })[0].checked = true;
	await button(rendered.body, 'restore-prepare').click();
	await settle();
	assert.strictEqual(harness.apiArgs('restore_prepare').length, 0, 'the unportable confirmation is also mandatory');
	findAll(rendered.body, function(node) { return node.getAttribute('id') === 'routepolicy-restore-unportable-ack'; })[0].checked = true;
	await button(rendered.body, 'restore-prepare').click();
	await settle();
	assert.deepStrictEqual(harness.apiArgs('restore_prepare'),
		[ [ 'lan\twan\tusbwan\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t1\t1' ] ],
		'restore_prepare must append both confirmations to the 13-field mapping');
	assert.ok(nodeText(rendered.body).includes('候选已准备'));
	assert.strictEqual(harness.apiArgs('config_export').length, 0, 'export must only run on explicit request');
	findAll(rendered.body, function(node) { return node.getAttribute('id') === 'routepolicy-apply-ack'; })[0].checked = true;
	await confirmedClick(rendered, 'do-apply');
	assert.ok(nodeText(rendered.body).includes('刚审阅的候选管理地址'));
	assert.strictEqual(button(rendered.body, 'http-confirm'), null);
	await runPoll(harness);
	assert.ok(button(rendered.body, 'http-confirm'));
	assert.strictEqual(button(rendered.body, 'restore-recover'), null);
	assert.deepStrictEqual(harness.apiArgs('init_apply'), [ [ TOKEN ] ]);
}

function assertPreparedExitView(body) {
	const text = nodeText(body);
	for (const expected of [ '退出候选已准备', '退出将恢复的服务状态', 'smartdns', '0（禁用自启）', '1（运行中）',
		'管理地址可能变化', '执行退出（危险确认）' ])
		assert.ok(text.includes(expected), 'prepared exit must show ' + expected);
	for (const unexpected of [ '确认超时窗口', '候选管理地址', '候选关键项', '没有证据' ])
		assert.ok(!text.includes(unexpected), 'prepared exit must omit initialization guidance: ' + unexpected);
	const dnsPort = findAll(body, node => node.getAttribute('data-key') === 'dhcp.@dnsmasq[0].port')[0];
	assert.deepStrictEqual(dnsPort.children.map(nodeText), [ 'dhcp.@dnsmasq[0].port', 'set', '0', '53' ],
		'prepared exit must retain the real baseline-to-restored DNS port change');
}

async function exitFlowContract() {
	const harness = createHarness({
		init_status: [ STATUS_CONFIRMED, STATUS_CONFIRMED, { ok: true, phase: 'rolling_back' }, { ok: true, phase: 'exited' } ],
		restore_status: [ RESTORE_IDLE ],
		exit_preview: [ {
			ok: true, state: 'ready', conflicts: '', routing_will_stop: true,
			management_may_change: true, confirmation_required: true, warning: 'use out-of-band console'
		} ],
		exit_prepare: [ EXIT_PREPARED ],
		exit_apply: [ { ok: true } ]
	});
	const rendered = await renderPage(harness, { ok: true, phase: 'confirmed' }, RESTORE_IDLE);
	await button(rendered.body, 'open-exit').click();
	await settle();
	const exitIntro = nodeText(rendered.body);
	for (const expected of [ '退出接管', '停用并清理', '卸载' ])
		assert.ok(exitIntro.includes(expected), 'exit page must distinguish exit from disable and uninstall: ' + expected);
	await button(rendered.body, 'exit-preview').click();
	await settle();
	const previewText = nodeText(rendered.body);
	for (const expected of [ '就绪', '分流将停止', '管理地址可能变化' ])
		assert.ok(previewText.includes(expected), 'exit preview must show ' + expected);
	await button(rendered.body, 'exit-prepare').click();
	await settle();
	assertPreparedExitView(rendered.body);
	await button(rendered.body, 'do-apply').click();
	assert.deepStrictEqual(harness.apiArgs('exit_apply'), [], 'exit must wait for the acknowledgement');
	const applyAck = findAll(rendered.body, function(node) { return node.getAttribute('id') === 'routepolicy-apply-ack'; })[0];
	applyAck.checked = true;
	await confirmedClick(rendered, 'do-apply');
	await settle();
	assert.deepStrictEqual(harness.apiArgs('exit_apply'), [ [ EXIT_TOKEN ] ]);
	assert.strictEqual(harness.apiArgs('init_apply').length, 0, 'exit must never trigger an init apply');
	assert.ok(nodeText(rendered.body).includes('回滚中'), 'the immediate poll after exit must show the rolling-back phase');
	await runPoll(harness);
	assert.ok(nodeText(rendered.body).includes('已退出'));
}

async function exitBlockedContract() {
	const harness = createHarness({
		init_status: [ { ok: true, phase: 'confirmed' } ],
		restore_status: [ RESTORE_IDLE ],
		exit_preview: [ { ok: false, error: '没有可验证的已确认旁路由接管' } ]
	});
	const rendered = await renderPage(harness, { ok: true, phase: 'confirmed' }, RESTORE_IDLE);
	await button(rendered.body, 'open-exit').click();
	await settle();
	await button(rendered.body, 'exit-preview').click();
	await settle();
	const text = nodeText(rendered.body);
	assert.ok(text.includes('没有可验证的已确认旁路由接管'), 'a blocked exit preview must surface the backend error');
	assert.strictEqual(button(rendered.body, 'exit-prepare'), null, 'no exit prepare button while blocked');
}

async function exitCandidateRefreshContract() {
	const harness = createHarness({
		init_status: [ Object.assign({ exit_candidate_available: true }, { ok: true, phase: 'confirmed' }) ],
		restore_status: [ RESTORE_IDLE ],
		exit_candidate: [ EXIT_PREPARED ]
	});
	const rendered = await renderPage(harness,
		Object.assign({ exit_candidate_available: true }, { ok: true, phase: 'confirmed' }), RESTORE_IDLE);
	const refresh = button(rendered.body, 'view-exit-candidate');
	assert.ok(refresh, 'an available exit candidate must offer a refresh entry instead of relying on browser memory');
	await refresh.click();
	await settle();
	assert.deepStrictEqual(harness.apiArgs('exit_candidate'), [ [] ]);
	assertPreparedExitView(rendered.body);
}

async function readOnlyAccountContract() {
	const harness = createHarness({
		init_status: [ STATUS_PENDING_READY ],
		'init_status#last': STATUS_PENDING_READY,
		restore_status: [ RESTORE_IDLE ]
	});
	harness.L.hasViewPermission = function() {
		/* Verified luci-base semantics: synchronous, no arguments,
		 * false = read-only permissions only. */
		return false;
	};
	const rendered = await renderPage(harness, STATUS_PENDING_READY, RESTORE_IDLE);
	await settle();
	const text = nodeText(rendered.body);
	assert.ok(text.includes('没有本页面的写权限'), 'a denied write permission must be explained');
	for (const action of [ 'open-init', 'open-restore', 'open-exit', 'http-confirm' ])
		assert.strictEqual(button(rendered.body, action).disabled, true, action + ' must be disabled without write permission');
	assert.strictEqual(button(rendered.body, 'refresh-status').disabled, false, 're-checking status stays available');
	for (const method of harness.apiCalls())
		assert.ok(method === 'init_status' || method === 'restore_status',
			'a read-only account must never trigger write-ACL calls during load, got ' + method);

	for (const scenario of [
		[ 'cancel-candidate', { ok: true, phase: 'prepared', token: TOKEN } ],
		[ 'confirm-finish', { ok: true, phase: 'confirmed', token: TOKEN, confirmation_error: 'watcher 启动失败' } ]
	]) {
		const readOnly = createHarness({ init_status: [ scenario[1] ], restore_status: [ RESTORE_IDLE ] });
		readOnly.L.hasViewPermission = function() { return false; };
		const view = await renderPage(readOnly);
		const action = button(view.body, scenario[0]);
		assert.ok(action && action.disabled);
		await action.click();
		assert.strictEqual(button(view.root, 'confirmation-accept'), null);
		assert.deepStrictEqual(readOnly.apiCalls(), [ 'init_status', 'restore_status' ]);
	}
}

async function plainTextRenderingContract() {
	const hostileStatus = {
		ok: true, phase: 'pending', token: 'c'.repeat(32),
		management_address: '<img src=x onerror=alert(1)>',
		remaining_seconds: 60, http_confirmation_ready: false,
		confirmation_transport: '<script>alert(2)</script>',
		conflicts: '<script>alert(3)</script>'
	};
	const hostileDiscover = JSON.parse(JSON.stringify(DISCOVER));
	hostileDiscover.netifd.interface.push({
		interface: '<b>evil</b>', up: true, l3_device: '<script>dev</script>', proto: 'static'
	});
	const harness = createHarness({
		init_status: [ hostileStatus, hostileStatus ],
		restore_status: [ RESTORE_IDLE ],
		init_discover: [ hostileDiscover ]
	});
	const rendered = await renderPage(harness, hostileStatus, RESTORE_IDLE);
	const text = nodeText(rendered.body);
	assert.ok(text.includes('<img src=x onerror=alert(1)>'), 'hostile values must render as literal text');
	assert.ok(text.includes('<script>alert(3)</script>'));
	await button(rendered.body, 'open-init').click();
	await settle();
	assert.ok(nodeText(rendered.body).includes('<b>evil</b>'), 'hostile interface names must stay plain text');
	const eventAttributes = findAll(rendered.root, hasEventAttribute);
	assert.deepStrictEqual(eventAttributes, [], 'no inline event handlers may be attached from data');
}

async function rulesAndSourcesContract() {
	const harness = createHarness({
		init_status: [ STATUS_ABSENT ],
		restore_status: [ RESTORE_IDLE ],
		init_discover: [ DISCOVER ],
		read_user_list: [ { ok: true, content: 'example.com\n' }, { ok: true, content: '' } ],
		write_user_list: [ { ok: true, message: '已保存', valid_count: 1, duplicate_count: 0, invalid_count: 0, invalid: [] } ]
	});
	harness.setUciSections([ {
		'.name': 'cfg08a1', '.type': 'source', name: 'blocklist', url: 'https://example.invalid/list',
		format: 'plain-domain', target: 'domain-policy', enabled: '1'
	}, {
		'.name': 'rp_src_disabled', '.type': 'source', name: 'disabled-list', enabled: '0'
	}, {
		'.name': 'rp_src_legacy', '.type': 'source', name: 'legacy-list'
	} ]);
	const rendered = await renderPage(harness, STATUS_ABSENT, RESTORE_IDLE);
	await button(rendered.body, 'open-init').click();
	await settle();
	const flowText = nodeText(rendered.body);
	for (const expected of [ 'blocklist', 'https://example.invalid/list', '准备候选', '之前完成' ])
		assert.ok(flowText.includes(expected), 'the wizard flow must embed existing sources: ' + expected);
	const sourceTable = findAll(rendered.body, node => node.getAttribute('id') === 'routepolicy-wizard-sources')[0];
	assert.deepStrictEqual(sourceTable.children.slice(1).map(row => [ nodeText(row.children[0]), nodeText(row.children[4]) ]),
		[ [ 'blocklist', '是' ], [ 'disabled-list', '否' ], [ 'legacy-list', '否' ] ],
		'only a source with explicit enabled=1 may display as enabled');
	const rules = findAll(rendered.body, function(node) { return node.getAttribute('id') === 'routepolicy-wizard-rules'; })[0];
	assert.strictEqual(rules.value, 'example.com\n', 'the real user list must load into the wizard editor');
	await button(rendered.body, 'save-rules').click();
	await settle();
	assert.deepStrictEqual(harness.apiArgs('write_user_list'), [ [ { list: 'domain-policy', content: 'example.com\n' } ] ]);
	await button(rendered.body, 'add-source').click();
	await button(rendered.body, 'save-sources').click();
	await settle();
	const uciActions = harness.uciLog.map(function(entry) { return entry[0]; });
	assert.ok(uciActions.includes('add') && uciActions.includes('set'), 'adding a source must stage UCI through the restricted routepolicy config');
	assert.deepStrictEqual(harness.uciLog.find(entry => entry[0] === 'add'), [ 'add', 'routepolicy', 'source', 'rp_src_0123456789abcdef01234567' ]);
	assert.deepStrictEqual(harness.uciLog.filter(entry => entry[0] === 'set' && entry[3] === 'enabled'),
		[ [ 'set', 'routepolicy', 'rp_src_0123456789abcdef01234567', 'enabled', '1' ] ],
		'only adding a source explicitly enables it; rendering and saving existing sources must leave their flags alone');
	assert.ok(uciActions.includes('save') && uciActions.includes('apply'), 'sources must be committed explicitly before prepare');
	assert.ok(uciActions.indexOf('save') < uciActions.indexOf('name-anonymous') && uciActions.indexOf('name-anonymous') < uciActions.indexOf('apply'),
		'old anonymous sources must be renamed after staging edits and before applying');
	/* Fixed (F1): the real uci.unload() is synchronous and returns nothing;
	 * saving must still complete the cache reload after apply. */
	assert.ok(uciActions.indexOf('apply') < uciActions.indexOf('unload') &&
		uciActions.indexOf('unload') < uciActions.indexOf('load', uciActions.indexOf('unload')),
		'saving sources must run apply → unload → reload in order');
	assert.ok(nodeText(rendered.body).includes('清单来源已提交'),
		'the synchronous unload must not break the save flow (regression for F1)');

	const draft = findAll(rendered.body, node => node.getAttribute('placeholder') === 'https://…')[0];
	draft.value = 'https://example.invalid/unsaved';
	let rejectMigration;
	const failure = new Promise(function(resolve, reject) { rejectMigration = reject; });
	harness.api.nameAnonymousSources = () => failure;
	harness.uciLog.length = 0;
	const saving = button(rendered.body, 'save-sources').click();
	assert.strictEqual(button(rendered.body, 'add-source').disabled, true);
	assert.strictEqual(button(rendered.body, 'make-preview').disabled, true);
	assert.strictEqual(button(rendered.body, 'back-overview-init').disabled, true);
	await settle();
	rejectMigration(new Error('rename denied'));
	await saving;
	assert.ok(nodeText(rendered.body).includes('rename denied'), 'the wizard must surface the actual migration failure');
	assert.strictEqual(draft.value, 'https://example.invalid/unsaved', 'a migration error must retain the source draft');
	assert.deepStrictEqual(harness.uciLog, [ [ 'save' ] ], 'no apply occurs after a rename error');
	assert.strictEqual(button(rendered.body, 'back-overview-init').disabled, false);
}

async function ruleEditorOrderingContract() {
	let finishOldList, finishSave, rejectSave, finishPreview, finishOldScreen;
	const oldList = new Promise(function(resolve) { finishOldList = resolve; });
	const saving = new Promise(function(resolve) { finishSave = resolve; });
	const rejectedSave = new Promise(function(resolve) { rejectSave = resolve; });
	const pendingPreview = new Promise(function(resolve) { finishPreview = resolve; });
	const oldScreen = new Promise(function(resolve) { finishOldScreen = resolve; });
	const harness = createHarness({
		'init_status#last': STATUS_ABSENT, 'restore_status#last': RESTORE_IDLE, 'init_discover#last': DISCOVER,
		read_user_list: [
			{ ok: true, content: 'policy-original.lab.test' }, oldList, { ok: true, content: 'policy-current.lab.test' },
			{ ok: false, error: '读取默认规则失败' }, { ok: true, content: '' }, oldScreen,
			{ ok: true, content: 'new-form.lab.test' }
		],
		write_user_list: [ saving, rejectedSave ],
		init_preview: [ pendingPreview ]
	});
	const rendered = await renderPage(harness);
	const body = rendered.body;
	const editor = function() { return findAll(body, function(node) { return node.getAttribute('id') === 'routepolicy-wizard-rules'; })[0]; };
	await button(body, 'open-init').click();
	await settle();
	const select = findAll(body, function(node) {
		return node.tagName === 'select' && node.children.some(function(option) { return option.value === 'domain-default'; });
	})[0];
	const change = function(kind) {
		select.value = kind;
		return select.listeners.change();
	};
	const save = button(body, 'save-rules');
	const waiting = change('domain-default');
	assert.ok(editor().disabled && save.disabled);
	assert.ok(nodeText(body).includes('正在读取所选规则'));
	await save.click();
	assert.deepStrictEqual(harness.apiArgs('write_user_list'), [], 'save cannot send an old or empty buffer while loading');
	await change('domain-policy');
	assert.strictEqual(editor().value, 'policy-current.lab.test');
	assert.ok(!editor().disabled && !save.disabled);
	editor().value = 'edited-policy.lab.test';
	finishOldList({ ok: true, content: 'wrong-default.lab.test' });
	await waiting;
	assert.strictEqual(editor().value, 'edited-policy.lab.test', 'a late list reply must preserve current edits');
	const saveRequest = save.click();
	assert.ok(select.disabled && editor().disabled && save.disabled);
	await change('domain-default');
	assert.strictEqual(select.value, 'domain-policy');
	assert.strictEqual(harness.apiArgs('read_user_list').length, 3);
	finishSave({ ok: true });
	await saveRequest;
	assert.deepStrictEqual(harness.apiArgs('write_user_list'), [ [ { list: 'domain-policy', content: 'edited-policy.lab.test' } ] ]);
	await change('domain-default');
	assert.ok(nodeText(body).includes('读取默认规则失败'));
	assert.ok(editor().disabled && save.disabled, 'a rejected read must not become an empty editable list');
	await save.click();
	assert.strictEqual(harness.apiArgs('write_user_list').length, 1);
	await button(body, 'retry-rules').click();
	assert.strictEqual(editor().value, '');
	assert.ok(!editor().disabled && !save.disabled, 'a successfully read empty list remains editable');

	editor().value = 'unsaved-default.lab.test';
	const form = rendered.page.form;
	form.accessSelect.value = 'lan';
	form.defaultSelect.value = 'wan';
	form.policySelect.value = 'usbwan';
	const preview = button(body, 'make-preview');
	const back = button(body, 'back-overview-init');
	const pendingWrite = save.click();
	assert.ok(preview.disabled && back.disabled);
	assert.ok(nodeText(body).includes('正在保存规则'));
	await back.click();
	await preview.click();
	assert.strictEqual(rendered.page.current, 'init-form');
	assert.deepStrictEqual(harness.apiArgs('init_preview'), []);
	assert.strictEqual(harness.apiArgs('init_status').length, 1, 'returning to the overview is blocked while saving');
	rejectSave({ ok: false, error: '写入门禁忙' });
	await pendingWrite;
	assert.ok(nodeText(body).includes('写入门禁忙'));
	assert.strictEqual(editor().value, 'unsaved-default.lab.test', 'a rejected write preserves the draft');
	assert.ok(!preview.disabled && !back.disabled);
	const previewRequest = preview.click();
	await save.click();
	assert.strictEqual(harness.apiArgs('write_user_list').length, 2, 'a preview already in flight cannot overlap a rule save');
	finishPreview({ ok: false, error: '预览被拒绝' });
	await previewRequest;
	assert.strictEqual(editor().value, 'unsaved-default.lab.test');
	const discard = change('domain-policy');
	assert.ok(nodeText(rendered.page.confirmation).includes('未保存的修改'));
	button(rendered.root, 'confirmation-cancel').click();
	await discard;
	assert.strictEqual(select.value, 'domain-default');
	assert.strictEqual(editor().value, 'unsaved-default.lab.test');
	assert.strictEqual(harness.apiArgs('read_user_list').length, 5, 'declining discard does not change the list');
	const detached = acceptConfirmation(rendered, change('domain-policy'));
	await settle();
	await button(body, 'back-overview-init').click();
	await settle();
	await button(body, 'open-init').click();
	await settle();
	finishOldScreen({ ok: false, error: '上一屏读取失败' });
	await detached;
	assert.strictEqual(editor().value, 'new-form.lab.test');
	assert.ok(!nodeText(body).includes('上一屏读取失败'));
}

async function openPrepareForm(rendered, kind) {
	const body = rendered.body;
	await button(body, 'open-' + kind).click();
	await settle();
	if (kind === 'exit') {
		await button(body, 'exit-preview').click();
	} else {
		rendered.page.form.defaultSelect.value = 'wan';
		rendered.page.form.policySelect.value = 'usbwan';
		if (kind === 'init') {
			await button(body, 'make-preview').click();
			findAll(body, function(node) { return node.getAttribute('id') === 'routepolicy-preview-ack'; })[0].checked = true;
		} else {
			findAll(body, function(node) { return node.getAttribute('id') === 'routepolicy-restore-import'; })[0].value = 'replacement declaration';
			findAll(body, function(node) { return node.getAttribute('id') === 'routepolicy-restore-danger-ack'; })[0].checked = true;
		}
	}
	return button(body, kind === 'init' ? 'do-prepare' : kind + '-prepare');
}

async function prepareScreenOwnershipContract() {
	const restore = Object.assign({}, RESTORE_IDLE, { candidate_pending: true, declaration_phase: 'prepared' });
	for (const kind of [ 'init', 'restore', 'exit' ]) {
		for (const success of [ true, false ]) {
			let finishPrepare;
			const prepare = new Promise(function(resolve) { finishPrepare = resolve; });
			const method = kind + '_prepare';
			const harness = createHarness({
				'init_status#last': kind === 'exit' ? STATUS_CONFIRMED : STATUS_ABSENT,
				'restore_status#last': kind === 'restore' ? restore : RESTORE_IDLE,
				'init_discover#last': DISCOVER,
				'init_preview#last': PREVIEW, 'exit_preview#last': { ok: true, state: 'ready' },
				[method]: [ prepare ]
			});
			const rendered = await renderPage(harness);
			const body = rendered.body;
			const prepareButton = await openPrepareForm(rendered, kind);
			const back = button(body, kind === 'init' ? 'back-form' : 'back-overview-' + kind);
			const redraw = kind === 'restore' ? button(body, 'config-import') : kind === 'exit' ? button(body, 'exit-preview') : null;
			const screen = rendered.page.screen;
			const preparing = kind === 'init' ? confirmedClick(rendered, prepareButton) : prepareButton.click();
			await settle();
			assert.ok(back.disabled && prepareButton.disabled && (!redraw || redraw.disabled), kind + ' keeps its controls locked until reply');
			assert.ok(nodeText(rendered.page.feedback).includes('正在准备候选'));
			const calls = harness.apiCalls();
			await back.click();
			if (redraw)
				await redraw.click();
			await prepareButton.click();
			assert.strictEqual(rendered.page.screen, screen, kind + ' must preserve its pending screen');
			assert.deepStrictEqual(harness.apiCalls(), calls, kind + ' cannot start a read, import, preview or second preparation while pending');
			assert.strictEqual(harness.apiArgs(method).length, 1);
			const refusal = kind + ' 候选准备被拒绝';
			finishPrepare(success ? Object.assign({}, PREPARED, { token: kind === 'exit' ? EXIT_TOKEN : TOKEN }) : { ok: false, error: refusal });
			await preparing;
			if (success) {
				assert.strictEqual(rendered.page.current, 'prepared');
				assert.ok(button(body, 'do-apply'));
				assert.ok(button(body, 'back-overview-prepared') && !button(body, 'back-overview-prepared').disabled);
			} else {
				assert.strictEqual(rendered.page.screen, screen);
				assert.ok(nodeText(rendered.page.feedback).includes(refusal));
				assert.ok(!back.disabled && !prepareButton.disabled && (!redraw || !redraw.disabled));
				if (kind === 'restore')
					assert.strictEqual(rendered.page.form.policySelect.value, 'usbwan');
				await back.click();
				assert.strictEqual(rendered.page.current, kind === 'init' ? 'init-form' : 'overview');
			}
			assert.deepStrictEqual(harness.apiArgs('init_apply'), []);
			assert.deepStrictEqual(harness.apiArgs('exit_apply'), []);
		}
	}
}

async function prepareTransportContract() {
	const prepared = { ok: true, phase: 'prepared', token: TOKEN };
	const newToken = 'c'.repeat(32);
	const newer = Object.assign({}, prepared, { token: newToken });
	const newCandidate = Object.assign({}, PREPARED, { token: newToken });
	const restore = Object.assign({}, RESTORE_IDLE, { candidate_pending: true, declaration_phase: 'prepared' });
	const exitStatus = Object.assign({}, STATUS_CONFIRMED, { exit_candidate_available: true });
	for (const kind of [ 'init', 'restore', 'exit' ]) {
		const method = kind + '_prepare';
		const harness = createHarness({
			init_status: kind === 'init' ? [ STATUS_ABSENT, STATUS_ABSENT, STATUS_ABSENT, newer ] :
				kind === 'restore' ? [ prepared, prepared, prepared, newer, newer ] : [ exitStatus, exitStatus, exitStatus, exitStatus ],
			'restore_status#last': kind === 'restore' ? restore : RESTORE_IDLE,
			'init_discover#last': DISCOVER,
			'init_preview#last': PREVIEW, 'exit_preview#last': { ok: true, state: 'ready' },
			[method]: [ { __reject: 'XHR request timed out' } ],
			init_candidate: kind === 'restore' ? [ PREPARED, newCandidate ] : [ newCandidate ],
			'init_candidate#last': newCandidate,
			exit_candidate: [ { ok: true, token: EXIT_TOKEN }, { ok: true, token: EXIT_TOKEN }, newCandidate ],
			'exit_candidate#last': newCandidate
		});
		const rendered = await renderPage(harness);
		const body = rendered.body;
		const prepare = await openPrepareForm(rendered, kind);
		await (kind === 'init' ? confirmedClick(rendered, prepare) : prepare.click());
		const candidateAction = kind === 'exit' ? 'view-exit-candidate' : 'view-candidate';
		const assertWaiting = function() {
			assert.ok(nodeText(body).includes('准备请求结果待核实'));
			assert.ok(!nodeText(rendered.page.feedback).includes('操作失败'));
			assert.strictEqual(button(body, candidateAction), null);
			assert.ok(button(body, 'reload-page'));
		};
		assertWaiting();
		await runPoll(harness);
		if (kind === 'restore') {
			assertWaiting();
			await runPoll(harness);
		}
		assert.ok(nodeText(rendered.page.feedback).includes('设备报告了当前候选'));
		assert.ok(!nodeText(rendered.page.feedback).includes('XHR request timed out'));
		assert.ok(button(body, candidateAction));
		assert.strictEqual(button(body, 'do-apply'), null);
		await button(body, candidateAction).click();
		assert.ok(button(body, 'do-apply'), 'review is only opened by the user');
		assert.strictEqual(harness.apiArgs(method).length, 1);
		assert.deepStrictEqual(harness.apiArgs('init_apply'), []);
		assert.deepStrictEqual(harness.apiArgs('exit_apply'), []);
	}

	const harness = createHarness({
		init_status: [ STATUS_ABSENT, { __reject: 'baseline unavailable' } ], 'restore_status#last': RESTORE_IDLE,
		'init_discover#last': DISCOVER, 'init_preview#last': PREVIEW
	});
	const rendered = await renderPage(harness);
	await confirmedClick(rendered, await openPrepareForm(rendered, 'init'));
	assert.strictEqual(rendered.page.current, 'init-preview');
	assert.ok(nodeText(rendered.page.feedback).includes('尚未发送准备请求'));
	assert.deepStrictEqual(harness.apiArgs('init_prepare'), []);
}

async function restoreRemappingOwnershipContract() {
	let finishOldDiscover;
	const oldDiscover = new Promise(function(resolve) { finishOldDiscover = resolve; });
	const restore = Object.assign({}, RESTORE_IDLE, { candidate_pending: true, declaration_phase: 'prepared' });
	const harness = createHarness({
		'init_status#last': STATUS_ABSENT, 'restore_status#last': restore,
		init_discover: [ oldDiscover, DISCOVER ], config_import: [ { ok: true } ]
	});
	const rendered = await renderPage(harness);
	const body = rendered.body;
	await button(body, 'open-restore').click();
	await settle();
	const oldPrepare = button(body, 'restore-prepare');
	findAll(body, function(node) { return node.getAttribute('id') === 'routepolicy-restore-import'; })[0].value = 'replacement declaration';
	await confirmedClick(rendered, 'config-import');
	await settle();
	const currentForm = rendered.page.form;
	assert.ok(currentForm);
	finishOldDiscover({ ok: false });
	await settle();
	assert.strictEqual(rendered.page.form, currentForm, 'late device discovery must not replace a newer mapping');
	await oldPrepare.click();
	assert.deepStrictEqual(harness.apiArgs('restore_prepare'), []);
}

async function confirmationErrorContract() {
	/* A persistent confirmation error omits health entirely: no all-green. */
	const harness = createHarness({
		init_status: [ { ok: true, phase: 'confirmed', confirmation_error: '上一次确认来自错误地址' } ],
		restore_status: [ RESTORE_IDLE ]
	});
	const rendered = await renderPage(harness,
		{ ok: true, phase: 'confirmed', confirmation_error: '上一次确认来自错误地址' }, RESTORE_IDLE);
	const text = nodeText(rendered.body);
	assert.ok(text.includes('上一次确认来自错误地址'), 'a persistent confirmation error must stay visible');
	assert.ok(text.includes('后端尚未返回本次确认的健康检查数据'), 'omitted health must be stated explicitly');
	assert.ok(!text.includes('事务验收检查全部通过'), 'an omitted health block must never claim overall success');
	const harnessMissingSets = createHarness({
		init_status: [ { ok: true, phase: 'confirmed', health: {
			topology: { management_address: '192.0.2.9', default_egress: 'verified' },
			dns_queries: [ { group: 'g', transport: 'udp', rcode: 'NOERROR' } ],
			rules_loaded: true, policy_egress: 'verified'
		} } ],
		restore_status: [ RESTORE_IDLE ]
	});
	const renderedSets = await renderPage(harnessMissingSets,
		{ ok: true, phase: 'confirmed', health: {
			topology: { management_address: '192.0.2.9', default_egress: 'verified' },
			dns_queries: [ { group: 'g', transport: 'udp', rcode: 'NOERROR' } ],
			rules_loaded: true, policy_egress: 'verified'
		} }, RESTORE_IDLE);
	assert.ok(nodeText(renderedSets.body).includes('部分检查未通过'),
		'a missing sets_loaded must count as an incomplete health verdict');
}

async function restoreConfirmDualPollContract() {
	const installed = Object.assign({}, RESTORE_IDLE, { declaration_phase: 'installed', init_token: TOKEN });
	const committed = Object.assign({}, RESTORE_IDLE, { candidate_pending: true, declaration_phase: 'committed', init_token: TOKEN });
	const harness = createHarness({
		init_status: [ STATUS_PENDING_READY, STATUS_PENDING_READY, STATUS_CONFIRMING, STATUS_CONFIRMED, STATUS_CONFIRMED ],
		'init_status#last': STATUS_CONFIRMED,
		restore_status: [ installed, installed, installed, installed, committed ],
		'restore_status#last': committed
	});
	const rendered = await renderPage(harness, STATUS_PENDING_READY, installed);
	await runPoll(harness);
	/* While pending the network is live: no undo button, convergence notice. */
	assert.strictEqual(button(rendered.body, 'restore-recover'), null,
		'no declaration undo while the network transaction is pending');
	assert.ok(nodeText(rendered.body).includes('声明等待网络收敛'));
	assert.ok(button(rendered.body, 'http-confirm'), 'the pending confirm button must be available');
	await button(rendered.body, 'http-confirm').click();
	await settle();
	assert.ok(nodeText(rendered.body).includes('确认中'),
		'the post-confirm poll must advance to confirming');
	const restoreDuring = harness.apiCalls().filter(function(m) { return m === 'restore_status'; }).length;
	assert.ok(restoreDuring >= 3,
		'polling must refresh the declaration status automatically (got ' + restoreDuring + ' calls, no manual refresh)');
	await runPoll(harness);
	assert.ok(nodeText(rendered.body).includes('已生效'));
	assert.ok(harness.apiCalls().filter(function(m) { return m === 'restore_status'; }).length >= 4,
		'every poll must have refreshed both authoritative states');
	assert.strictEqual(button(rendered.body, 'restore-recover'), null,
		'a crossed confirmed/installed read must not offer undo');
	assert.ok(!nodeText(rendered.body).includes('撤销已导入的声明'));
	assert.ok(nodeText(rendered.body).includes('声明还没有报告完成'));
	assert.ok(activeTimer(harness), 'crossed reads must not stop polling');
	await runPoll(harness);
	assert.strictEqual(button(rendered.body, 'restore-recover'), null,
		'a committed declaration must drop the undo entry immediately after confirmation');
	assert.ok(!nodeText(rendered.body).includes('声明还没有报告完成'));
	assert.ok(nodeText(rendered.body).includes('设备保留了一份导入声明'));
	assert.ok(!nodeText(rendered.body).includes('等待接口映射'));
	assert.ok(!nodeText(rendered.body).includes('默认启用开关'));
	assert.strictEqual(activeTimer(harness), null, 'polling ends when both states converge');
	assert.ok(harness.apiCalls().every(function(method) { return method === 'init_status' || method === 'restore_status'; }),
		'reading across the commit point must never trigger writes');
	assert.strictEqual(harness.posts.length, 1, 'only the explicit click confirms over HTTP');
	/* Re-login at the same state must stay consistent. */
	const relogin = createHarness({
		init_status: [ STATUS_CONFIRMED ], 'init_status#last': STATUS_CONFIRMED,
		restore_status: [ committed ], 'restore_status#last': committed, init_discover: [ DISCOVER ]
	});
	const reRendered = await renderPage(relogin, STATUS_CONFIRMED, committed);
	assert.strictEqual(button(reRendered.body, 'restore-recover'), null,
		'a fresh login at confirmed+committed must not resurrect a stale undo entry');
	await button(reRendered.body, 'open-restore').click();
	await settle();
	assert.ok(nodeText(reRendered.body).includes('设备保留的导入声明'));
	assert.ok(!nodeText(reRendered.body).includes('等待映射'));
	assert.deepStrictEqual(relogin.apiArgs('restore_prepare'), [], 'the retained declaration remains read-only until a user prepares it');

	/* A new, unbound declaration can be interrupted alongside an older confirmation. */
	const unbound = Object.assign({}, installed, { init_token: '' });
	const interrupted = createHarness({ init_status: [ STATUS_CONFIRMED ], restore_status: [ unbound ] });
	const unboundView = await renderPage(interrupted);
	assert.ok(button(unboundView.body, 'restore-recover'), 'an independent interrupted import must still be recoverable');
	assert.strictEqual(activeTimer(interrupted), null);

	const mismatched = Object.assign({}, installed, { init_token: EXIT_TOKEN });
	const stale = createHarness({ init_status: [ STATUS_CONFIRMED ], restore_status: [ mismatched ] });
	const staleView = await renderPage(stale);
	assert.strictEqual(button(staleView.body, 'restore-recover'), null, 'a mismatched binding cannot authorize undo');
	assert.strictEqual(button(staleView.body, 'confirm-finish'), null, 'a mismatched binding cannot authorize finish');
	assert.ok(activeTimer(stale));
}

async function terminalCountdownGuidanceContract() {
	/* F2 residue: a terminal confirmed state must not show a rollback
	 * countdown, and confirmation_error guidance must match the real phase. */
	let harness = createHarness({
		init_status: [ { ok: true, phase: 'confirmed', token: TOKEN, remaining_seconds: 0, confirmation_error: 'watcher error' } ],
		restore_status: [ RESTORE_IDLE ]
	});
	let rendered = await renderPage(harness,
		{ ok: true, phase: 'confirmed', remaining_seconds: 0, confirmation_error: 'watcher error' }, RESTORE_IDLE);
	const text = nodeText(rendered.body);
	assert.ok(!text.includes('剩余确认时间'),
		'a terminal confirmed state must not render a confirmation countdown');
	assert.ok(!text.includes('窗口结束后后端自动回滚'),
		'terminal guidance must not promise an automatic rollback that will never come');
	assert.ok(text.includes('watcher error'), 'the persistent error itself stays visible');
	assert.ok(text.includes('完成确认收尾'), 'guidance must point at the real finishing entry');
	assert.ok(!text.includes('等待后端回滚'), 'the contradictory wait-for-rollback wording must be gone');
	assert.ok(button(rendered.body, 'confirm-finish'), 'the finishing entry must render');

	const rolled = { ok: true, phase: 'rolled_back', token: TOKEN, remaining_seconds: 0, confirmation_error: 'DNS 验证失败' };
	harness = createHarness({ init_status: [ rolled ], restore_status: [ RESTORE_IDLE ] });
	rendered = await renderPage(harness);
	const rolledText = nodeText(rendered.body);
	assert.ok(rolledText.includes('DNS 验证失败') && rolledText.includes('本次配置已回滚'));
	assert.ok(!rolledText.includes('重新确认') && !rolledText.includes('自动回滚') && !rolledText.includes('剩余确认时间'));
	assert.strictEqual(button(rendered.body, 'http-confirm'), null);
	assert.strictEqual(button(rendered.body, 'confirm-finish'), null);

	const pendingZero = Object.assign({}, STATUS_PENDING_READY, { remaining_seconds: 0 });
	harness = createHarness({ init_status: [ pendingZero ], 'init_status#last': pendingZero, restore_status: [ RESTORE_IDLE ] });
	rendered = await renderPage(harness, pendingZero, RESTORE_IDLE);
	const zeroText = nodeText(rendered.body);
	assert.ok(zeroText.includes('确认窗口') && zeroText.includes('已结束'),
		'an exhausted pending window must say so instead of counting down');
	assert.ok(zeroText.includes('请勿重复应用'));

	const pendingLive = Object.assign({}, STATUS_PENDING_READY, { remaining_seconds: 60 });
	harness = createHarness({ init_status: [ pendingLive ], 'init_status#last': pendingLive, restore_status: [ RESTORE_IDLE ] });
	rendered = await renderPage(harness, pendingLive, RESTORE_IDLE);
	assert.ok(nodeText(rendered.body).includes('剩余确认时间（秒）') && nodeText(rendered.body).includes('60'),
		'a live pending window still shows the backend-driven countdown');
}

async function preparedCancelOrderContract() {
	const prepared = { ok: true, phase: 'prepared', token: TOKEN };
	const expired = { ok: true, phase: 'expired', token: TOKEN, prepared_expired_reason: 'cancelled-unapplied' };
	const installed = Object.assign({}, RESTORE_IDLE, { candidate_pending: false, declaration_phase: 'installed' });
	const undone = Object.assign({}, RESTORE_IDLE, { candidate_pending: false, declaration_phase: 'rolled_back' });
	let harness = createHarness({
		init_status: [ prepared, expired, expired ], 'init_status#last': expired,
		restore_status: [ installed, installed, undone ], 'restore_status#last': undone,
		init_cancel: [ expired ],
		restore_recover: [ { ok: true, message: '应用声明已逐文件恢复' } ],
		init_discover: [ DISCOVER ]
	});
	let rendered = await renderPage(harness, prepared, installed);
	assert.ok(button(rendered.body, 'view-candidate'), 'the prepared candidate review entry must render');
	const cancel = button(rendered.body, 'cancel-candidate');
	assert.ok(cancel, 'a prepared candidate must offer an explicit manual cancel entry');
	assert.strictEqual(button(rendered.body, 'restore-recover'), null,
		'the declaration undo must not be offered before the candidate is cancelled');
	assert.ok(nodeText(rendered.body).includes('请先取消已准备的网络候选'),
		'the ordering guidance must be explicit');
	await confirmedClick(rendered, cancel);
	await settle();
	assert.deepStrictEqual(harness.apiArgs('init_cancel'), [ [ TOKEN ] ], 'cancelling targets the reviewed candidate');
	assert.strictEqual(harness.apiArgs('init_recover').length, 0, 'cancelling must not call general recovery');
	assert.strictEqual(harness.apiArgs('restore_recover').length, 0, 'cancelling must not automatically undo the declaration');
	assert.strictEqual(harness.apiArgs('init_apply').length, 0, 'cancelling must never auto-apply');
	const afterCancel = nodeText(rendered.body);
	assert.ok(afterCancel.includes('cancelled-unapplied') || afterCancel.includes('候选已过期'),
		'the real cancelled state must be reflected');
	const undo = button(rendered.body, 'restore-recover');
	assert.ok(undo, 'after cancelling the candidate the declaration undo must appear');
	await confirmedClick(rendered, undo);
	await settle();
	assert.deepStrictEqual(harness.apiArgs('restore_recover'), [ [] ]);
	assert.strictEqual(button(rendered.body, 'restore-recover'), null,
		'the undo entry must disappear once the declaration is rolled back');
	const start = button(rendered.body, 'open-init');
	assert.ok(start && !start.disabled, 'after cancelling both layers a new first-time flow must be startable');
	await start.click();
	await settle();
	assert.ok(nodeText(rendered.body).includes('设备与接口自检'), 'the new flow must actually open');

	/* A rejected cancel stays a persistent real error, never green. */
	harness = createHarness({
		init_status: [ prepared ], 'init_status#last': prepared,
		restore_status: [ installed ], 'restore_status#last': installed,
		init_cancel: [ { ok: false, error: '后端拒绝取消候选' } ]
	});
	rendered = await renderPage(harness, prepared, installed);
	await confirmedClick(rendered, 'cancel-candidate');
	await settle();
	assert.ok(nodeText(rendered.page.feedback).includes('后端拒绝取消候选'));
	assert.ok(!nodeText(rendered.page.feedback).includes('操作已受理'));
	assert.ok(button(rendered.body, 'cancel-candidate'), 'a failed cancel keeps the entry available for retry');
}

async function staleStatusActionsContract() {
	const prepared = { ok: true, phase: 'prepared', token: TOKEN };
	const failedFinish = { ok: true, phase: 'confirmed', token: TOKEN, confirmation_error: 'watcher 启动失败' };
	for (const scenario of [
		[ 'cancel-candidate', 'init_cancel', prepared, STATUS_PENDING_READY ],
		[ 'cancel-candidate', 'init_cancel', prepared, { ok: true, phase: 'prepared', token: EXIT_TOKEN } ],
		[ 'confirm-finish', 'init_finish', failedFinish, Object.assign({}, STATUS_PENDING_READY, { token: EXIT_TOKEN }) ]
	]) {
		const action = scenario[0], method = scenario[1], oldStatus = scenario[2], currentStatus = scenario[3];
		const rejection = { ok: false, message: '原操作已被替换或状态已变，请重新检测' };
		const harness = createHarness({
			init_status: [ oldStatus, currentStatus ], 'init_status#last': currentStatus,
			'restore_status#last': RESTORE_IDLE,
			[method]: [ rejection ]
		});
		const rendered = await renderPage(harness);
		await confirmedClick(rendered, action);
		assert.deepStrictEqual(harness.apiArgs(method), [ [ TOKEN ] ], 'send the identity shown on the card');
		assert.strictEqual(harness.apiArgs('init_recover').length, 0, 'never fall back to broad recovery');
		assert.strictEqual(rendered.page.status.token, currentStatus.token);
		assert.strictEqual(rendered.page.status.phase, currentStatus.phase);
		if (currentStatus.phase === 'pending')
			await runPoll(harness);
		const feedback = nodeText(rendered.page.feedback);
		assert.ok(feedback.includes(rejection.message) && !feedback.includes('操作已受理'));
	}

	let finishOldRead;
	const oldRead = new Promise(function(resolve) { finishOldRead = resolve; });
	const expired = { ok: true, phase: 'expired', token: TOKEN, prepared_expired_reason: 'cancelled-unapplied' };
	const harness = createHarness({
		init_status: [ prepared, oldRead, expired ], 'restore_status#last': RESTORE_IDLE,
		init_cancel: [ expired ]
	});
	const rendered = await renderPage(harness);
	const oldRefresh = button(rendered.body, 'refresh-status').click();
	await confirmedClick(rendered, 'cancel-candidate');
	finishOldRead(prepared);
	await oldRefresh;
	assert.strictEqual(rendered.page.status.phase, 'expired', 'the post-cancel read must supersede the older refresh');
	assert.strictEqual(button(rendered.body, 'cancel-candidate'), null);
}

async function main() {
	const checks = [
		[ 'read-only load', loadReadOnlyContract ],
		[ 'standalone down NIC and IPv4 role discovery', standaloneDeviceDiscoveryContract ],
		[ 'init happy path with real preview data', initHappyPathContract ],
		[ 'HTTP confirm rejection', confirmRejectionContract ],
		[ 'HTTP confirm transport reconciles its own token and feedback', confirmationTransportContract ],
		[ 'offline polling', offlinePollingContract ],
		[ 'inline confirmation can cancel and rejects stale state', inlineConfirmationContract ],
		[ 'lost init and exit apply replies', applyReplyLossContract ],
		[ 'apply reply and status reads after navigation', applyReplyNavigationContract ],
		[ 'apply registration and split phase/job replies', applyRegistrationContract ],
		[ 'reload from unresolved exit submission', exitLockRefusalReloadContract ],
		[ 'reviewed address survives first-time disconnect', reviewedReconnectAddressContract ],
		[ 'HTTP confirmation not ready', httpNotReadyContract ],
		[ 'expired / rolled back / conflict phases', phaseHandlingContract ],
		[ 'declaration undo in quiescent states', restoreRecoverQuiescentContract ],
		[ 'restore mapping waits for declaration undo', restoreMappingBlockedContract ],
		[ 'leftover preparing declaration cancel', declarationPreparingCancelContract ],
		[ 'restore confirm dual polling', restoreConfirmDualPollContract ],
		[ 'terminal countdown and guidance', terminalCountdownGuidanceContract ],
		[ 'prepared cancel and declaration order', preparedCancelOrderContract ],
		[ 'stale status actions', staleStatusActionsContract ],
		[ 'confirmation finish after error', confirmationFinishContract ],
		[ 'fresh render polling', freshRenderPollingContract ],
		[ 'overview refresh and polling lifetime', overviewRefreshPollingContract ],
		[ 'reconnect URL scheme and port', reconnectUrlContract ],
		[ 'import & restore flow', restoreFlowContract ],
		[ 'exit flow', exitFlowContract ],
		[ 'exit blocked', exitBlockedContract ],
		[ 'exit candidate refresh', exitCandidateRefreshContract ],
		[ 'confirmation error without health', confirmationErrorContract ],
		[ 'read-only account gating', readOnlyAccountContract ],
		[ 'plain text rendering', plainTextRenderingContract ],
		[ 'rules & sources inside the flow', rulesAndSourcesContract ],
		[ 'rule editor keeps current type and edits', ruleEditorOrderingContract ],
		[ 'prepare keeps the owning screen until reply', prepareScreenOwnershipContract ],
		[ 'prepare transport reads a changed authoritative candidate', prepareTransportContract ],
		[ 'restore remapping retains current discovery', restoreRemappingOwnershipContract ]
	];
	const failures = [];
	for (const check of checks) {
		try { await check[1](); }
		catch (error) { failures.push(check[0] + ': ' + (error && error.message || String(error))); }
	}
	if (failures.length)
		throw new Error(failures.join('\n'));
	console.log('LuCI wizard interaction contract passed.');
}

main().catch(function(error) {
	console.error(error.stack || error);
	process.exit(1);
});
