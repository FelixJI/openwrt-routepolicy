#!/bin/sh

set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
"$HERE/common-test.sh"
"$HERE/user-list-test.sh"
"$HERE/cli-contract-test.sh"
"$HERE/init-lifecycle-test.sh"
"$HERE/status-contract-test.sh"
"$HERE/warm-state-test.sh"
"$HERE/mark-conflict-test.sh"
"$HERE/render-test.sh"
"$HERE/apply-failure-test.sh"
"$HERE/apply-route-test.sh"
"$HERE/import-legacy-test.sh"
"$HERE/smartdns-lifecycle-test.sh"
"$HERE/smartdns-management-test.sh"
