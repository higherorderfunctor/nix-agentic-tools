#!/usr/bin/env bash
# Local hooks and patch-policy scan Nix sources for direct patch bypasses.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
cd "${1:-.}"
# Only the shared implementation may choose flags or invoke patch tools.
# Text matching covers literal calls; computed commands require code review.
# Kiro option prose begins with "patch" but is not a shell command.
kiro_description="patch the binary's embedded manifest. A raw"
status=0
rg --hidden --no-ignore -n -U -P --glob '*.nix' --glob '!.git/**' \
  --glob '!lib/packaging/patching.nix' \
  "^(?!\h*#|\h*\Q${kiro_description}\E$)[^\n]*?(\bpatchFlags\b|\bapplyPatches\b|\bpatch\s+[-<]|(?:^\h*|[;&|(\"\x27]\h*)(?:command\h+|exec\h+)?patch(?!\h*=)(?:\h|$)|/bin/patch\b|\bgetExe\s+pkgs\.(?:gnu)?patch\b|\bgit\b[^\n]*\bapply\b)" . || status=$?
test "$status" -eq 1
