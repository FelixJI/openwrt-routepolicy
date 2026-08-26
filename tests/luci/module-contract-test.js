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

function loadModule(name, filename) {
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

	const factory = new Function('window', 'document', 'L', ...aliases, source);
	const constructor = factory({}, {}, {}, ...instances);

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

console.log('LuCI module constructor contract passed.');
