'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

class AbstractValue {}
class Flag extends AbstractValue {}
class Value extends AbstractValue {}
class ListValue extends AbstractValue {}
class NetworkSelect extends AbstractValue {}
class NamedSection {}
class GridSection {}

class Element {
	constructor(tagName) {
		this.tagName = tagName;
		this.attributes = {};
		this.children = [];
		this.listeners = {};
		this.style = {};
		this.value = '';
		this.textContent = '';
	}
	addEventListener(name, listener) { this.listeners[name] = listener; }
	appendChild(child) {
		if (Array.isArray(child)) {
			this.children.push(String(child));
			return child;
		}
		this.children.push(child);
		return child;
	}
	toString() {
		return '[object HTML' + this.tagName.charAt(0).toUpperCase() + this.tagName.slice(1) + 'Element]';
	}
	replaceChildren(...children) {
		this.children = [];
		children.forEach(this.appendChild.bind(this));
	}
	getAttribute(name) {
		return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null;
	}
	setAttribute(name, value) {
		this.attributes[name] = String(value);
		if (name === 'value') this.value = String(value);
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

if (typeof String.prototype.format !== 'function') {
	Object.defineProperty(String.prototype, 'format', {
		configurable: true,
		value: function() {
			let index = 0, args = arguments;
			return String(this).replace(/%[sd]/g, function() { return String(args[index++]); });
		}
	});
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
	return factory(globals.window, globals.document, {}, makeElement, function(value) { return value; }, ...instances);
}

function createViewHarness(overrides) {
	const events = [];
	const renderedOptions = [];
	let currentMap;
	const section = {
		option: function(OptionClass, name) {
			const option = new OptionClass();
			option.option = name;
			option.map = currentMap;
			option.value = function() { return option; };
			renderedOptions.push(option);
			return option;
		},
		tab: function() {},
		taboption: function(tab, OptionClass, name) { return this.option(OptionClass, name); }
	};
	class Map {
		constructor() { currentMap = this; }
		section() { return section; }
		render() { return Promise.resolve(makeElement('div', { class: 'cbi-map' })); }
		save() { events.push('save'); return Promise.resolve(); }
		reset() { events.push('reset'); return Promise.resolve(); }
		lookupOption(name, sectionId) {
			const option = renderedOptions.find(function(candidate) { return candidate.option === name; });
			return option ? [ option, sectionId ] : null;
		}
	}
	const notifications = [];
	const ui = {
		changes: { apply: function() { events.push('apply'); return Promise.resolve(); } },
		createHandlerFn: function(ctx, fn) {
			const wrapped = function() { return Promise.resolve(fn.apply(ctx, arguments)); };
			wrapped.isManagedHandler = true;
			return wrapped;
		},
		addNotification: function(title, content, level) { notifications.push({ content: nodeText(content), level: level }); }
	};
	const api = Object.assign({
		reload: function() { events.push('reload'); return Promise.resolve({ ok: true }); },
		safeText: function(value, fallback) { return value === null || value === undefined || value === '' ? (fallback || '—') : String(value); },
		notice: function(targetUi, reply, fallback) {
			targetUi.addNotification(null, makeElement('p', {}, reply && (reply.error || reply.message) || fallback), reply && reply.ok ? 'info' : 'error');
			return reply;
		}
	}, overrides && overrides.api);
	const reloads = [];
	return {
		events: events,
		notifications: notifications,
		dependencies: {
			view: { extend: function(properties) { return properties; } },
			form: { Map: Map, NamedSection: NamedSection, GridSection: GridSection, Flag: Flag, Value: Value, ListValue: ListValue },
			uci: {}, ui: ui, 'routepolicy/api': api,
			'tools.widgets': { NetworkSelect: NetworkSelect }
		},
		globals: {
			window: { confirm: function() { return true; }, location: { reload: function() { reloads.push(true); } } },
			document: { querySelectorAll: function() { return []; } }
		},
		reloads: reloads,
		ui: ui,
		api: api
	};
}

function loadApi(filename) {
	const notifications = [];
	const dependencies = {
		baseclass: { extend: function(properties) { return properties; } },
		rpc: { declare: function() { return function() {}; } }
	};
	const globals = { window: {}, document: {} };
	const api = loadSource(filename, dependencies, globals);
	api.notice({ addNotification: function(title, content, level) {
		notifications.push({ text: nodeText(content), level: level });
	} }, { ok: false, error: '逻辑接口不存在：usbwan' }, '验证候选配置');
	assert.deepStrictEqual(notifications, [ { text: '逻辑接口不存在：usbwan', level: 'error' } ],
		'RPC error details must be visible instead of a generic operation label');
}

async function formApplyContract(filename) {
	const harness = createViewHarness();
	const page = loadSource(filename, harness.dependencies, harness.globals);
	await page.render();
	await page.handleSaveApply(null, '0');
	assert.deepStrictEqual(harness.events, [ 'save', 'apply' ],
		'Save & Apply must commit staged UCI through LuCI before lifecycle reload triggers run');
}

async function statusContract(filename) {
	const reply = { ok: false, error: '逻辑接口不存在：usbwan' };
	const harness = createViewHarness({ api: {
		status: function() { return Promise.resolve({}); },
		validate: function() { return Promise.resolve(reply); },
		apply: function() { return Promise.resolve({ ok: true }); },
		reload: function() { return Promise.resolve({ ok: true }); },
		update: function() { return Promise.resolve({ ok: true }); },
		rollback: function() { return Promise.resolve({ ok: true }); },
		notice: function(targetUi, payload, fallback) {
			targetUi.addNotification(null, makeElement('p', {}, payload && (payload.error || payload.message) || fallback), payload && payload.ok ? 'info' : 'error');
			return payload;
		}
	} });
	const page = loadSource(filename, harness.dependencies, harness.globals);
	const root = page.render({
		service: { enabled: false },
		versions: { luci_app_routepolicy: '0.3.1-r1', smartdns: '46.1-r2' },
		interfaces: {
			lan: { device: 'br-lan', address: '192.0.2.1/24', online: true, message: 'LAN 正常' },
			wan: { device: 'eth0', address: '198.51.100.2/24', online: true, message: '默认出口正常' },
			policy: { device: 'eth1', address: '203.0.113.2/24', online: false, message: '策略出口离线' }
		}
	});
	assert.ok((root.getAttribute('class') || '').split(/\s+/).includes('cbi-map'),
		'the status page must use LuCI cbi-map structure');
	const buttons = findAll(root, function(node) { return node.tagName === 'button'; });
	const labels = buttons.map(nodeText);
	assert.ok(labels.includes('启用并应用'), 'the status page must expose an explicit enable action');
	assert.ok(labels.includes('停用并清理'), 'the status page must expose an explicit disable action');
	assert.ok(!nodeText(root).includes('[object HTMLDivElement]'),
		'interface rows must render as DOM rows instead of a stringified nested element array');
	for (const expected of [ 'br-lan', 'eth0', 'eth1', '192.0.2.1/24', '198.51.100.2/24', '203.0.113.2/24' ])
		assert.ok(nodeText(root).includes(expected), 'interface table must display ' + expected);
	for (const expected of [
		'RoutePolicy LuCI 版本', '0.3.1-r1', 'SmartDNS 版本', '46.1-r2',
		'升级与启用命令', 'sysupgrade -b /tmp/before-routepolicy.tar.gz',
		'apk add --allow-untrusted', "uci set routepolicy.main.enabled='1'"
	])
		assert.ok(nodeText(root).includes(expected), 'status page must display version or command guidance: ' + expected);
	const validate = buttons.find(function(button) { return nodeText(button) === '验证候选配置'; });
	assert.ok(validate && validate.listeners.click, 'validate action must be rendered');
	await validate.listeners.click();
	assert.strictEqual(harness.reloads.length, 0, 'failed validation must remain visible instead of reloading the page');
}

async function manualRuleFeedbackContract(filename) {
	const harness = createViewHarness({ api: {
		readUserList: function() { return Promise.resolve({ ok: true, content: '' }); },
		writeUserList: function() {
			return Promise.resolve({ ok: true, message: '人工规则已保存；启用时需重新应用配置后进入运行态', valid_count: 1, duplicate_count: 0, invalid_count: 0, invalid: [] });
		}
	} });
	const page = loadSource(filename, harness.dependencies, harness.globals);
	const root = page.render({ ok: true, content: '' });
	const pageText = nodeText(root);
	assert.ok(pageText.includes('保存后如何生效'), 'manual rule page must label the post-save activation guidance');
	for (const expected of [ '不会立即改变运行态', '运行状态', '验证候选配置', '重新应用当前配置' ])
		assert.ok(pageText.includes(expected), 'manual rule activation guidance must explain: ' + expected);
	const textarea = findAll(root, function(node) { return node.tagName === 'textarea'; })[0];
	textarea.value = 'example.com\n';
	const save = findAll(root, function(node) { return node.tagName === 'button' && nodeText(node) === '校验并保存'; })[0];
	assert.ok(save && save.listeners.click, 'manual rule save action must be rendered');
	await Promise.resolve(save.listeners.click());
	await new Promise(function(resolve) { setTimeout(resolve, 0); });
	assert.ok(nodeText(root).includes('人工规则已保存；启用时需重新应用配置后进入运行态'),
		'manual rule save result must remain visible in the page and explain when it takes effect');
}

async function manualRuleReservedIpv4Contract(filename) {
	let writes = 0;
	const harness = createViewHarness({ api: {
		readUserList: function() { return Promise.resolve({ ok: true, content: '' }); },
		writeUserList: function() {
			writes++;
			return Promise.resolve({ ok: false, message: '核心校验或原子写入人工规则失败', invalid: [] });
		}
	} });
	const page = loadSource(filename, harness.dependencies, harness.globals);
	const root = page.render({ ok: true, content: '' });
	const select = findAll(root, function(node) { return node.tagName === 'select'; })[0];
	select.value = 'ipv4-policy';
	select.listeners.change();
	await new Promise(function(resolve) { setTimeout(resolve, 0); });

	const textarea = findAll(root, function(node) { return node.tagName === 'textarea'; })[0];
	textarea.value = '192.168.1.1\n';
	const check = findAll(root, function(node) { return node.tagName === 'button' && nodeText(node) === '校验此列表'; })[0];
	check.listeners.click();
	assert.ok(nodeText(root).includes('非法 1 条'),
		'manual rule validation must reject IPv4 ranges that the core refuses to save');

	const save = findAll(root, function(node) { return node.tagName === 'button' && nodeText(node) === '校验并保存'; })[0];
	await Promise.resolve(save.listeners.click());
	assert.strictEqual(writes, 0, 'locally rejected IPv4 ranges must not be sent as a doomed save request');
}

async function manualRuleDomainLengthContract(filename) {
	let writes = 0;
	const harness = createViewHarness({ api: {
		readUserList: function() { return Promise.resolve({ ok: true, content: '' }); },
		writeUserList: function() {
			writes++;
			return Promise.resolve({ ok: false, message: '核心校验或原子写入人工规则失败', invalid: [] });
		}
	} });
	const page = loadSource(filename, harness.dependencies, harness.globals);
	const root = page.render({ ok: true, content: '' });
	const textarea = findAll(root, function(node) { return node.tagName === 'textarea'; })[0];
	const labels = [ 'a'.repeat(63), 'b'.repeat(63), 'c'.repeat(63), 'd'.repeat(63) ];
	textarea.value = labels.join('.') + '\n';

	const check = findAll(root, function(node) { return node.tagName === 'button' && nodeText(node) === '校验此列表'; })[0];
	check.listeners.click();
	assert.ok(nodeText(root).includes('非法 1 条'),
		'manual rule validation must reject domains longer than the core 253-character limit');

	const save = findAll(root, function(node) { return node.tagName === 'button' && nodeText(node) === '校验并保存'; })[0];
	await Promise.resolve(save.listeners.click());
	assert.strictEqual(writes, 0, 'overlong domains must not be sent as a doomed save request');
}

function noPhantomFormFooterContract(filename) {
	const harness = createViewHarness();
	const page = loadSource(filename, harness.dependencies, harness.globals);
	assert.strictEqual(page.handleSave, null, path.basename(filename) + ' must not render a form Save footer');
	assert.strictEqual(page.handleSaveApply, null, path.basename(filename) + ' must not render a form Save & Apply footer');
	assert.strictEqual(page.handleReset, null, path.basename(filename) + ' must not render a form Reset footer');
}

async function main() {
	const repo = path.resolve(__dirname, '../..');
	const viewDir = path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy');
	const menu = JSON.parse(fs.readFileSync(path.join(
		repo,
		'luci-app-routepolicy/root/usr/share/luci/menu.d/luci-app-routepolicy.json'
	), 'utf8'));
	const settingsView = menu['admin/services/routepolicy/settings'].action.path.split('/').pop() + '.js';
	const checks = [
		[ 'RPC error visibility', function() { return loadApi(path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/routepolicy/api.js')); } ],
		[ 'settings Save & Apply', function() { return formApplyContract(path.join(viewDir, settingsView)); } ],
		[ 'sources Save & Apply', function() { return formApplyContract(path.join(viewDir, 'sources.js')); } ],
		[ 'status controls', function() { return statusContract(path.join(viewDir, 'status.js')); } ],
		[ 'manual rule feedback', function() { return manualRuleFeedbackContract(path.join(viewDir, 'rules.js')); } ],
		[ 'manual rule reserved IPv4', function() { return manualRuleReservedIpv4Contract(path.join(viewDir, 'rules.js')); } ],
		[ 'manual rule domain length', function() { return manualRuleDomainLengthContract(path.join(viewDir, 'rules.js')); } ],
		[ 'status phantom footer', function() { return noPhantomFormFooterContract(path.join(viewDir, 'status.js')); } ],
		[ 'observability phantom footer', function() { return noPhantomFormFooterContract(path.join(viewDir, 'observability.js')); } ],
		[ 'rules phantom footer', function() { return noPhantomFormFooterContract(path.join(viewDir, 'rules.js')); } ],
		[ 'diagnostics phantom footer', function() { return noPhantomFormFooterContract(path.join(viewDir, 'diagnostics.js')); } ]
	];
	const failures = [];
	for (const check of checks) {
		try { await check[1](); }
		catch (error) { failures.push(check[0] + ': ' + error.message); }
	}
	if (failures.length)
		throw new Error(failures.join('\n'));
	console.log('LuCI interaction contract passed.');
}

main().catch(function(error) {
	console.error(error.stack || error);
	process.exit(1);
});
