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

function makeOption(OptionClass, name) {
	if (typeof OptionClass !== 'function' || !(OptionClass.prototype instanceof CBIAbstractValue))
		throw new TypeError('Class must be a descendant of CBIAbstractValue');

	const option = new OptionClass();
	option.option = name;
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
	section() { return section; }
	render() { return 'rendered'; }
	save() { return Promise.resolve(); }
	reset() { return Promise.resolve(); }
}

function loadView(filename) {
	const source = fs.readFileSync(filename, 'utf8');
	const dependencies = {
		view: { extend: function(properties) { return properties; } },
		form: { Map: Map, NamedSection: NamedSection, Flag: Flag, Value: Value },
		uci: {},
		ui: {},
		'routepolicy/api': {},
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
	return factory({}, {}, {}, function() {}, function(value) { return value; }, ...instances);
}

const repo = path.resolve(__dirname, '../..');
const settings = loadView(path.join(
	repo,
	'luci-app-routepolicy/htdocs/luci-static/resources/view/routepolicy/settings.js'
));

assert.strictEqual(settings.render(), 'rendered');
assert.deepStrictEqual(
	renderedOptions.filter(function(option) { return option instanceof NetworkSelect; }).map(function(option) { return option.option; }),
	[ 'lan_interface', 'default_interface', 'policy_interface' ]
);

console.log('LuCI view render contract passed.');
