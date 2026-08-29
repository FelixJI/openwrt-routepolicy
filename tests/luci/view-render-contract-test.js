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
let currentMap = null;

function makeOption(OptionClass, name) {
	if (typeof OptionClass !== 'function' || !(OptionClass.prototype instanceof CBIAbstractValue))
		throw new TypeError('Class must be a descendant of CBIAbstractValue');

	const option = new OptionClass();
	option.option = name;
	option.map = currentMap;
	renderedOptions.push(option);
	return option;
}

const section = {
	addremove: true,
	option: makeOption,
	tab: function() {},
	taboption: function(tab, OptionClass, name) {
		return makeOption(OptionClass, name);
	}
};

class Map {
	constructor() { currentMap = this; }
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
assert.deepStrictEqual(
	renderedOptions.filter(function(option) { return option instanceof NetworkSelect; }).map(function(option) { return option.option; }),
	[ 'lan_interface', 'default_interface', 'policy_interface' ]
);

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

console.log('LuCI view render contract passed.');
