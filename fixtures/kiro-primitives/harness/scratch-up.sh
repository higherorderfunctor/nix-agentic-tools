#!/usr/bin/env bash
#
# Materialize a scratch HOME and a scratch workspace for one mode-F sitting.
#
# Prints an `eval`-able block of the variables every other harness script wants,
# so a runbook step is a copy-paste rather than a set of things to remember:
#
#   eval "$(./scratch-up.sh)"
#
# WHY HOME AND NOT KIRO_HOME: see the header of lib.sh. Short version — the
# engine resolves its root from os.homedir() because the launcher never passes
# --home-dir, and KIRO_HOME means a different thing one layer up. Redirecting
# KIRO_HOME would point this harness at a directory the engine never reads, and
# the symptom is a silent "the workflow flag didn't work".
#
# XDG_DATA_HOME is deliberately NOT redirected. An empty credential database
# means no cached token, and the CLI answers that with an interactive browser
# login rather than an error. That also means this harness needs a machine that
# has already logged in.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

scratch_root="${KIRO_FIXTURE_SCRATCH:-${TMPDIR:-/tmp}/kiro-mode-f}"

# Refuse an unsafe root before creating anything under it.
kiro_assert_under_scratch "$scratch_root" "$scratch_root"

scratch_home="$scratch_root/home"
workspace="$scratch_root/workspace"

mkdir -p "$scratch_home" "$workspace"

# The engine creates the .kiro subtree it needs on first launch. Only the
# sessions path is pre-created, because seed-session.sh writes into it before
# any launch happens.
mkdir -p "$scratch_home/.kiro/sessions"

# Both of these must be REAL directories. The session lister filters on a
# directory-entry type check that is false for a symlink, so a symlinked bucket
# or session silently vanishes from --resume, --resume-picker and
# --list-sessions while staying reachable by --resume-id. That split symptom is
# how a "the feature is broken" conclusion gets made.
kiro_assert_real "$scratch_home/.kiro/sessions"
kiro_assert_real "$workspace"

bundle_info="$(kiro_resolve_bundle)"
kasid="${bundle_info%%$'\t'*}"

cat <<EOF
# mode-F scratch environment — eval this
export KIRO_FIXTURE_SCRATCH='${scratch_root}'
export KIRO_FIXTURE_HOME='${scratch_home}'
export KIRO_FIXTURE_WORKSPACE='${workspace}'
export KIRO_FIXTURE_KASID='${kasid}'
# Raise the engine's log level: four otherwise-silent decisions (adapter
# selection, agent-profile hook registration, workspace-root overlap, and
# untrusted-workspace hook suppression) are debug-only. Whether the launcher
# forwards this to the engine is NOT yet established — assert-seed-took.sh
# reports whether any debug line actually appeared.
export KIRO_LOG_LEVEL='debug'
# Deliberately NOT exported: KIRO_HOME (wrong layer, silently hides things) and
# XDG_DATA_HOME (empties the credential store and forces a browser login).
EOF
