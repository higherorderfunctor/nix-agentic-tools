#!/usr/bin/env bash
# kiro-memory-hitl.sh — set up + drive the HITL live-TUI test of kiro-cli
# auto-memory (docs/plans/kiro-cli-auto-memory.md, STATE session 11 / D27).
#
# USER-RUN, in a SCRATCH config — it never touches ~/.kiro config or your real
# repos. It builds the REAL autoMemory hooks + steering (via kiro-memory-hitl.nix,
# derived from the generators so it can't go stale), drops them into a throwaway
# git repo's workspace-local .kiro/, and points the distiller's WRITE target at a
# scratch dir. kiro still reads its transcript from ~/.kiro/sessions (its own dir).
#
# What it proves (the only remaining closed-binary unknown for the write loop):
#   (a) /hooks lists all THREE hooks from the ONE kiro-memory.json envelope
#   (b) the scratch <memDir>/<project>/{now,recent}.md GREW
#   (c) the steering anchor ("Persistent project memory") shows in context
#
# Env overrides: MEM_SCRATCH (default /tmp/kiro-mem-hitl), PROJ (default
# /tmp/kiro-hitl-proj).
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${script_dir}/../.." && pwd)"
mem_scratch="${MEM_SCRATCH:-/tmp/kiro-mem-hitl}"
proj="${PROJ:-/tmp/kiro-hitl-proj}"

echo "==> building the real autoMemory hooks + steering (OOM-safe targeted eval)"
config="$(nix-build --impure --no-out-link \
  "${root}/dev/scripts/kiro-memory-hitl.nix" \
  --argstr memDir "${mem_scratch}")"
echo "    built: ${config}"

echo "==> creating throwaway project at ${proj}"
rm -rf -- "${proj}" "${mem_scratch}"
mkdir -p -- "${proj}/.kiro"
git init -q -b main "${proj}"
git -C "${proj}" config user.email hitl@example.com
git -C "${proj}" config user.name hitl
# workspace-local v3 standalone hooks + the always-on steering anchor
cp -r -- "${config}/hooks" "${config}/steering" "${proj}/.kiro/"
chmod -R u+w -- "${proj}/.kiro" # store copies are read-only
# a couple of source files so there is something to talk about across turns
echo 'export const add = (a, b) => a + b;' >"${proj}/math.js"
echo 'export const sub = (a, b) => a - b;' >"${proj}/math2.js"
git -C "${proj}" add -A
git -C "${proj}" commit -qm "hitl fixture"

cat <<EOF

==> READY. Now run the live test (trusted TUI — v3):

  cd ${proj}
  kiro-cli chat --tui --v3      # verified working on 2.12.0 (S13). The launcher form
                                # 'kiro-cli --v3 --tui' also works; either is fine.
  # Trust the workspace when prompted (hooks only fire in a trusted TUI).

  Run 2-3 turns that reference the two files, e.g.:
    > what does math.js do?
    > now do the same explanation for math2.js
  Then quit.

==> CHECK:
  (a) /hooks   -> kiro-memory-distill (Stop), kiro-memory-flush (SessionStart),
                  kiro-memory-remember (Manual)
  (b) ls -R ${mem_scratch}   -> a <project-slug>/ dir with now.md / recent.md that GREW
      cat ${mem_scratch}/*/now.md
  (c) the "Persistent project memory" steering anchor appears in the model's context
  (optional) trigger the Manual hook (/remember) -> an immediate distill

==> If kiro will NOT fire all three hooks from the one file, split to one-file-per-hook
    (a trivial 3-attr change in packages/kiro-cli/lib/autoMemory.nix) and report back so
    the next session folds it into D27 + the frozen stage order.

==> CLEANUP:  rm -rf ${proj} ${mem_scratch}
EOF
