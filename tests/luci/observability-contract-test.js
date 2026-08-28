'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

class Element {
	constructor(tagName) {
		this.tagName = tagName;
		this.attributes = {};
		this.children = [];
		this.listeners = {};
		this.textContent = '';
		this.value = '';
	}
	appendChild(child) {
		this.children.push(child);
		if (this.tagName === 'select' && child instanceof Element && child.tagName === 'option' && this.value === '')
			this.value = child.value;
		return child;
	}
	replaceChildren(...children) { this.children = children; }
	addEventListener(name, listener) { this.listeners[name] = listener; }
	setAttribute(name, value) { this.attributes[name] = String(value); if (name === 'value') this.value = String(value); }
	getAttribute(name) { return this.attributes[name] || null; }
}

function E(tagName, attributes, children) {
	const element = new Element(tagName);
	Object.keys(attributes || {}).forEach(function(key) {
		if (attributes[key] == null) return;
		if (typeof attributes[key] === 'function') element.addEventListener(key, attributes[key]);
		else element.setAttribute(key, attributes[key]);
	});
	(Array.isArray(children) ? children : [ children ]).forEach(function(child) { if (child != null) element.appendChild(child); });
	return element;
}

function nodeText(node) {
	if (!(node instanceof Element)) return node == null ? '' : String(node);
	return node.textContent + node.children.map(nodeText).join('');
}

function findAll(node, predicate, found) {
	found = found || [];
	if (!(node instanceof Element)) return found;
	if (predicate(node)) found.push(node);
	node.children.forEach(function(child) { findAll(child, predicate, found); });
	return found;
}

function flush() { return new Promise(function(resolve) { setImmediate(resolve); }); }

function loadPage(filename, api, clock) {
	const source = fs.readFileSync(filename, 'utf8');
	const dependencies = { view: { extend: function(value) { return value; } }, 'routepolicy/api': api };
	const aliases = [];
	const instances = [];
	const directive = /^'(use strict|require\s+(\S+)(?:\s+as\s+([a-zA-Z_]\S*))?)';\s*/;
	let remaining = source;
	while (true) {
		const match = directive.exec(remaining);
		if (!match) break;
		remaining = remaining.substring(match[0].length);
		if (!match[2]) continue;
		aliases.push(match[3] || match[2].replace(/[^a-zA-Z0-9_]/g, '_'));
		instances.push(dependencies[match[2]]);
	}
	const documentListeners = {};
	const document = { visibilityState: 'visible', addEventListener: function(name, handler) { documentListeners[name] = handler; } };
	const windowListeners = {};
	const timers = [];
	let sequence = 0;
	const window = {
		setTimeout: function(callback, delay) { const timer = { id: ++sequence, callback: callback, delay: delay, cancelled: false }; timers.push(timer); return timer.id; },
		clearTimeout: function(id) { timers.forEach(function(timer) { if (timer.id === id) timer.cancelled = true; }); },
		addEventListener: function(name, handler) { windowListeners[name] = handler; }
	};
	const factory = new Function('window', 'document', 'performance', 'E', '_', ...aliases, source);
	return { page: factory(window, document, clock, E, function(value) { return value; }, ...instances), document: document, documentListeners: documentListeners, windowListeners: windowListeners, timers: timers };
}

function activeTimer(harness, delay) {
	return harness.timers.filter(function(timer) { return !timer.cancelled && timer.delay === delay; }).slice(-1)[0];
}

async function runTimer(harness, delay) {
	const timer = activeTimer(harness, delay);
	assert.ok(timer, 'expected a ' + delay + 'ms timer');
	timer.cancelled = true;
	timer.callback();
	await flush(); await flush(); await flush();
}

async function counterRecoveryContract(repo) {
	let now = 1000;
	let index = 0;
	const snapshots = [
		{ rx_bytes: 'malformed', tx_bytes: '100' },
		{ rx_bytes: '100', tx_bytes: '200' },
		{ rx_bytes: '200', tx_bytes: '300' },
		{ ok: false, message: '接口快照暂不可用' },
		{ rx_bytes: '500', tx_bytes: '600' },
		{ rx_bytes: '600', tx_bytes: '700' }
	];
	const counters = function(values) {
		return Object.assign({ rx_packets: '1', tx_packets: '1', rx_errors: '0', tx_errors: '0', rx_dropped: '0', tx_dropped: '0' }, values);
	};
	const api = {
		safeText: function(value, fallback) { return value == null || value === '' ? (fallback || '—') : String(value); },
		observeInterfaces: function() {
			const value = snapshots[index++] || snapshots[snapshots.length - 1];
			return Promise.resolve(value.ok === false ? value : { ok: true, interfaces: [ Object.assign({ device: 'br-lan', roles: [ { role: 'lan' } ], online: true }, counters(value)) ] });
		},
		observeSets: function() { return Promise.resolve({ ok: true, source_accounting: false, sets: [] }); },
		observeQuery: function() { return Promise.resolve({ ok: true, items: [] }); }
	};
	const harness = loadPage(path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/observability.js'), api, { now: function() { return now; } });
	const root = harness.page.render();
	await flush(); await flush(); await flush();
	for (const delay of [ 2000, 2000, 2000, 4000, 2000 ]) {
		now += delay;
		await runTimer(harness, delay);
	}
	assert.ok(nodeText(root).includes('接口数据已过期') === false, 'a later healthy snapshot must clear the stale state');
	assert.strictEqual(findAll(root, function(node) { return node.tagName === 'polyline'; }).length, 0,
		'malformed counters and failed polls must clear the baseline so recovered samples form a disconnected chart segment');
}

async function deviceDisappearanceContract(repo) {
	let now = 1000;
	let index = 0;
	const snapshots = [
		[ { device: 'br-lan', roles: [ { role: 'lan' } ], online: true, counters: { rx_bytes: '100', tx_bytes: '100', rx_packets: '1', tx_packets: '1', rx_errors: '0', tx_errors: '0', rx_dropped: '0', tx_dropped: '0' } } ],
		[ { device: 'br-lan', roles: [ { role: 'lan' } ], online: true, counters: { rx_bytes: '200', tx_bytes: '200', rx_packets: '2', tx_packets: '2', rx_errors: '0', tx_errors: '0', rx_dropped: '0', tx_dropped: '0' } } ],
		[],
		[ { device: 'br-lan', roles: [ { role: 'lan' } ], online: true, counters: { rx_bytes: '500', tx_bytes: '500', rx_packets: '5', tx_packets: '5', rx_errors: '0', tx_errors: '0', rx_dropped: '0', tx_dropped: '0' } } ],
		[ { device: 'br-lan', roles: [ { role: 'lan' } ], online: true, counters: { rx_bytes: '600', tx_bytes: '600', rx_packets: '6', tx_packets: '6', rx_errors: '0', tx_errors: '0', rx_dropped: '0', tx_dropped: '0' } } ]
	];
	const api = {
		safeText: function(value, fallback) { return value == null || value === '' ? (fallback || '—') : String(value); },
		observeInterfaces: function() { return Promise.resolve({ ok: true, interfaces: snapshots[index++] || [] }); },
		observeSets: function() { return Promise.resolve({ ok: true, source_accounting: false, sets: [] }); },
		observeQuery: function() { return Promise.resolve({ ok: true, items: [] }); }
	};
	const harness = loadPage(path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/observability.js'), api, { now: function() { return now; } });
	const root = harness.page.render();
	await flush(); await flush(); await flush();
	for (const delay of [ 2000, 2000, 2000, 2000 ]) {
		now += delay;
		await runTimer(harness, delay);
	}
	assert.strictEqual(findAll(root, function(node) { return node.tagName === 'polyline'; }).length, 0,
		'a device missing from a successful snapshot must discard its old baseline before it returns');
}

async function main() {
	const calls = [];
	let interfaceCalls = 0;
	let failInterfaces = false;
	let accountingAvailable = true;
	let sourceAccounting = true;
	let rejectCursor = false;
	let rxBytes = 9007199254740995n;
	let txBytes = 9007199254740997n;
	const api = {
		safeText: function(value, fallback) { return value == null || value === '' ? (fallback || '—') : String(value); },
		observeInterfaces: function() {
			interfaceCalls++;
			if (failInterfaces) return Promise.resolve({ ok: false, message: '接口快照暂不可用' });
			const reply = { ok: true, unavailable_roles: [ 'policy' ], interfaces: [ {
				device: 'br-lan', roles: [ { role: 'lan', interface: 'lan' }, { role: 'default', interface: 'wan' } ], online: true,
				rx_bytes: rxBytes.toString(), tx_bytes: txBytes.toString(), rx_packets: '12', tx_packets: '13',
				rx_errors: '0', tx_errors: '0', rx_dropped: '0', tx_dropped: '0'
			} ] };
			rxBytes += 1024n;
			txBytes += 2048n;
			return Promise.resolve(reply);
		},
		observeSets: function() {
			return Promise.resolve({ source_accounting: sourceAccounting, sets: [
				{ dataset: 'domain_policy', count: 1 }, { dataset: 'domain_default', count: 0 }, { dataset: 'static_policy4', count: 0 }, { dataset: 'static_default4', count: 0 }, { dataset: 'dynamic_policy4', count: 0 }, { dataset: 'dynamic_default4', count: 0 },
				{ dataset: 'source_ingress4', available: accountingAvailable, count: 4096, saturated: true }, { dataset: 'source_egress4', available: accountingAvailable, count: 1, saturated: false }
			] });
		},
		observeQuery: function(params) {
			calls.push(params);
			if (params.dataset.indexOf('source_') === 0)
				return Promise.resolve({ items: [ { address: '192.0.2.7', device: 'br-lan', packets: '9007199254740995', bytes: '9007199254740997', expires: 59 } ] });
			if (params.cursor === 'next') return Promise.resolve(rejectCursor
				? { ok: false, message: 'cursor 已失效或不属于当前数据集' }
				: { ok: true, items: [ { domain: 'next.example', target: 'policy' } ], next_cursor: null });
			return Promise.resolve({ items: [ { domain: '<img src=x onerror=alert(1)>', target: 'policy' } ], next_cursor: 'next', volatile: true, truncated: true });
		}
	};
	let now = 1000;
	const repo = path.resolve(__dirname, '../..');
	const harness = loadPage(path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/observability.js'), api, { now: function() { return now; } });
	const root = harness.page.render();
	await flush(); await flush(); await flush(); await flush();

	assert.ok(activeTimer(harness, 2000), 'interface snapshots must poll at 2 seconds');
	assert.ok(activeTimer(harness, 10000), 'set summaries must poll at 10 seconds');
	assert.ok(calls.some(function(call) { return call.dataset === 'domain_policy' && call.limit === 50; }), 'initial rules query must be bounded');
	assert.ok(calls.some(function(call) { return call.dataset === 'source_ingress4' && call.sort === 'bytes' && call.limit === 50; }), 'enabled source accounting must poll its bounded Top list');
	assert.ok(calls.some(function(call) { return call.dataset === 'source_ingress4' && call.query === ''; }), 'source Top queries must pass an explicit bounded query string');
	assert.ok(nodeText(root).includes('已饱和'), 'a saturated source set must warn that new attribution keys may be missing');
	assert.ok(nodeText(root).includes('缺失逻辑角色：policy'), 'unavailable logical roles must remain visible beside interface state');
	assert.ok(nodeText(root).includes('8 PiB'), '64-bit byte counters must render without Number precision loss');
	assert.ok(!findAll(root, function(node) { return node.tagName === 'img'; }).length, 'untrusted query values must render as text, never HTML');

	const next = findAll(root, function(node) { return node.tagName === 'button' && nodeText(node) === '下一页'; })[0];
	assert.ok(next && next.listeners.click, 'rules pagination must provide a next action when a cursor exists');
	rejectCursor = true;
	next.listeners.click();
	await flush(); await flush();
	assert.ok(calls.some(function(call) { return call.cursor === 'next'; }), 'next page must use the opaque cursor returned by the backend');
	assert.ok(nodeText(root).includes('cursor 已失效或不属于当前数据集'), 'a rejected cursor must remain visible instead of becoming an empty successful page');

	const interfaceTimer = activeTimer(harness, 2000);
	failInterfaces = true;
	interfaceTimer.callback();
	await flush(); await flush();
	assert.ok(activeTimer(harness, 4000), 'failed interface polling must back off instead of retaining the 2-second cadence');
	assert.ok(nodeText(root).includes('接口数据已过期'), 'resolved ok:false polling replies must visibly mark stale data');

	harness.document.visibilityState = 'hidden';
	harness.documentListeners.visibilitychange();
	assert.ok(!activeTimer(harness, 2000) && !activeTimer(harness, 4000) && !activeTimer(harness, 10000), 'hidden documents must cancel all polling timers');
	const beforeVisible = interfaceCalls;
	harness.document.visibilityState = 'visible';
	failInterfaces = false;
	now += 600000;
	harness.documentListeners.visibilitychange();
	await flush(); await flush();
	assert.strictEqual(interfaceCalls, beforeVisible + 1, 'becoming visible must rebuild a single interface baseline without overlapping requests');
	assert.ok(activeTimer(harness, 2000), 'visible documents must resume the 2-second interface poll');

	const sourceDirection = findAll(root, function(node) { return node.tagName === 'select' && node.children.some(function(child) { return child instanceof Element && child.value === 'source_ingress4'; }); })[0];
	sourceDirection.value = 'source_egress4';
	sourceDirection.listeners.change();
	await flush(); await flush();
	assert.ok(calls.some(function(call) { return call.dataset === 'source_egress4'; }), 'direction selection must query the selected source dataset');
	const sourceQuery = findAll(root, function(node) { return node.tagName === 'input' && node.getAttribute('placeholder') === '搜索 IPv4/CIDR 前缀'; })[0];
	sourceQuery.value = '192.0.2';
	sourceQuery.listeners.keydown({ key: 'Enter' });
	await flush(); await flush();
	assert.ok(calls.some(function(call) { return call.dataset === 'source_egress4' && call.query === '192.0.2'; }), 'source search must pass the selected IPv4 prefix through observe_query');
	const queriesBeforeInvalidSourceSearch = calls.length;
	sourceQuery.value = 'invalid search';
	sourceQuery.listeners.keydown({ key: 'Enter' });
	assert.strictEqual(calls.length, queriesBeforeInvalidSourceSearch, 'source search must reject text outside the backend IPv4-prefix grammar before RPC');
	assert.ok(nodeText(root).includes('IP 查询只能使用 IPv4、CIDR 或点号数字前缀'), 'invalid source search must remain visible to the user');

	const search = findAll(root, function(node) { return node.tagName === 'input' && node.getAttribute('placeholder') === '搜索当前生效规则'; })[0];
	search.value = 'example';
	findAll(root, function(node) { return node.tagName === 'button' && nodeText(node) === '搜索'; })[1].listeners.click();
	await flush(); await flush();
	assert.ok(calls.some(function(call) { return call.dataset === 'domain_policy' && call.query === 'example'; }), 'rules search must pass the text query only through the bounded query contract');

	accountingAvailable = false;
	activeTimer(harness, 10000).callback();
	await flush(); await flush();
	assert.ok(nodeText(root).includes('归因数据不可用'), 'enabled source accounting with unavailable sets must not be presented as disabled');
	assert.ok(!nodeText(root).includes('请在“基础设置 → 高级设置”启用'), 'unavailable source sets must not direct an already-enabled user to enable statistics');
	sourceAccounting = false;
	activeTimer(harness, 10000).callback();
	await flush(); await flush();
	assert.ok(nodeText(root).includes('按源 IP 统计已关闭'), 'only a disabled source-accounting switch may show the enable path');

	for (let index = 0; index < 151; index++) {
		now += 2000;
		activeTimer(harness, 2000).callback();
		await flush(); await flush();
	}
	const polylines = findAll(root, function(node) { return node.tagName === 'polyline'; });
	assert.ok(polylines.every(function(line) { return line.getAttribute('points').split(' ').length <= 150; }), 'rate history must retain at most 150 points per line');
	rxBytes = 1n;
	txBytes = 2n;
	for (let index = 0; index < 3; index++) {
		now += 2000;
		activeTimer(harness, 2000).callback();
		await flush(); await flush();
	}
	assert.ok(findAll(root, function(node) { return node.tagName === 'polyline'; }).length >= 4,
		'counter rollback must break the RX/TX chart instead of drawing a negative-rate segment');
	await counterRecoveryContract(repo);
	await deviceDisappearanceContract(repo);

	console.log('LuCI observability contract passed.');
}

main().catch(function(error) { console.error(error.stack || error); process.exit(1); });
