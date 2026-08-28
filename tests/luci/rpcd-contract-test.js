'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..', '..');
const pluginPath = path.join(root, 'luci-app-routepolicy', 'root', 'usr', 'share', 'rpcd', 'ucode', 'routepolicy');
const rulesViewPath = path.join(root, 'luci-app-routepolicy', 'htdocs', 'luci-static', 'resources', 'view', 'routepolicy', 'rules.js');
const converterPath = path.join(root, 'routepolicy', 'files', 'usr', 'libexec', 'routepolicy', 'converter-lib');
const legacyPath = path.join(root, 'luci-app-routepolicy', 'root', 'usr', 'libexec', 'rpcd', 'routepolicy');
const expectedMethods = [
	'apply', 'diagnose', 'import_legacy', 'read_local_hosts', 'read_user_list', 'reload', 'rollback',
	'observe_interfaces', 'observe_query', 'observe_sets',
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
	'/usr/sbin/routepolicyctl observe-interfaces --json',
	'/usr/sbin/routepolicyctl observe-sets --json',
	'/usr/sbin/routepolicyctl observe-export-domain-policy --json',
	'/usr/sbin/routepolicyctl observe-export-domain-default --json',
	'/usr/sbin/routepolicyctl observe-export-static-policy4 --json',
	'/usr/sbin/routepolicyctl observe-export-static-default4 --json',
	'/usr/sbin/routepolicyctl observe-export-dynamic-policy4 --json',
	'/usr/sbin/routepolicyctl observe-export-dynamic-default4 --json',
	'/usr/sbin/routepolicyctl observe-export-source-ingress4-address --json',
	'/usr/sbin/routepolicyctl observe-export-source-ingress4-bytes --json',
	'/usr/sbin/routepolicyctl observe-export-source-ingress4-packets --json',
	'/usr/sbin/routepolicyctl observe-export-source-egress4-address --json',
	'/usr/sbin/routepolicyctl observe-export-source-egress4-bytes --json',
	'/usr/sbin/routepolicyctl observe-export-source-egress4-packets --json',
	...['domain-policy', 'domain-default', 'ipv4-policy', 'ipv4-default'].flatMap(kind => [
		`/usr/sbin/routepolicyctl user-list read ${kind} --json`,
		`/usr/sbin/routepolicyctl user-list write ${kind} --json`
	])
]);

assert.ok(fs.existsSync(pluginPath), 'rpcd ucode plugin must be installed under /usr/share/rpcd/ucode');
assert.ok(!fs.existsSync(legacyPath), 'legacy /usr/libexec/rpcd plugin must not remain in the package');

function declaredReservedRanges(text) {
	const body = text.match(/const RESERVED_IPV4_RANGES = \[([\s\S]*?)\];/);
	assert.ok(body, 'reserved IPv4 range declaration is missing');
	return Array.from(body[1].matchAll(/\[\s*(\d+)\s*,\s*(\d+)\s*\]/g), match => [ Number(match[1]), Number(match[2]) ]);
}

const coreReservedRanges = Array.from(
	fs.readFileSync(converterPath, 'utf8').matchAll(/if\(overlap\(a,b,(\d+),(\d+)\)\)/g),
	match => [ Number(match[1]), Number(match[2]) ]
);
assert.deepStrictEqual(declaredReservedRanges(fs.readFileSync(pluginPath, 'utf8')), coreReservedRanges,
	'rpcd reserved IPv4 policy must stay aligned with the core converter');
assert.deepStrictEqual(declaredReservedRanges(fs.readFileSync(rulesViewPath, 'utf8')), coreReservedRanges,
	'LuCI reserved IPv4 policy must stay aligned with the core converter');

let source = fs.readFileSync(pluginPath, 'utf8')
	.replace(/^#![^\n]*\n/, '')
	.replace(/^import\s+\{\s*popen\s*\}\s+from\s+'fs';\s*$/m, '')
	/* ucode iterates array values with `in`; JavaScript uses `of`. */
	.replace('for (let raw in split(content, /\\r?\\n/))', 'for (let raw of split(content, /\\r?\\n/))')
	.replace('for (let value in values)', 'for (let value of values)')
	.replace('for (let item in payload.items)', 'for (let item of payload.items)');

assert.ok(!/\.length\b/.test(source),
	'ucode collections must use length(value); JavaScript-style .length triggers a target runtime exception');
assert.ok(!/\bline\[0\]/.test(source),
	'ucode strings must use substr(); JavaScript-style string indexing triggers a target runtime exception');
assert.ok(!source.includes('(?:'),
	'ucode runtime regular expressions must not use JavaScript non-capturing groups');

const calls = [];
let observeGeneration = 'g1';
/* OpenWrt 25.12 pins a ucode fs.popen() implementation that accepts strings only. */
function popen(command, mode) {
	if (typeof command !== 'string')
		return null;

	let writtenContent = null;
	const proc = {
		read() {
			if (command.includes('observe-export-domain-policy'))
				return JSON.stringify({ ok: true, dataset: 'domain_policy', generation: observeGeneration, volatile: false, truncated: false, enabled: true, devices: [ 'br-lan' ], items: [ { domain: 'Example.COM', target: 'policy' }, { domain: 'sub.example.com', target: 'policy' } ] });
			if (command.includes('observe-export-source-ingress4'))
				return JSON.stringify({ ok: true, dataset: 'source_ingress4', generation: 'g1', volatile: true, truncated: false, enabled: true, devices: [ 'br-lan' ], items: [ { device: 'br-lan', address: '192.168.1.2', packets: '7', bytes: '9007199254740993', expires: '42' } ] });
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
	'popen', 'type', 'length', 'split', 'trim', 'substr', 'match', 'lc', 'json', 'push', 'join', 'index',
	source
)(
	popen,
	value => Array.isArray(value) ? 'array' : value === null ? 'null' : typeof value,
	value => value.length,
	(value, separator) => value.split(separator),
	value => value.trim(),
	(value, start, count) => value.slice(start, start + count),
	(value, expression) => value.match(expression),
	value => value.toLowerCase(),
	JSON.parse,
	(array, value) => array.push(value),
	(separator, array) => array.join(separator),
	(value, needle) => value.indexOf(needle)
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
	'smartdns_apply', 'smartdns_discard_candidate', 'read_local_hosts', 'import_legacy',
	'observe_interfaces', 'observe_sets'
]) {
	assert.strictEqual(routepolicy[name].call({ args: {} }).ok, true, name + ' must execute through fixed string popen');
}
assert.deepStrictEqual(routepolicy.observe_query.call({ args: {
	dataset: 'domain_policy', query: 'example', limit: 1, sort: 'domain'
} }), {
	ok: true,
	dataset: 'domain_policy',
	items: [ { domain: 'Example.COM', target: 'policy' } ],
	next_cursor: 'v1:domain_policy:g1:1',
	total_matched: 2,
	generation: 'g1',
	enabled: true,
	volatile: false,
	truncated: false
});
assert.deepStrictEqual(routepolicy.observe_query.call({ args: {
	dataset: 'domain_policy', query: 'example', cursor: 'v1:domain_policy:g1:1', limit: 1, sort: 'domain'
} }).items, [ { domain: 'sub.example.com', target: 'policy' } ]);
observeGeneration = 'unavailable';
const unavailableReply = routepolicy.observe_query.call({ args: {
	dataset: 'domain_policy', query: 'example', limit: 1, sort: 'domain'
} });
assert.strictEqual(unavailableReply.next_cursor, null,
	'a missing active generation must not issue a reusable cursor');
assert.strictEqual(unavailableReply.truncated, true,
	'a missing active generation must report undisplayable continuation as truncated');
const callsBeforeUnavailableCursor = calls.length;
assert.strictEqual(routepolicy.observe_query.call({ args: {
	dataset: 'domain_policy', cursor: 'v1:domain_policy:unavailable:1', limit: 1, sort: 'domain'
} }).ok, false, 'an unavailable-generation cursor must be rejected');
assert.strictEqual(calls.length, callsBeforeUnavailableCursor,
	'an unavailable-generation cursor must be rejected before popen');
observeGeneration = 'g1';
assert.strictEqual(routepolicy.observe_query.call({ args: {
	dataset: 'source_ingress4', device: 'br-lan', sort: 'bytes', limit: 50
} }).items[0].bytes, '9007199254740993', '64-bit decimal counters must remain strings');
const callsBeforeObserveRejections = calls.length;
for (const args of [
	{ dataset: 'source_ingress4; reboot', limit: 50 },
	{ dataset: 'domain_policy', query: "'; reboot #", limit: 50 },
	{ dataset: 'source_ingress4', query: '1.2.3.4\nreboot', limit: 50 },
	{ dataset: 'source_ingress4', device: '../../sys', limit: 50 },
	{ dataset: 'source_ingress4', limit: 201 },
	{ dataset: 'domain_policy', cursor: 'x'.repeat(257), limit: 50 }
])
	assert.strictEqual(routepolicy.observe_query.call({ args }).ok, false, 'unsafe observation request must be rejected');
assert.strictEqual(calls.length, callsBeforeObserveRejections,
	'rejected observation fields must not start a process');
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
const maximumLengthDomain = [ 'a'.repeat(63), 'b'.repeat(63), 'c'.repeat(61), 'd'.repeat(63) ].join('.');
assert.strictEqual(maximumLengthDomain.length, 253);
assert.strictEqual(routepolicy.write_user_list.call({ args: {
	list: 'domain-policy',
	content: maximumLengthDomain + '\n'
} }).ok, true, '253-character domains accepted by the core must remain writable');
const overlongDomain = [ 'a'.repeat(63), 'b'.repeat(63), 'c'.repeat(63), 'd'.repeat(63) ].join('.');
const callsBeforeOverlongDomain = calls.length;
assert.deepStrictEqual(routepolicy.write_user_list.call({ args: {
	list: 'domain-policy',
	content: overlongDomain + '\n'
} }), {
	ok: false,
	message: '发现非法规则，未保存',
	valid: [],
	valid_count: 0,
	duplicate_count: 0,
	invalid_count: 1,
	invalid: [ overlongDomain ]
});
assert.strictEqual(calls.length, callsBeforeOverlongDomain,
	'domains rejected by the core length limit must be rejected before starting a write process');
const callsBeforeReservedIpv4 = calls.length;
for (const value of [
	'0.0.0.0', '10.0.0.1', '100.64.0.1', '127.0.0.1', '169.254.0.1',
	'172.16.0.1', '192.0.0.1', '192.0.2.1', '192.88.99.1', '192.168.1.1',
	'198.18.0.1', '198.51.100.1', '203.0.113.1', '224.0.0.1', '255.255.255.255',
	'8.8.8.8/1'
]) {
	const reply = routepolicy.write_user_list.call({ args: { list: 'ipv4-policy', content: value + '\n' } });
	assert.strictEqual(reply.ok, false, value + ' must be rejected consistently with the core');
	assert.deepStrictEqual(reply.invalid, [ value ]);
}
assert.strictEqual(calls.length, callsBeforeReservedIpv4,
	'IPv4 ranges rejected by the core must be rejected before starting a write process');
assert.strictEqual(routepolicy.write_user_list.call({ args: {
	list: 'ipv4-policy',
	content: '8.8.8.0/24\n'
} }).ok, true, 'public IPv4 CIDRs must remain writable');
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
