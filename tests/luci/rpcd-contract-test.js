'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..', '..');
const pluginPath = path.join(root, 'luci-app-routepolicy', 'root', 'usr', 'share', 'rpcd', 'ucode', 'routepolicy');
const legacyPath = path.join(root, 'luci-app-routepolicy', 'root', 'usr', 'libexec', 'rpcd', 'routepolicy');
const expectedMethods = [
	'apply', 'diagnose', 'import_legacy', 'read_local_hosts', 'read_user_list', 'reload', 'rollback',
	'smartdns_apply', 'smartdns_discard_candidate', 'smartdns_save', 'smartdns_status', 'smartdns_validate',
	'status', 'update', 'validate', 'write_local_hosts', 'write_user_list'
];

assert.ok(fs.existsSync(pluginPath), 'rpcd ucode plugin must be installed under /usr/share/rpcd/ucode');
assert.ok(!fs.existsSync(legacyPath), 'legacy /usr/libexec/rpcd plugin must not remain in the package');

let source = fs.readFileSync(pluginPath, 'utf8')
	.replace(/^#![^\n]*\n/, '')
	.replace(/^import\s+\{\s*popen\s*\}\s+from\s+'fs';\s*$/m, '')
	/* ucode iterates array values with `in`; JavaScript uses `of`. */
	.replace('for (let raw in split(content, /\\r?\\n/))', 'for (let raw of split(content, /\\r?\\n/))');

const calls = [];
function popen(argv, mode) {
	const proc = {
		read() {
			if (argv.includes('status'))
				return '{"ok":true,"message":"status ok"}';
			if (argv.includes('user-list'))
				return '{"ok":true,"content":"example.com\\n"}';
			if (argv.includes('restart'))
				return '停用清理完成：已删除 RoutePolicy 自有状态\nRoutePolicy 未启用；已跳过应用并保持停用\n';
			return '';
		},
		write(content) {
			calls.push({ argv, mode, content });
			return content.length;
		},
		close() { return 0; }
	};
	calls.push({ argv, mode });
	return proc;
}

const signature = new Function(
	'popen', 'type', 'length', 'split', 'trim', 'match', 'lc', 'json', 'push', 'join',
	source
)(
	popen,
	value => Array.isArray(value) ? 'array' : value === null ? 'null' : typeof value,
	value => value.length,
	(value, separator) => value.split(separator),
	value => value.trim(),
	(value, expression) => value.match(expression),
	value => value.toLowerCase(),
	JSON.parse,
	(array, value) => array.push(value),
	(separator, array) => array.join(separator)
);

assert.ok(signature && typeof signature === 'object', 'ucode plugin must return a signature dictionary');
assert.deepStrictEqual(Object.keys(signature), [ 'routepolicy' ], 'signature must expose exactly the routepolicy ubus object');

const routepolicy = signature.routepolicy;
assert.deepStrictEqual(Object.keys(routepolicy).sort(), expectedMethods.slice().sort(), 'routepolicy object method set changed');
for (const name of expectedMethods) {
	assert.ok(routepolicy[name] && typeof routepolicy[name].call === 'function', name + ' must expose a callable handler');
	assert.ok(routepolicy[name].args && typeof routepolicy[name].args === 'object', name + ' must declare an argument dictionary');
}

assert.deepStrictEqual(routepolicy.status.call({ args: {} }), { ok: true, message: 'status ok' });
assert.deepStrictEqual(routepolicy.read_user_list.call({ args: { list: 'domain-policy' } }), {
	ok: true,
	content: 'example.com\n'
});
assert.deepStrictEqual(routepolicy.smartdns_save.call({ args: { content: 'enabled\t1\n' } }), {
	ok: true,
	message: 'SmartDNS 候选已保存'
});
assert.ok(calls.some(call => call.mode === 'w' && call.content === 'enabled\t1\n'), 'write handler must consume request.args.content');
assert.deepStrictEqual(routepolicy.write_local_hosts.call({ args: { content: 'router.lan 192.0.2.1\n' } }), {
	ok: true,
	message: '本地主机候选已保存'
});
assert.deepStrictEqual(routepolicy.write_user_list.call({ args: {
	list: 'domain-policy',
	content: 'Example.COM\nexample.com\n'
} }), {
	ok: true,
	message: '规则校验通过',
	valid: [ 'example.com' ],
	valid_count: 1,
	duplicate_count: 1,
	invalid_count: 0,
	invalid: []
});
assert.strictEqual(
	routepolicy.apply.call({ args: {} }).message,
	'停用清理完成：已删除 RoutePolicy 自有状态\nRoutePolicy 未启用；已跳过应用并保持停用',
	'RPC lifecycle response must preserve the concrete init-script result'
);

console.log('rpcd ucode registration contract passed.');
