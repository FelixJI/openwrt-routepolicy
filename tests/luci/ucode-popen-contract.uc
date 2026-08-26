'use strict';

import { popen } from 'fs';

const expected = 'routepolicy-ucode-runtime\n';
let proc = popen("printf 'routepolicy-ucode-runtime\\n'", 'r');

assert(proc, 'target ucode must open a fixed command string');
let output = proc.read('all');
let exitcode = proc.close();

assert(output == expected, 'target ucode returned unexpected command output');
assert(exitcode == 0, 'target ucode command must exit successfully');

const stdin_payload = 'routepolicy-stdin-contract\n';
proc = popen("grep -qx 'routepolicy-stdin-contract'", 'w');
assert(proc, 'target ucode must open a fixed stdin command string');
assert(proc.write(stdin_payload) == length(stdin_payload), 'target ucode must write the complete stdin payload');
assert(proc.close() == 0, 'target ucode stdin command must accept the payload');
print('ucode fixed-string popen contract passed.\n');
