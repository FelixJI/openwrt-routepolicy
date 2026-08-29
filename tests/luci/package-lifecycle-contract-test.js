'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const repo = path.resolve(__dirname, '../..');
const makefile = fs.readFileSync(path.join(repo, 'luci-app-routepolicy/Makefile'), 'utf8');
const postinst = makefile.match(
	/define Package\/\$\(PKG_NAME\)\/postinst\s*\r?\n([\s\S]*?)\r?\nendef/
);

assert.ok(postinst,
	'the package must own its install lifecycle instead of relying on a best-effort framework reload');
assert.match(postinst[1], /IPKG_INSTROOT/,
	'the install lifecycle must not touch services while building an image root');
assert.match(postinst[1], /rm -f \/tmp\/luci-indexcache\.\*/,
	'the install lifecycle must invalidate the LuCI server index cache');
assert.match(postinst[1], /rm -rf \/tmp\/luci-modulecache\//,
	'the install lifecycle must invalidate the LuCI server module cache');
assert.match(postinst[1], /if ! \/etc\/init\.d\/rpcd restart; then\s+exit 1\s+fi/,
	'rpcd restart failure must immediately fail the package script before any stale object can satisfy wait_for');
assert.match(postinst[1], /ubus -t 10 wait_for routepolicy/,
	'the package script must wait for the public routepolicy object before reporting success');

console.log('LuCI package lifecycle contract passed.');
