'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

class CBIAbstractValue {}
class Flag extends CBIAbstractValue {}
class Value extends CBIAbstractValue {}
class NetworkSelect extends CBIAbstractValue {}
class NamedSection {}

const renderedOptions = [];
const sectionTabs = [];
let currentMap = null;

function makeOption(OptionClass, name, tab) {
	if (typeof OptionClass !== 'function' || !(OptionClass.prototype instanceof CBIAbstractValue))
		throw new TypeError('Class must be a descendant of CBIAbstractValue');

	const option = new OptionClass();
	option.option = name;
	option.tab = tab || null;
	option.map = currentMap;
	renderedOptions.push(option);
	return option;
}

/* LuCI renders tabbed sections in registration order and omits unbound options. */
const section = {
	addremove: true,
	option: function(OptionClass, name) { return makeOption(OptionClass, name); },
	tab: function(name) {
		if (sectionTabs.every(function(existing) { return existing.name !== name; }))
			sectionTabs.push({ name: name });
	},
	taboption: function(tab, OptionClass, name) {
		return makeOption(OptionClass, name, tab);
	}
};

class Map {
	constructor(config, title, description) { this.description = description; currentMap = this; }
	section() { return section; }
	render() { return 'rendered'; }
	save() { return Promise.resolve(); }
	reset() { return Promise.resolve(); }
	lookupOption(name, sectionId) {
		const option = renderedOptions.find(function(candidate) { return candidate.option === name; });
		return option ? [ option, sectionId ] : null;
	}
}

class Element {
	constructor(tagName) {
		this.tagName = tagName;
		this.attributes = {};
		this.children = [];
		this.listeners = {};
		this.style = {};
		this.value = '';
		this.selected = false;
		this.selectedIndex = -1;
	}

	addEventListener(name, listener) { this.listeners[name] = listener; }
	getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null; }
	hasAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name); }
	setAttribute(name, value) {
		this.attributes[name] = String(value);
		if (name === 'value') this.value = String(value);
		if (name === 'selected') this.selected = true;
	}
	appendChild(child) {
		this.children.push(child);
		if (!(child instanceof Element)) return child;
		child.parentNode = this;
		if (this.tagName === 'select' && child.tagName === 'option') {
			const index = this.children.length - 1;
			if (this.selectedIndex === -1 || child.selected) {
				this.children.forEach(function(option) { option.selected = false; });
				child.selected = true;
			this.selectedIndex = index;
			this.value = child.value;
			}
		}
		return child;
	}
	replaceChildren() {
		this.children = [];
		for (let i = 0; i < arguments.length; i++)
			this.appendChild(arguments[i]);
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
	for (const child of items)
		if (child != null) element.appendChild(child);
	return element;
}

function findByAttribute(node, name, value) {
	if (!(node instanceof Element)) return null;
	if (node.getAttribute(name) === value) return node;
	for (const child of node.children) {
		const match = findByAttribute(child, name, value);
		if (match) return match;
	}
	return null;
}

function loadView(filename) {
	const source = fs.readFileSync(filename, 'utf8');
	const dependencies = {
		view: { extend: function(properties) { return properties; } },
		form: { Map: Map, NamedSection: NamedSection, Flag: Flag, Value: Value },
		uci: {},
		ui: { createHandlerFn: function(ctx, fn) { return fn.bind(ctx); } },
		'routepolicy/api': { safeText: function(value, fallback) { return value == null || value === '' ? (fallback || '—') : String(value); } },
		'tools.widgets': { NetworkSelect: NetworkSelect }
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
			throw new Error('Unsupported view dependency: ' + match[2]);

		aliases.push(match[3] || match[2].replace(/[^a-zA-Z0-9_]/g, '_'));
		instances.push(dependencies[match[2]]);
	}

	const factory = new Function('window', 'document', 'L', 'E', '_', ...aliases, source);
	return factory({}, {}, {}, makeElement, function(value) { return value; }, ...instances);
}

const repo = path.resolve(__dirname, '../..');
const menu = JSON.parse(fs.readFileSync(path.join(
	repo,
	'luci-app-routepolicy/root/usr/share/luci/menu.d/luci-app-routepolicy.json'
), 'utf8'));
const settingsView = menu['admin/services/routepolicy/settings'].action.path;
assert.match(settingsView, /^routepolicy\/settings-v[0-9]+$/,
	'the settings route must use a package-owned asset generation so an old form.NetworkSelect view cannot survive an upgrade');
const settings = loadView(path.join(
	repo,
	'luci-app-routepolicy/htdocs/luci-static/resources/view', settingsView + '.js'
));

assert.strictEqual(settings.render(), 'rendered');
assert.match(currentMap.description, /初始化期间.*其他页面或 SSH.*SmartDNS.*确认成功或回滚完成.*冲突检查/);
assert.deepStrictEqual(
	renderedOptions.filter(function(option) { return option instanceof NetworkSelect; }).map(function(option) { return option.option; }),
	[ 'lan_interface', 'default_interface', 'policy_interface' ]
);

/* ---------- native LuCI tab grouping contract ---------- */

const tabOrder = sectionTabs.map(function(tab) { return tab.name; });
assert.ok(tabOrder.includes('advanced'), 'the advanced tab must survive the basic-settings regression fix');
assert.strictEqual(tabOrder[0], 'general',
	'the general tab must be registered first so the default visible tab holds the basic controls');

/* renderUCISection placement rule: a tabbed section renders only options
   bound to a registered tab, so this list is what actually reaches the DOM. */
assert.deepStrictEqual(
	renderedOptions.filter(function(option) { return tabOrder.indexOf(option.tab) >= 0; }).map(function(option) { return option.option; }),
	[ 'enabled', 'lan_interface', 'default_interface', 'policy_interface',
	  'strict_enforcement', 'dns_redirect', 'warm_restore', 'route_local_traffic', 'source_accounting',
	  'route_table', 'rule_priority', 'mark', 'mark_mask', 'smartdns_enabled', 'smartdns_policy_group',
	  'auto_update', 'update_hour', 'update_minute', 'update_via_policy_interface',
	  'source_idle_timeout', 'source_max_entries' ],
	'every settings control must actually reach the tabbed DOM');

assert.deepStrictEqual(
	renderedOptions.filter(function(option) { return option.tab === tabOrder[0]; }).map(function(option) { return option.option; }),
	[ 'enabled', 'lan_interface', 'default_interface', 'policy_interface',
	  'strict_enforcement', 'dns_redirect', 'warm_restore', 'route_local_traffic', 'source_accounting' ],
	'the default visible tab must hold the basic controls including the enable switch');

assert.deepStrictEqual(
	renderedOptions.filter(function(option) { return option.tab === 'advanced'; }).map(function(option) { return option.option; }),
	[ 'route_table', 'rule_priority', 'mark', 'mark_mask', 'smartdns_enabled', 'smartdns_policy_group',
	  'auto_update', 'update_hour', 'update_minute', 'update_via_policy_interface',
	  'source_idle_timeout', 'source_max_entries' ],
	'all advanced controls must stay on the advanced tab');

const enabledOption = renderedOptions.find(function(option) { return option.option === 'enabled'; });
assert.strictEqual(enabledOption.default, '0', 'RoutePolicy must stay opt-in by default');
assert.strictEqual(enabledOption.rmempty, false,
	'an explicit disable must persist enabled=0 in UCI instead of being removed by the LuCI form Flag rmempty rule');
for (const expected of [ [ 'strict_enforcement', '1' ], [ 'dns_redirect', '1' ], [ 'warm_restore', '1' ],
		[ 'route_local_traffic', '0' ], [ 'source_accounting', '0' ] ]) {
	const option = renderedOptions.find(function(candidate) { return candidate.option === expected[0]; });
	assert.strictEqual(option.default, expected[1], expected[0] + ' must keep its existing default semantics');
}

const smartdns = loadView(path.join(
	repo,
	'luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/smartdns.js'
));
const smartdnsPage = smartdns.render([ {
	initialized: true,
	settings: { enabled: { explicit: '1' } },
	servers: [ { id: 'resolver', enabled: '1', type: 'tls', ip: '1.1.1.1' } ]
}, { content: '' } ]);
for (const expected of [ [ 'enabled', '1' ], [ 'server.resolver.enabled', '1' ], [ 'server.resolver.type', 'tls' ] ]) {
	const select = findByAttribute(smartdnsPage, 'data-key', expected[0]);
	assert.ok(select, expected[0] + ' control must render');
	assert.strictEqual(select.value, expected[1], expected[0] + ' must reflect the rpcd value');
	assert.strictEqual(select.children.filter(function(option) { return option.hasAttribute('selected'); }).length, 1,
		expected[0] + ' must render exactly one selected option');
}

const mark = renderedOptions.find(function(option) { return option.option === 'mark'; });
const mask = renderedOptions.find(function(option) { return option.option === 'mark_mask'; });
const localTraffic = renderedOptions.find(function(option) { return option.option === 'route_local_traffic'; });
const sourceAccounting = renderedOptions.find(function(option) { return option.option === 'source_accounting'; });
const sourceTimeout = renderedOptions.find(function(option) { return option.option === 'source_idle_timeout'; });
const sourceMaximum = renderedOptions.find(function(option) { return option.option === 'source_max_entries'; });
assert.strictEqual(typeof mark.validate, 'function', 'mark must use a backend-compatible custom validator');
assert.strictEqual(typeof mask.validate, 'function', 'mark_mask must use a backend-compatible custom validator');
for (const value of [ '0x1', '0x100', '0x80000000' ]) {
	mark.formvalue = function() { return value; };
	mask.formvalue = function() { return value; };
	assert.strictEqual(mark.validate('main', value), true, value + ' must be a valid mark bit');
	assert.strictEqual(mask.validate('main', value), true, value + ' must be a valid mark mask');
}
for (const value of [ '256', '0x0', '0x101', '0x100000000', '0X100' ]) {
	mark.formvalue = function() { return value; };
	mask.formvalue = function() { return value; };
	assert.notStrictEqual(mark.validate('main', value), true, value + ' must be rejected as a mark bit');
}
mark.formvalue = function() { return '0x100'; };
mask.formvalue = function() { return '0x200'; };
assert.notStrictEqual(mark.validate('main', '0x100'), true, 'mark and mask must be identical');
assert.notStrictEqual(mask.validate('main', '0x200'), true, 'mask and mark must be identical');
assert.strictEqual(localTraffic.default, '0', 'router-local traffic classification must remain opt-in by default');
assert.strictEqual(sourceAccounting.default, '0', 'source accounting must remain opt-in by default');
assert.strictEqual(sourceTimeout.datatype, 'range(60,86400)', 'source accounting timeout must have the backend-compatible bound');
assert.strictEqual(sourceMaximum.datatype, 'range(256,16384)', 'source accounting capacity must have the backend-compatible bound');

/* ---------- lifecycle wizard ---------- */

function loadLifecycleModule() {
	function BaseClass() {}
	BaseClass.extend = function(properties) {
		function Subclass() {}
		Subclass.prototype = Object.create(BaseClass.prototype);
		Object.assign(Subclass.prototype, properties);
		return Subclass;
	};
	const lifecycleFactory = loadViewWithDependencies(
		path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/routepolicy/lifecycle.js'),
		{ baseclass: BaseClass }
	);
	return new (lifecycleFactory())();
}

/* Re-run the directive loader with a custom dependency set for the wizard. */
function loadViewWithDependencies(filename, dependencies) {
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
			throw new Error('Unsupported view dependency: ' + match[2]);
		aliases.push(match[3] || match[2].replace(/[^a-zA-Z0-9_]/g, '_'));
		instances.push(dependencies[match[2]]);
	}
	const factory = new Function('window', 'document', 'L', 'E', '_', ...aliases, source);
	return function(L, window, document) {
		return factory(window, document, L, makeElement, function(value) { return value; }, ...instances);
	};
}

const wizardEntry = menu['admin/services/routepolicy/wizard'];
assert.ok(wizardEntry, 'the menu must expose the lifecycle wizard entry');
assert.strictEqual(wizardEntry.action.path, 'routepolicy/wizard');
assert.strictEqual(wizardEntry.depends.acl[0], 'luci-app-routepolicy');

const wizardLoadCalls = [];
const wizardApi = {
	safeText: function(value, fallback) { return value == null || value === '' ? (fallback || '—') : String(value); },
	initStatus: function() { wizardLoadCalls.push('init_status'); return Promise.resolve({ ok: true, phase: 'absent' }); },
	restoreStatus: function() { wizardLoadCalls.push('restore_status'); return Promise.resolve({ ok: true, candidate_pending: false, declaration_phase: 'absent', init_token: '' }); }
};
for (const forbidden of [ 'init_discover', 'init_preview', 'init_prepare', 'init_candidate', 'init_apply', 'init_cancel', 'init_finish', 'init_recover',
	'config_export', 'config_import', 'restore_prepare', 'restore_recover', 'exit_preview', 'exit_prepare',
	'exit_candidate', 'exit_apply', 'write_user_list' ]) {
	const camel = forbidden.replace(/_([a-z])/g, function(_, c) { return c.toUpperCase(); });
	wizardApi[camel] = function() {
		wizardLoadCalls.push(forbidden);
		return Promise.reject(new Error(forbidden + ' must not be callable during load or render'));
	};
}
let wizardPosted = false;
const wizardFactory = loadViewWithDependencies(
	path.join(repo, 'luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/wizard.js'),
	{
		view: { extend: function(properties) { return properties; } },
		uci: {
			load: function() { wizardLoadCalls.push('uci.load'); return Promise.resolve(); },
			get: function() { return null; },
			sections: function() { return []; },
			set: function() { throw new Error('wizard render must not write UCI'); }
		},
		ui: {
			createHandlerFn: function(ctx, fn) { return fn.bind(ctx); },
			addNotification: function() {}
		},
		request: {
			post: function() { wizardPosted = true; return Promise.reject(new Error('render must not post')); }
		},
		'routepolicy/api': wizardApi,
		'routepolicy/lifecycle': loadLifecycleModule()
	}
);
const wizard = wizardFactory({}, { setTimeout: function() { return 1; }, clearTimeout: function() {} }, {});
assert.strictEqual(wizard.handleSave, null, 'the wizard must not render a form Save footer');
assert.strictEqual(wizard.handleSaveApply, null, 'the wizard must not render a form Save & Apply footer');
assert.strictEqual(wizard.handleReset, null, 'the wizard must not render a form Reset footer');

(async function() {
	const loaded = await wizard.load();
	const wizardRoot = wizard.render(loaded);
	for (const call of wizardLoadCalls)
		assert.ok(call === 'init_status' || call === 'restore_status' || call === 'uci.load',
			'wizard load/render must stay read-only, got ' + call);
	assert.strictEqual(wizardPosted, false, 'render must not POST the confirmation endpoint');
	let wizardText = '';
	const collect = function(node) {
		if (node == null) return;
		if (!(node instanceof Element)) { wizardText += String(node); return; }
		wizardText += node.textContent;
		node.children.forEach(collect);
	};
	collect(wizardRoot);
	for (const expected of [ '初始化与恢复向导', '未初始化', '首次配置向导', '导入恢复', '退出', '重新检测状态', '默认启用开关' ])
		assert.ok(wizardText.includes(expected), 'wizard overview must display ' + expected);

	/* Hostile backend values render as literal plain text. */
	const hostile = wizard.render([
		{ ok: true, phase: 'pending', token: 'd'.repeat(32), management_address: '<img src=x onerror=alert(1)>',
			remaining_seconds: 60, http_confirmation_ready: false, confirmation_transport: '<script>alert(2)</script>',
			conflicts: '<script>alert(3)</script>' },
		{ ok: true, candidate_pending: false, declaration_phase: 'absent', init_token: '' }
	]);
	let hostileText = '';
	const hostileCollect = function(node) {
		if (node == null) return;
		if (!(node instanceof Element)) { hostileText += String(node); return; }
		hostileText += node.textContent;
		node.children.forEach(hostileCollect);
	};
	hostileCollect(hostile);
	for (const expected of [ '<img src=x onerror=alert(1)>', '<script>alert(3)</script>' ])
		assert.ok(hostileText.includes(expected), 'backend values must render as literal text: ' + expected);
	const scanEventAttributes = function(node, found) {
		found = found || [];
		if (!(node instanceof Element)) return found;
		for (const name of Object.keys(node.attributes))
			if (/^on/i.test(name)) found.push(name);
		node.children.forEach(function(child) { scanEventAttributes(child, found); });
		return found;
	};
	assert.deepStrictEqual(scanEventAttributes(hostile), [], 'no inline event attribute may be derived from data');
})().then(function() {
	console.log('LuCI view render contract passed.');
}, function(error) {
	console.error(error.stack || error);
	process.exit(1);
});
