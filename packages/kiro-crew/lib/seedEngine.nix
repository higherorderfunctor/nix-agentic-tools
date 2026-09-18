# Seed the packaged PPTX Maker engine into KiroCrew's per-user tree.
#
# WHY THIS CANNOT BE A DERIVATION, which is the whole reason a module exists at
# all for this package: `paths.engine_root()` resolves to
# `<crew home>/apps/pptx-maker/data/vendor/sdpm`, and `uv` creates
# `mcp-local/.venv` INSIDE that directory during provisioning. A read-only
# store path therefore cannot be the live tree — it has to be a writable copy,
# and making a writable copy in the user's home is activation work.
#
# What the copy buys: `engine_source.is_installed()` compares the marker's
# `commit` and `sha256` against its own constants, and `install_engine()` is
# documented idempotent — "an existing tree that already matches the pin is
# left untouched (no network call)". So a correctly-marked tree turns the
# first-run download into a no-op. That is the entire mechanism.
{
  lib,
  pkgs,
}: {engine}:
pkgs.writeShellApplication {
  name = "kiro-crew-seed-pptx-engine";
  runtimeInputs = [pkgs.coreutils pkgs.jq];
  # `set -o` flags belong here rather than in `text`: writeShellApplication
  # emits them ABOVE its own generated `export PATH=…`, so `nounset` covers
  # that line too. `inherit_errexit` is a shopt and has no `bashOptions` form,
  # so it is set in `text` — the header genuinely splits across both.
  bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
  text = ''
    shopt -s inherit_errexit 2>/dev/null || :

    # `engine_root()` arrives as ARGV, not baked in. It is a runtime path that
    # can contain `$HOME` — `KIROCREW_HOME` relocates the crew data root, and
    # only the caller knows whether the user set it. Interpolating it into this
    # script would mean either escaping it (so `$HOME` never expands) or not
    # escaping it (so any other metacharacter in a user-chosen path executes).
    # Taking it as an argument dodges both.
    if [ "$#" -ne 1 ]; then
      echo "usage: $0 <engine-root>" >&2
      exit 2
    fi
    engine=${lib.escapeShellArg engine}
    root="$1"
    marker=".kirocrew-engine.json"

    # The pin this seed would install. Read from the store copy rather than
    # restated, so it cannot drift from the derivation that produced it.
    want_commit="$(jq -er '.commit' "$engine/$marker")"
    want_sha="$(jq -er '.sha256' "$engine/$marker")"

    # IDEMPOTENCE IS LOAD-BEARING, not an optimization. The engine's venv lives
    # INSIDE this tree at `mcp-local/.venv`, so re-seeding an already-correct
    # tree would destroy a provisioned venv on every activation and force `uv`
    # to resolve it again. Compare the same two fields `is_installed()` does,
    # and do nothing when they agree.
    if [ -f "$root/$marker" ]; then
      have_commit="$(jq -er '.commit // empty' "$root/$marker" 2>/dev/null || echo "")"
      have_sha="$(jq -er '.sha256 // empty' "$root/$marker" 2>/dev/null || echo "")"
      if [ "$have_commit" = "$want_commit" ] && [ "$have_sha" = "$want_sha" ]; then
        echo "kiro-crew: PPTX engine already at $want_commit — leaving it alone"
        exit 0
      fi
      echo "kiro-crew: PPTX engine pin moved, reseeding ($have_commit -> $want_commit)"
    else
      echo "kiro-crew: seeding the PPTX engine at $want_commit"
    fi

    mkdir -p "$(dirname "$root")"

    # Stage beside the target so the swap is a same-filesystem rename, then
    # retire the old tree and move the new one in. Same ordering upstream's
    # own `_swap_in` uses, and for the same reason: the fallible work happens
    # before anything the live install depends on is removed.
    staging="$root.seed-staging"
    retired="$root.seed-retired"
    rm -rf "$staging" "$retired"

    # `--no-preserve=mode`: the source is a 0555/0444 store path and the
    # destination must be writable by its owner, because `uv` writes the venv
    # into it. This is the same defect the copytree patches fix on upstream's
    # own copy paths; here we simply never create it.
    cp -R --no-preserve=mode "$engine/." "$staging"

    if [ -e "$root" ]; then
      mv "$root" "$retired"
    fi
    mv "$staging" "$root"
    rm -rf "$retired"

    echo "kiro-crew: PPTX engine seeded at $root"
  '';
}
