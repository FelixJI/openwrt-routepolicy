'use strict';

import { mkstemp, popen } from 'fs';

function call_core(command, content) {
	/* Two anonymous files provide independent streams without shared results
	 * or user data in a command line. The child receives only their FDs. */
	const input = mkstemp('/tmp/routepolicy-lifecycle.XXXXXX');
	const reply = mkstemp('/tmp/routepolicy-lifecycle.XXXXXX');
	let payload;
	try {
		if (input && reply && input.write(content) == length(content) && input.seek(0)) {
			const proc = popen(command, 'w');
			if (proc) {
				const streams = `${input.fileno()}\t${reply.fileno()}\n`;
				const written = proc.write(streams);
				const rc = proc.close();
				if (written == length(streams) && reply.seek(0)) {
					payload = json(reply.read(262144));
					if (type(payload) == 'object')
						payload.ok = rc == 0 && payload.ok === true;
				}
			}
		}
	}
	catch (e) {}
	input?.close();
	reply?.close();
	return type(payload) == 'object' ? payload : { ok: false, error: '无法读取 RoutePolicy 生命周期响应' };
}

return { call_core };
