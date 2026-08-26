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
const fixedCommands = new Set([
	'/usr/sbin/routepolicyctl status --json',
	'/usr/sbin/routepolicyctl validate --json',
	'/etc/init.d/routepolicy restart',
	'/usr/sbin/routepolicyctl update --json',
	'/usr/sbin/routepolicyctl rollback --json',
	'/usr/sbin/routepolicyctl diagnose --json',
	'/usr/sbin/routepolicyctl smartdns-status --json',
	'/usr/sbin/routepolicyctl smartdns-save --json',
	'/usr/sbin/routepolicyctl smartdns-validate --json',
	'/usr/sbin/routepolicyctl smartdns-apply --json',
	'/usr/sbin/routepolicyctl smartdns-discard --json',
	'/usr/sbin/routepolicyctl smartdns-read-local-hosts --json',
	'/usr/sbin/routepolicyctl smartdns-write-local-hosts --json',
	'/usr/sbin/routepolicyctl import-legacy /etc/splitroute --json',
	...['domain-policy', 'domain-default', 'ipv4-policy', 'ipv4-default'].flatMap(kind => [
		`/usr/sbin/routepolicyctl user-list read ${kind} --json`,
		`/usr/sbin/routepolicyctl user-list write ${kind} --json`
	])
]);

assert.ok(fs.existsSync(pluginPath), 'rpcd ucode plugin must be installed under /usr/share/rpcd/ucode');
assert.ok(!fs.existsSync(legacyPath), 'legacy /usr/libexec/rpcd plugin must not remain in the package');

let source = fs.readFileSync(pluginPath, 'utf8')
	.replace(/^#![^\n]*\n/, '')
	.replace(/^import\s+\{\s*popen\s*\}\s+from\s+'fs';\s*$/m, '')
	/* ucode iterates array values with `in`; JavaScript uses `of`. */
	.replace('for (let raw in split(content, /\\r?\\n/))', 'for (let raw of split(content, /\\r?\\n/))');

const calls = [];
/* OpenWrt 25.12 pins a ucode fs.popen() implementation that accepts strings only. */
function popen(command, mode) {
	if (typeof command !== 'string')
		return null;

	let writtenContent = null;
	const proc = {
		read() {
			if (command.includes('user-list read'))
				return '{"ok":true,"content":"example.com\\n"}';
			if (command.includes('restart'))
				return '停用清理完成：已删除 RoutePolicy 自有状态\nRoutePolicy 未启用；已跳过应用并保持停用\n';
			if (command.includes('diagnose'))
				return 'not-json';
			return '{"ok":true,"message":"command ok"}';
		},
		write(content) {
			writtenContent = content;
			calls.push({ command, mode, content });
			if (content === 'partial-write')
				return content.length - 1;
			return content.length;
		},
		close() {
			if (command.includes('diagnose') || writtenContent === 'reject-write')
				return 7;
			return 0;
		}
	};
	calls.push({ command, mode });
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

for (const name of [
	'status', 'validate', 'update', 'rollback', 'smartdns_status', 'smartdns_validate',
	'smartdns_apply', 'smartdns_discard_candidate', 'read_local_hosts', 'import_legacy'
]) {
	assert.strictEqual(routepolicy[name].call({ args: {} }).ok, true, name + ' must execute through fixed string popen');
}
assert.deepStrictEqual(routepolicy.diagnose.call({ args: {} }), {
	output: 'not-json',
	ok: false,
	message: 'RoutePolicy 控制程序执行失败'
});
assert.deepStrictEqual(routepolicy.read_user_list.call({ args: { list: 'domain-policy' } }), {
	ok: true,
	content: 'example.com\n'
});
const stdinSentinel = "enabled\t'; touch /tmp/routepolicy-rpc-injection; #\n";
assert.deepStrictEqual(routepolicy.smartdns_save.call({ args: { content: stdinSentinel } }), {
	ok: true,
	message: 'SmartDNS 候选已保存'
});
assert.ok(calls.some(call => call.mode === 'w' && call.content === stdinSentinel), 'write handler must consume request.args.content');
assert.ok(calls.every(call => !call.command.includes(stdinSentinel)), 'request content must never enter a shell command');
assert.deepStrictEqual(routepolicy.write_local_hosts.call({ args: { content: 'router.lan 192.0.2.1\n' } }), {
	ok: true,
	message: '本地主机候选已保存'
});
assert.deepStrictEqual(routepolicy.smartdns_save.call({ args: { content: 'partial-write' } }), {
	ok: false,
	message: '向核心事务层传递候选失败'
});
assert.deepStrictEqual(routepolicy.write_local_hosts.call({ args: { content: 'reject-write' } }), {
	ok: false,
	message: '核心事务层拒绝候选'
});
const callsBeforeRejectedList = calls.length;
assert.deepStrictEqual(routepolicy.read_user_list.call({ args: { list: 'domain-policy; id' } }), {
	ok: false,
	message: '未知的人工规则类型'
});
assert.strictEqual(calls.length, callsBeforeRejectedList, 'unknown list names must be rejected before popen');
assert.deepStrictEqual(routepolicy.smartdns_save.call({ args: { content: 'x'.repeat(262145) } }), {
	ok: false,
	message: '候选内容必须是小于 256 KiB 的文本'
});
assert.deepStrictEqual(routepolicy.write_user_list.call({ args: {
	list: 'domain-policy',
	content: 'Example.COM\nexample.com\n'
} }), {
	ok: true,
	message: '人工规则已保存；RoutePolicy 启用时需重新应用配置后进入运行态',
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
assert.strictEqual(routepolicy.reload.call({ args: {} }).ok, true, 'reload must use the same fixed lifecycle command');
assert.ok(calls.length > 0, 'contract must exercise the process adapter');
for (const call of calls) {
	assert.strictEqual(typeof call.command, 'string', 'OpenWrt 25.12 popen command must be a string');
	assert.ok(fixedCommands.has(call.command), `unexpected shell command: ${call.command}`);
}

console.log('rpcd ucode registration contract passed.');
