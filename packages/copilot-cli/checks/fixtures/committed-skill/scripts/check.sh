#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
IFS= read -r report <assets/expected.txt
[[ $report == REPORT-READY ]]
