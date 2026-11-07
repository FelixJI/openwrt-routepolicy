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
assert.match(postrm, /\/var\/run\/rpcd\/snapshot-files/,
	'removal must conservatively detect the native rpcd snapshot-files state before touching rpcd');
assert.match(postrm, /\/var\/run\/rpcd\/snapshot-delta/,
	'removal must conservatively detect the native rpcd snapshot-delta state before touching rpcd');
assert.match(postrm, /-e "\$\$snap_files"/,
	'removal must treat any existing snapshot path as blocking state');
assert.match(postrm, /-L "\$\$snap_files"/,
	'removal must also treat snapshot symlinks as blocking state');
assert.match(postrm, /rm -f \/tmp\/luci-indexcache\.\*/,
	'the removal lifecycle must invalidate the LuCI server index cache');
assert.match(postrm, /rm -rf \/tmp\/luci-modulecache\//,
	'the removal lifecycle must invalidate the LuCI server module cache');
assert.match(postrm, /ubus -t 2 -v list rc/,
	'removal must read the rpcd rc object id with a short bounded timeout before reloading');
assert.match(postrm, /\*\[!0-9a-fA-F\]\*/,
	'removal must reject non-hexadecimal rc object ids instead of trusting any @-prefixed token');
assert.match(postrm, /\/etc\/init\.d\/rpcd reload/,
	'removal must reconcile the resident rpcd object through the native reload action');
assert.doesNotMatch(postrm, /rpcd restart/,
	'removal must never cold-restart rpcd: restart purges uncommitted UCI session deltas and pending rollback timers');
assert.match(postrm, /ubus -t 10 call uci configs/,
	'removal must confirm the reloaded rpcd event loop answers a read-only uci configs call');
assert.match(postrm, /ubus -t 2 list/,
	'removal must bound the final object listing with a short timeout');
assert.match(postrm, /grep -qx routepolicy/,
	'removal must detect a resident routepolicy object instead of assuming file deletion unregisters it');
assert.doesNotMatch(postrm, /rm\s+(-\w+\s+)*[^\s]*snapshot/,
	'removal must never delete or clean rpcd snapshots or staging directories');
assert.doesNotMatch(postrm, /(^|[;&|(]|&&|\$\()\s*uci\s+(-\S+\s+)*(set|commit|add|delete|revert|import|apply|batch)\b|\/etc\/(config|routepolicy)/,
	'removal must not modify user configuration or DNS/DHCP service state');

/*
 * Behaviour section: execute the emitted hooks in a sandbox against fake
 * /etc/init.d/rpcd and ubus commands, so offline, upgrade, snapshot-blocked,
 * reload-failure, id-stale, health-failure and object-residue outcomes are
 * observed rather than restated. Only absolute on-device paths are rewritten
 * to sandbox-relative ones.
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

function resolveRealGrep(shPath) {
	const candidates = process.platform === 'win32' ? [
		path.join(path.dirname(shPath), 'grep.exe'),
		'C:\\Program Files\\Git\\usr\\bin\\grep.exe'
	] : ['/usr/bin/grep', '/bin/grep'];
	for (const candidate of candidates)
		if (candidate && fs.existsSync(candidate))
			return candidate;
	throw new Error('a real grep is required for the grep-error scenario');
}

const sh = resolvePosixSh();
const realGrep = resolveRealGrep(sh);
const sandboxRoot = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'routepolicy-lifecycle-'));

const fakeUbus = [
	'#!/bin/sh',
	'printf \'%s\\n\' "$*" >>"$UBUS_LOG"',
	'case "$*" in',
	'*" wait_for "*)',
	'\tif [ "${UBUS_WAIT_EXIT:-0}" -ne 0 ]; then',
	'\t\techo \'Connection error\' >&2',
	'\t\texit "${UBUS_WAIT_EXIT}"',
	'\tfi',
	'\texit 0',
	'\t;;',
	'*" call uci configs")',
	'\tif [ "${UBUS_CONFIGS_EXIT:-0}" -ne 0 ]; then',
	'\t\techo \'Connection error\' >&2',
	'\t\texit "${UBUS_CONFIGS_EXIT}"',
	'\tfi',
	'\tprintf \'%s\\n\' \'{"configs":["dhcp","network"]}\'',
	'\texit 0',
	'\t;;',
	'*"list rc")',
	'\tif [ "${UBUS_RC_EXIT:-0}" -ne 0 ]; then',
	'\t\techo \'Connection error\' >&2',
	'\t\texit "${UBUS_RC_EXIT}"',
	'\tfi',
	'\tif [ "${UBUS_RC_GARBAGE:-0}" -ne 0 ]; then',
	'\t\tprintf \'not-an-object-listing\\n\'',
	'\t\texit 0',
	'\tfi',
	'\trc_id="${UBUS_RC_ID:-0aaa}"',
	'\tif [ -n "${UBUS_RC_ID_NEW:-}" ] && [ -f "${RPCD_RELOAD_MARKER:-}" ]; then',
	'\t\trc_polls=$(cat "$UBUS_LOG.rcpolls" 2>/dev/null || printf \'0\')',
	'\t\trc_polls=$((rc_polls + 1))',
	'\t\tprintf \'%s\\n\' "$rc_polls" >"$UBUS_LOG.rcpolls"',
	'\t\tif [ "$rc_polls" -gt "${UBUS_RC_SWITCH_AFTER:-0}" ]; then',
	'\t\t\trc_id="${UBUS_RC_ID_NEW}"',
	'\t\tfi',
	'\tfi',
	'\tprintf "%s @%s\\n" "\'rc\'" "$rc_id"',
	'\tprintf \'init {}\\n\'',
	'\texit 0',
	'\t;;',
	'list|*\' list\')',
	'\tif [ "${UBUS_LIST_EXIT:-0}" -ne 0 ]; then',
	'\t\techo \'Connection error\' >&2',
	'\t\texit "${UBUS_LIST_EXIT}"',
	'\tfi',
	'\tfor object in ${UBUS_OBJECTS:-rc uci}; do printf \'%s\\n\' "$object"; done',
	'\texit 0',
	'\t;;',
	'esac',
	'exit 1',
	''
].join('\n');

const fakeRpcd = [
	'#!/bin/sh',
	'printf \'%s\\n\' "$*" >>"$RPCD_LOG"',
	'if [ "$1" = reload ] && [ -n "${RPCD_RELOAD_MARKER:-}" ]; then',
	'\t: >"$RPCD_RELOAD_MARKER"',
	'fi',
	'exit "${RPCD_EXIT:-0}"',
	''
].join('\n');

const failingGrepForRoutepolicy = [
	'#!/bin/sh',
	'for argument in "$@"; do',
	'\tcase "$argument" in',
	'\t*routepolicy*) echo \'grep: simulated failure\' >&2; exit 2 ;;',
	'\tesac',
	'done',
	'exec "${REAL_GREP:?}" "$@"',
	''
].join('\n');

function writeExecutable(file, content) {
	fs.writeFileSync(file, content);
	fs.chmodSync(file, 0o755);
}

function sandboxedHook(hook) {
	let script = emittedHook(hook);
	const substitutions = [
		['/etc/init.d/rpcd', 'etc/init.d/rpcd'],
		['/tmp/luci-indexcache.*', 'tmp/luci-indexcache.*'],
		['/tmp/luci-modulecache/', 'tmp/luci-modulecache/']
	];
	if (hook === 'postrm')
		substitutions.push(
			['/var/run/rpcd/snapshot-files', 'var/run/rpcd/snapshot-files'],
			['/var/run/rpcd/snapshot-delta', 'var/run/rpcd/snapshot-delta']);
	for (const [absolute, relative] of substitutions) {
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

function executeHook(hook, scenario, scenarioEnv, setup) {
	const sandbox = path.join(sandboxRoot, hook + '-' + scenario);
	fs.rmSync(sandbox, { recursive: true, force: true });
	fs.mkdirSync(path.join(sandbox, 'bin'), { recursive: true });
	fs.mkdirSync(path.join(sandbox, 'etc', 'init.d'), { recursive: true });
	fs.mkdirSync(path.join(sandbox, 'tmp', 'luci-modulecache'), { recursive: true });
	fs.mkdirSync(path.join(sandbox, 'var', 'run', 'rpcd'), { recursive: true });
	writeExecutable(path.join(sandbox, 'bin', 'ubus'), fakeUbus);
	writeExecutable(path.join(sandbox, 'etc', 'init.d', 'rpcd'), fakeRpcd);
	if (setup)
		setup(sandbox);
	fs.writeFileSync(path.join(sandbox, 'tmp', 'luci-indexcache.000001'), 'stale index cache\n');
	fs.writeFileSync(path.join(sandbox, 'tmp', 'luci-modulecache', 'stale-module'), 'stale module cache\n');
	fs.writeFileSync(path.join(sandbox, hook), sandboxedHook(hook));

	const sandboxBin = path.join(sandbox, 'bin').split(path.sep).join('/');
	const environment = {
		PATH: sandboxBin + path.delimiter +
			(process.platform === 'win32' ? path.dirname(sh) + path.delimiter : '') +
			(process.env.PATH || ''),
		UBUS_LOG: path.join(sandbox, 'ubus.log').split(path.sep).join('/'),
		RPCD_LOG: path.join(sandbox, 'rpcd.log').split(path.sep).join('/'),
		RPCD_RELOAD_MARKER: path.join(sandbox, 'reload.marker').split(path.sep).join('/')
	};
	if (process.platform === 'win32') {
		environment.SYSTEMROOT = process.env.SystemRoot;
		environment.TEMP = os.tmpdir();
		environment.TMP = os.tmpdir();
	}
	Object.assign(environment, scenarioEnv || {});

	const execution = spawnSync(sh, [hook], { cwd: sandbox, env: environment, encoding: 'utf8', timeout: 60000 });
	return {
		sandbox,
		exitStatus: execution.status,
		output: (execution.stdout || '') + (execution.stderr || ''),
		rpcdInvocations: readInvocations(path.join(sandbox, 'rpcd.log')),
		ubusInvocations: readInvocations(path.join(sandbox, 'ubus.log')),
		indexCacheCleared: !fs.existsSync(path.join(sandbox, 'tmp', 'luci-indexcache.000001')),
		moduleCacheCleared: !fs.existsSync(path.join(sandbox, 'tmp', 'luci-modulecache'))
	};
}

function assertSnapshotUntouched(sandbox, name) {
	const snapshot = path.join(sandbox, 'var', 'run', 'rpcd', name);
	assert.ok(fs.existsSync(snapshot) || fs.lstatSync(snapshot).isSymbolicLink(),
		'blocked snapshot state must never be cleaned by the hook');
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
	assert.deepStrictEqual(outcome.rpcdInvocations, [], 'offline image removals must not touch host rpcd');
	assert.deepStrictEqual(outcome.ubusInvocations, [], 'offline image removals must not query host ubus');
	assert.strictEqual(outcome.indexCacheCleared || outcome.moduleCacheCleared, false,
		'offline image removals must not modify files inside the image root');

	outcome = executeHook('postrm', 'upgrade-reinstall', { PKG_UPGRADE: '1' });
	assert.strictEqual(outcome.exitStatus, 0, 'an upgrade removal must succeed without interfering with the incoming postinst');
	assert.deepStrictEqual(outcome.rpcdInvocations, [], 'upgrade removals must not touch rpcd');
	assert.deepStrictEqual(outcome.ubusInvocations, [], 'upgrade removals must not probe ubus');
	assert.strictEqual(outcome.indexCacheCleared || outcome.moduleCacheCleared, false,
		'upgrade removals must leave maintenance to the incoming postinst');

	let snapshotForms = [
		['nonempty-dir', sandbox => {
			fs.mkdirSync(path.join(sandbox, 'var', 'run', 'rpcd', 'snapshot-files'));
			fs.writeFileSync(path.join(sandbox, 'var', 'run', 'rpcd', 'snapshot-files', 'delta.dat'), 'pending\n');
		}],
		['empty-dir', sandbox => fs.mkdirSync(path.join(sandbox, 'var', 'run', 'rpcd', 'snapshot-files'))],
		['regular-file', sandbox => fs.writeFileSync(path.join(sandbox, 'var', 'run', 'rpcd', 'snapshot-delta'), 'leftover\n')]
	];
	/* Windows hosts without symlink privilege cannot exercise the dangling-link form. */
	try {
		const probeDir = fs.mkdtempSync(path.join(sandboxRoot, 'symlink-probe-'));
		fs.symlinkSync('nowhere', path.join(probeDir, 'probe'));
		snapshotForms = snapshotForms.concat([['dangling-symlink', sandbox =>
			fs.symlinkSync('deleted-target', path.join(sandbox, 'var', 'run', 'rpcd', 'snapshot-files'))]]);
	} catch (error) {
		if (error.code !== 'EPERM')
			throw error;
	}
	for (const [form, setup] of snapshotForms) {
		outcome = executeHook('postrm', 'snapshot-' + form, {}, setup);
		assert.strictEqual(outcome.exitStatus, 1,
			'a pending or leftover rpcd snapshot (' + form + ') must explicitly fail the removal hook');
		assert.match(outcome.output, /luci-app-routepolicy/,
			'the blocked removal must explain itself on stderr');
		assert.deepStrictEqual(outcome.rpcdInvocations, [],
			'snapshot state must prevent any rpcd signal, including reload');
		assert.deepStrictEqual(outcome.ubusInvocations, [], 'snapshot state must prevent any ubus probing');
		assert.strictEqual(outcome.indexCacheCleared || outcome.moduleCacheCleared, false,
			'snapshot state must fail the hook before any cache maintenance');
		if (form === 'nonempty-dir')
			assert.strictEqual(fs.readFileSync(path.join(outcome.sandbox, 'var', 'run', 'rpcd', 'snapshot-files', 'delta.dat'), 'utf8'), 'pending\n',
				'snapshot payload must survive byte-for-byte');
		assertSnapshotUntouched(outcome.sandbox, form === 'regular-file' ? 'snapshot-delta' : 'snapshot-files');
	}

	outcome = executeHook('postrm', 'baseline-unreachable', { UBUS_RC_EXIT: '1' });
	assert.strictEqual(outcome.exitStatus, 1, 'an unreachable rc object listing must fail the removal before any signal');
	assert.deepStrictEqual(outcome.rpcdInvocations, [], 'no rpcd action may run without a baseline rc object id');

	outcome = executeHook('postrm', 'baseline-bad-id-format', { UBUS_RC_ID: 'zz!!' });
	assert.strictEqual(outcome.exitStatus, 1,
		'a non-hexadecimal rc object id must fail the removal instead of being trusted');
	assert.deepStrictEqual(outcome.rpcdInvocations, [], 'a malformed baseline id must fail before any rpcd signal');

	outcome = executeHook('postrm', 'baseline-garbage', { UBUS_RC_GARBAGE: '1' });
	assert.strictEqual(outcome.exitStatus, 1, 'an unparsable rc listing must fail the removal before any signal');
	assert.deepStrictEqual(outcome.rpcdInvocations, [], 'no rpcd action may run without a parsable rc object id');

	outcome = executeHook('postrm', 'reload-failure', { RPCD_EXIT: '2' });
	assert.strictEqual(outcome.exitStatus, 1, 'a failed rpcd reload must fail the removal loudly');
	assert.deepStrictEqual(outcome.rpcdInvocations, ['reload'], 'the removal must use the native reload action');
	assert.ok(!outcome.ubusInvocations.includes('-t 2 list'),
		'a failed reload must not be followed by object probing');

	outcome = executeHook('postrm', 'rc-id-never-changes', { UBUS_RC_ID: '0aaa', UBUS_RC_ID_NEW: '0aaa' });
	assert.strictEqual(outcome.exitStatus, 1,
		'a stale rc object id after reload must fail within the bounded wait instead of trusting the old object');

	outcome = executeHook('postrm', 'rc-new-id-bad-format', { UBUS_RC_ID: '0aaa', UBUS_RC_ID_NEW: 'not-hex!' });
	assert.strictEqual(outcome.exitStatus, 1,
		'a malformed post-reload rc id must never count as the new registration and must fail bounded');

	outcome = executeHook('postrm', 'rc-id-delayed', { UBUS_RC_ID: '0aaa', UBUS_RC_ID_NEW: '0bbb', UBUS_RC_SWITCH_AFTER: '2' });
	assert.strictEqual(outcome.exitStatus, 0, 'a delayed rc re-registration must still converge');
	assert.strictEqual(outcome.ubusInvocations.filter(call => call === '-t 2 -v list rc').length >= 4, true,
		'the delayed scenario must actually poll the rc id across reload');
	assert.deepStrictEqual(outcome.ubusInvocations.slice(-2), ['-t 10 call uci configs', '-t 2 list'],
		'convergence must end with the read-only health call and object listing');
	assert.deepStrictEqual(outcome.rpcdInvocations, ['reload'], 'the removal must reconcile rpcd via reload only, never a cold restart');

	outcome = executeHook('postrm', 'healthy-removal', { UBUS_RC_ID: '0aaa', UBUS_RC_ID_NEW: '0bbb' });
	assert.strictEqual(outcome.exitStatus, 0, 'a healthy removal must succeed');
	assert.strictEqual(outcome.indexCacheCleared && outcome.moduleCacheCleared, true,
		'removal must clear the same LuCI caches as install');
	assert.deepStrictEqual(outcome.rpcdInvocations, ['reload'], 'removal must never cold-restart rpcd');
	assert.deepStrictEqual(outcome.ubusInvocations, ['-t 2 -v list rc', '-t 2 -v list rc', '-t 10 call uci configs', '-t 2 list'],
		'removal must baseline the rc id, observe a new id, confirm uci health, then verify the object list');

	outcome = executeHook('postrm', 'uci-configs-failure', { UBUS_RC_ID: '0aaa', UBUS_RC_ID_NEW: '0bbb', UBUS_CONFIGS_EXIT: '1' });
	assert.strictEqual(outcome.exitStatus, 1, 'a failing uci configs health call must fail the removal');

	outcome = executeHook('postrm', 'list-connection-failure', { UBUS_RC_ID: '0aaa', UBUS_RC_ID_NEW: '0bbb', UBUS_LIST_EXIT: '1' });
	assert.strictEqual(outcome.exitStatus, 1,
		'ubus connection failure must never be interpreted as the object being gone');

	outcome = executeHook('postrm', 'list-missing-rc', { UBUS_RC_ID: '0aaa', UBUS_RC_ID_NEW: '0bbb', UBUS_OBJECTS: 'uci' });
	assert.strictEqual(outcome.exitStatus, 1, 'a missing rc object after reload must fail the removal');

	outcome = executeHook('postrm', 'list-missing-uci', { UBUS_RC_ID: '0aaa', UBUS_RC_ID_NEW: '0bbb', UBUS_OBJECTS: 'rc' });
	assert.strictEqual(outcome.exitStatus, 1, 'a missing uci object after reload must fail the removal');

	outcome = executeHook('postrm', 'object-residue', { UBUS_RC_ID: '0aaa', UBUS_RC_ID_NEW: '0bbb', UBUS_OBJECTS: 'rc uci routepolicy' });
	assert.strictEqual(outcome.exitStatus, 1,
		'a routepolicy object surviving the reload must fail the removal');

	outcome = executeHook('postrm', 'grep-error-not-absence', { UBUS_RC_ID: '0aaa', UBUS_RC_ID_NEW: '0bbb', REAL_GREP: realGrep }, sandbox => {
		writeExecutable(path.join(sandbox, 'bin', 'grep'), failingGrepForRoutepolicy);
	});
	assert.strictEqual(outcome.exitStatus, 1,
		'a grep error must be an explicit failure, never a false report that routepolicy is gone');
	assert.match(outcome.output, /simulated failure/,
		'the grep error path must actually be exercised');
} finally {
	fs.rmSync(sandboxRoot, { recursive: true, force: true });
}

console.log('LuCI package lifecycle contract passed.');
