#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# Managed policyHelper for policy-helper.sh: prints the helper output schema
# {managedSettings, claudeMd, appendSystemPrompt} with one sentinel append.
printf '%s\n' '{"managedSettings":{},"appendSystemPrompt":"Policy helper sentinel: POLICYAPP-8484."}'
