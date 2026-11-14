'use strict';

import { mkstemp, readfile } from 'fs';

const tree = './luci-app-routepolicy/root/usr/share/';
const menu = json(readfile(tree + 'luci/menu.d/luci-app-routepolicy-confirm.json'));
const route = menu['admin/services/routepolicy/confirm'];
assert(route.action.post === true && route.depends.acl[0] == 'luci-app-routepolicy',
	'confirmation must pass the LuCI dispatcher POST, CSRF and read ACL gates');
const acl = json(readfile(tree + 'rpcd/acl.d/luci-app-routepolicy.json'))['luci-app-routepolicy'];
assert(length(acl.write.uci) == 1 && acl.write.uci[0] == 'routepolicy');
assert('init_discover' in acl.read.ubus.routepolicy && 'init_status' in acl.read.ubus.routepolicy);
assert(!('init_prepare' in acl.read.ubus.routepolicy) && !('init_apply' in acl.read.ubus.routepolicy));
assert(!('init_cancel' in acl.read.ubus.routepolicy) && !('init_finish' in acl.read.ubus.routepolicy));
assert('init_cancel' in acl.write.ubus.routepolicy && 'init_finish' in acl.write.ubus.routepolicy);

const controller = loadfile(tree + 'ucode/luci/controller/routepolicy.uc', { raw_mode: true })();
const token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
let calls = 0;
let reply;
let status;

const rpcd = loadfile(tree + 'rpcd/ucode/routepolicy', { raw_mode: true })().routepolicy;
for (let method in ['config_import', 'restore_prepare', 'init_preview', 'init_prepare', 'init_apply',
	'init_cancel', 'init_finish', 'init_confirm', 'exit_apply']) {
	reply = rpcd[method].call({ args: { content: 1, token: 'invalid' } });
	assert(reply.ok === false && reply.message == '生命周期输入类型、长度或 token 非法',
		method + ' must return a structured rejection through the installed rpcd signature');
}
reply = rpcd.init_confirm.call({ args: { token } });
assert(reply.ok === false && reply.state == 'trusted_confirmation_required');

function request(session, access, address, submitted_token) {
	status = 200;
	let env = {
		ctx: { authsession: session, authacl: { 'access-group': { 'luci-app-routepolicy': access } } },
		http: {
			formvalue: function(name) {
				assert(name == 'transaction_token', 'controller must never read a claimed address');
				return submitted_token;
			},
			getenv: function(name) {
				assert(name == 'SERVER_ADDR' || name == 'SERVER_SOFTWARE', 'controller must ignore HTTP headers');
				return name == 'SERVER_ADDR' ? address : 'uhttpd';
			},
			status: function(code) { status = code; },
			header: function() {},
			prepare_content: function() {},
			write_json: function(payload) { reply = payload; }
		},
		require: function(name) {
			assert(name == 'routepolicy.lifecycle');
			return { call_core: function(command, content) {
				calls++;
				assert(command == '/usr/sbin/routepolicyctl web-init-confirm --json');
				assert(content == token + '\t192.0.2.2', 'only the local socket address enters the confirmation request');
				return { ok: true };
			} };
		}
	};
	call(controller.confirm, controller, env);
}

request(null, ['read', 'write'], '192.0.2.2', token);
assert(status == 403 && !reply.ok && calls == 0);
request('read-only-session', ['read'], '192.0.2.2', token);
assert(status == 403 && !reply.ok && calls == 0);
request('writer-session', ['write'], null, token);
assert(status == 400 && !reply.ok && calls == 0);
request('writer-session', ['write'], '192.0.2.2', 'invalid');
assert(status == 400 && !reply.ok && calls == 0);
request('writer-session', ['write'], '192.0.2.2', token);
assert(status == 200 && reply.ok && calls == 1);

const adapter = loadfile(tree + 'ucode/routepolicy/lifecycle.uc', { raw_mode: true })();
const command = 'ROUTEPOLICY_LIBEXEC=./routepolicy/files/usr/libexec/routepolicy ./routepolicy/files/usr/sbin/routepolicyctl web-init-preview --json';
const held = [];
for (let i = 0; i < 12; i++) push(held, mkstemp());
reply = adapter.call_core(command, 'invalid');
assert(reply.ok === false && reply.error == '初始化请求需要 13 个非空白名单字段',
	'core validation must return structured data through independent anonymous descriptors');
reply = adapter.call_core(command, 'invalid\x00');
assert(reply.ok === false && reply.error == '请求包含非法控制字符', 'the shell boundary must reject NUL');
for (let operation in ['web-init-cancel', 'web-init-finish']) {
	const fixed = 'ROUTEPOLICY_LIBEXEC=./routepolicy/files/usr/libexec/routepolicy ./routepolicy/files/usr/sbin/routepolicyctl ' + operation + ' --json';
	reply = adapter.call_core(fixed, 'invalid');
	assert(reply.ok === false && reply.error == 'token 非法');
}
for (let i = 0; i < length(held); i++) held[i].close();
print('LuCI lifecycle backend contract passed.\n');
