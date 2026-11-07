'use strict';

const assert = require('assert');
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const repo = path.resolve(__dirname, '../..');
const makefile = fs.readFileSync(path.join(repo, 'luci-app-routepolicy/Makefile'), 'utf8');

function hookDefinition(hook) {
	const match = makefile.match(
		new RegExp('define Package/\\$\\(PKG_NAME\\)/' + hook + '\\s*\\r?\\n([\\s\\S]*?)\\r?\\nendef')
	);
	assert.ok(match,
		'the package must own its ' + hook + ' lifecycle instead of relying on best-effort framework defaults');
	return match[1];
}

/* The build system expands the hook through make before emitting the package
 * control script, so every shell dollar sign is doubled in the Makefile. */
function emittedHook(hook) {
	return hookDefinition(hook).replace(/\$\$/g, '$').replace(/\r\n/g, '\n');
}

const postinst = hookDefinition('postinst');
const postrm = hookDefinition('postrm');

assert.match(postinst, /IPKG_INSTROOT/,
	'the install lifecycle must not touch services while building an image root');
assert.match(postinst, /rm -f \/tmp\/luci-indexcache\.\*/,
	'the install lifecycle must invalidate the LuCI server index cache');
assert.match(postinst, /rm -rf \/tmp\/luci-modulecache\//,
	'the install lifecycle must invalidate the LuCI server module cache');
assert.match(postinst, /if ! \/etc\/init\.d\/rpcd restart; then\s+exit 1\s+fi/,
	'rpcd restart failure must immediately fail the package script before any stale object can satisfy wait_for');
assert.match(postinst, /ubus -t 10 wait_for routepolicy/,
	'the package script must wait for the public routepolicy object before reporting success');

assert.match(postrm, /IPKG_INSTROOT/,
	'the removal lifecycle must not touch services while building an image root');
assert.match(postrm, /PKG_UPGRADE/,
	'an upgrade reinstall must leave rpcd reconciliation to the incoming postinst');
assert.match(postrm, /rm -f \/tmp\/luci-indexcache\.\*/,
	'the removal lifecycle must invalidate the LuCI server index cache');
assert.match(postrm, /rm -rf \/tmp\/luci-modulecache\//,
	'the removal lifecycle must invalidate the LuCI server module cache');
assert.match(postrm, /if ! \/etc\/init\.d\/rpcd restart; then\s+exit 1\s+fi/,
	'rpcd restart failure must fail the removal instead of leaving a stale object registered');
assert.match(postrm, /ubus -t 10 wait_for rc/,
	'removal must wait for the native rpcd rc object to prove rpcd is healthy again');
assert.match(postrm, /grep -qx routepolicy/,
	'removal must detect a resident routepolicy object instead of assuming file deletion unregisters it');
assert.doesNotMatch(postrm, /\buci\b|dnsmasq|smartdns|\bdhcp\b|\/etc\/config|\/etc\/routepolicy/i,
	'removal may only reconcile LuCI caches and the rpcd object; user configuration and DNS/DHCP services stay untouched');

/*
 * Behaviour section: execute the emitted hooks in a sandbox against fake
 * /etc/init.d/rpcd and ubus commands, so offline, upgrade, restart-failure,
 * ubus-failure and object-residue outcomes are observed rather than restated.
 * Only absolute on-device paths are rewritten to sandbox-relative ones.
 */
function resolvePosixSh() {
	const probe = spawnSync('sh', ['-c', 'exit 0'], { timeout: 10000 });
	if (probe.status === 0)
		return 'sh';
	const candidates = process.platform === 'win32' ? [
		path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'usr', 'bin', 'sh.exe'),
		path.join(process.env['ProgramFiles(x86)'] || '', 'Git', 'usr', 'bin', 'sh.exe'),
		path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Git', 'usr', 'bin', 'sh.exe')
	] : ['/bin/sh', '/usr/bin/sh'];
	for (const candidate of candidates)
		if (candidate && fs.existsSync(candidate))
			return candidate;
	throw new Error('a POSIX sh is required to execute the package lifecycle hooks');
}

const sh = resolvePosixSh();
const sandboxRoot = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'routepolicy-lifecycle-'));

const fakeUbus = [
	'#!/bin/sh',
	'printf \'%s\\n\' "$*" >>"$UBUS_LOG"',
	'case "$1" in',
	'list)',
	'\tif [ "${UBUS_LIST_EXIT:-0}" -ne 0 ]; then',
	'\t\techo \'Connection error\' >&2',
	'\t\texit "${UBUS_LIST_EXIT}"',
	'\tfi',
	'\tfor object in ${UBUS_OBJECTS:-rc}; do printf \'%s\\n\' "$object"; done',
	'\texit 0',
	'\t;;',
	'esac',
	'case "$*" in',
	'*wait_for*)',
	'\tif [ "${UBUS_WAIT_EXIT:-0}" -ne 0 ]; then',
	'\t\techo \'Connection error\' >&2',
	'\t\texit "${UBUS_WAIT_EXIT}"',
	'\tfi',
	'\texit 0',
	'\t;;',
	'esac',
	'exit 1',
	''
].join('\n');

const fakeRpcd = [
	'#!/bin/sh',
	'printf \'%s\\n\' "$*" >>"$RPCD_LOG"',
	'exit "${RPCD_EXIT:-0}"',
	''
].join('\n');

function writeExecutable(file, content) {
	fs.writeFileSync(file, content);
	fs.chmodSync(file, 0o755);
}

function sandboxedHook(hook) {
	let script = emittedHook(hook);
	for (const [absolute, relative] of [
		['/etc/init.d/rpcd', 'etc/init.d/rpcd'],
		['/tmp/luci-indexcache.*', 'tmp/luci-indexcache.*'],
		['/tmp/luci-modulecache/', 'tmp/luci-modulecache/']
	]) {
		const occurrences = script.split(absolute).length - 1;
		assert.strictEqual(occurrences, 1,
			'the ' + hook + ' hook must reference ' + absolute + ' exactly once for sandboxed execution');
		script = script.split(absolute).join(relative);
	}
	return script;
}

function readInvocations(file) {
	try {
		return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
	} catch (error) {
		return [];
	}
}

function executeHook(hook, scenario, scenarioEnv) {
	const sandbox = path.join(sandboxRoot, hook + '-' + scenario);
	fs.rmSync(sandbox, { recursive: true, force: true });
	fs.mkdirSync(path.join(sandbox, 'bin'), { recursive: true });
	fs.mkdirSync(path.join(sandbox, 'etc', 'init.d'), { recursive: true });
	fs.mkdirSync(path.join(sandbox, 'tmp', 'luci-modulecache'), { recursive: true });
	writeExecutable(path.join(sandbox, 'bin', 'ubus'), fakeUbus);
	writeExecutable(path.join(sandbox, 'etc', 'init.d', 'rpcd'), fakeRpcd);
	fs.writeFileSync(path.join(sandbox, 'tmp', 'luci-indexcache.000001'), 'stale index cache\n');
	fs.writeFileSync(path.join(sandbox, 'tmp', 'luci-modulecache', 'stale-module'), 'stale module cache\n');
	fs.writeFileSync(path.join(sandbox, hook), sandboxedHook(hook));

	const sandboxBin = path.join(sandbox, 'bin').split(path.sep).join('/');
	const environment = {
		PATH: sandboxBin + path.delimiter +
			(process.platform === 'win32' ? path.dirname(sh) + path.delimiter : '') +
			(process.env.PATH || ''),
		UBUS_LOG: path.join(sandbox, 'ubus.log').split(path.sep).join('/'),
		RPCD_LOG: path.join(sandbox, 'rpcd.log').split(path.sep).join('/')
	};
	if (process.platform === 'win32') {
		environment.SYSTEMROOT = process.env.SystemRoot;
		environment.TEMP = os.tmpdir();
		environment.TMP = os.tmpdir();
	}
	Object.assign(environment, scenarioEnv);

	const execution = spawnSync(sh, [hook], { cwd: sandbox, env: environment, encoding: 'utf8', timeout: 30000 });
	return {
		exitStatus: execution.status,
		output: (execution.stdout || '') + (execution.stderr || ''),
		rpcdInvocations: readInvocations(path.join(sandbox, 'rpcd.log')),
		ubusInvocations: readInvocations(path.join(sandbox, 'ubus.log')),
		indexCacheCleared: !fs.existsSync(path.join(sandbox, 'tmp', 'luci-indexcache.000001')),
		moduleCacheCleared: !fs.existsSync(path.join(sandbox, 'tmp', 'luci-modulecache'))
	};
}

let outcome;
try {
	/* Install-side behaviour must not regress while fixing removal. */
	outcome = executeHook('postinst', 'offline-image-root', { IPKG_INSTROOT: '/imagebuilder/root' });
	assert.strictEqual(outcome.exitStatus, 0, 'offline image installs must succeed without touching the host');
	assert.deepStrictEqual(outcome.rpcdInvocations, [], 'offline image installs must not restart host rpcd');
	assert.deepStrictEqual(outcome.ubusInvocations, [], 'offline image installs must not query host ubus');
	assert.strictEqual(outcome.indexCacheCleared || outcome.moduleCacheCleared, false,
		'offline image installs must not modify files inside the image root');

	outcome = executeHook('postinst', 'install', {});
	assert.strictEqual(outcome.exitStatus, 0, 'a healthy install must succeed');
	assert.strictEqual(outcome.indexCacheCleared && outcome.moduleCacheCleared, true,
		'install must clear the LuCI caches');
	assert.deepStrictEqual(outcome.rpcdInvocations, ['restart'], 'install must reconcile rpcd through its init script');
	assert.deepStrictEqual(outcome.ubusInvocations, ['-t 10 wait_for routepolicy'],
		'install must wait for the routepolicy object');

	outcome = executeHook('postinst', 'upgrade-reinstall', { PKG_UPGRADE: '1' });
	assert.strictEqual(outcome.exitStatus, 0, 'an upgrade reinstall must succeed through the existing postinst');
	assert.deepStrictEqual(outcome.rpcdInvocations, ['restart'], 'upgrade reinstalls must still reconcile rpcd exactly once');
	assert.deepStrictEqual(outcome.ubusInvocations, ['-t 10 wait_for routepolicy'],
		'upgrade reinstalls must still wait for the routepolicy object');

	outcome = executeHook('postinst', 'rpcd-restart-failure', { RPCD_EXIT: '3' });
	assert.strictEqual(outcome.exitStatus, 1, 'install must fail loudly when rpcd cannot restart');
	assert.deepStrictEqual(outcome.ubusInvocations, [], 'a failed rpcd restart must not be masked by wait_for');

	/* Removal-side behaviour: the fix under test. */
	outcome = executeHook('postrm', 'offline-image-root', { IPKG_INSTROOT: '/imagebuilder/root' });
	assert.strictEqual(outcome.exitStatus, 0, 'offline image removals must succeed without touching the host');
	assert.deepStrictEqual(outcome.rpcdInvocations, [], 'offline image removals must not restart host rpcd');
	assert.deepStrictEqual(outcome.ubusInvocations, [], 'offline image removals must not query host ubus');
	assert.strictEqual(outcome.indexCacheCleared || outcome.moduleCacheCleared, false,
		'offline image removals must not modify files inside the image root');

	outcome = executeHook('postrm', 'upgrade-reinstall', { PKG_UPGRADE: '1' });
	assert.strictEqual(outcome.exitStatus, 0, 'an upgrade removal must succeed without interfering with the incoming postinst');
	assert.deepStrictEqual(outcome.rpcdInvocations, [], 'upgrade removals must not restart rpcd a second time');
	assert.deepStrictEqual(outcome.ubusInvocations, [], 'upgrade removals must not probe ubus');
	assert.strictEqual(outcome.indexCacheCleared || outcome.moduleCacheCleared, false,
		'upgrade removals must leave cache maintenance to the incoming postinst');

	outcome = executeHook('postrm', 'healthy-removal', {});
	assert.strictEqual(outcome.exitStatus, 0, 'a healthy removal must succeed');
	assert.strictEqual(outcome.indexCacheCleared && outcome.moduleCacheCleared, true,
		'removal must clear the same LuCI caches as install');
	assert.deepStrictEqual(outcome.rpcdInvocations, ['restart'], 'removal must reconcile rpcd through its init script');
	assert.deepStrictEqual(outcome.ubusInvocations, ['-t 10 wait_for rc', 'list'],
		'removal must prove rpcd health before proving the routepolicy object is gone');

	outcome = executeHook('postrm', 'rpcd-restart-failure', { RPCD_EXIT: '3' });
	assert.strictEqual(outcome.exitStatus, 1, 'removal must fail loudly when rpcd cannot restart');
	assert.deepStrictEqual(outcome.ubusInvocations, [], 'a failed rpcd restart must not be followed by object probing');

	outcome = executeHook('postrm', 'rpcd-not-returning', { UBUS_WAIT_EXIT: '1' });
	assert.strictEqual(outcome.exitStatus, 1,
		'an ubus that cannot confirm rpcd recovery must fail the removal');

	outcome = executeHook('postrm', 'ubus-list-connection-failure', { UBUS_LIST_EXIT: '1' });
	assert.strictEqual(outcome.exitStatus, 1,
		'ubus connection failure must never be interpreted as the object being gone');
	assert.deepStrictEqual(outcome.ubusInvocations, ['-t 10 wait_for rc', 'list']);

	outcome = executeHook('postrm', 'object-residue', { UBUS_OBJECTS: 'rc routepolicy' });
	assert.strictEqual(outcome.exitStatus, 1,
		'a routepolicy object surviving the restart must fail the removal');
	assert.deepStrictEqual(outcome.ubusInvocations, ['-t 10 wait_for rc', 'list']);
} finally {
	fs.rmSync(sandboxRoot, { recursive: true, force: true });
}

console.log('LuCI package lifecycle contract passed.');
