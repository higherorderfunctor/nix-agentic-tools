# rumdl — the Rust markdownlint, re-pinned onto this repo's update
# cadence. An `overrideAttrs` over nixpkgs' own
# `rustPlatform.buildRustPackage` derivation: `version`, `src` and
# `cargoDeps` move, everything else stays whatever nixpkgs ships.
#
# Structurally identical to overlays/generic/fblog.nix, including the
# ONE-HASH decision and its reasoning: nixpkgs carries an inline
# `cargoHash` beside the src hash, `ghArchiveUpdateScript` refreshes only
# the src hash in the sidecar, so a version bump would land a stale
# vendor hash every time — the transitive-hash gap this repo already
# tracks. Reading `Cargo.lock` out of the PINNED source instead means the
# vendor set is derived from the same pin the sidecar names and
# self-updates with it.
#
# WHY IT IS CARRIED AT ALL, given nixpkgs has it. Same reason as every
# other package here: nixpkgs' version is not an input to this repo's
# cadence. At absorption nixpkgs shipped 0.2.60 against upstream's
# v0.2.62 — a real delta, but the delta is not the justification and a
# future parity is not a reason to drop it.
#
# UPSTREAM SHIPS NO FLAKE. Checked at absorption: rvben/rumdl has no
# flake.nix on main (404), so there is no upstream flake output to
# consume the way overlays/semble.nix consumes one. An overlay plus a
# sidecar is the whole mechanism.
#
# WHAT IT IS FOR HERE — read this before "simplifying" the pair. rumdl is
# the PRIMARY half of the markdown table-cell-count gate declared in
# `config/repo-validation.nix`; `markdownlint-cli2` is the backup half.
# They share the rule NUMBER (MD056) and cover DISJOINT halves of it:
# rumdl catches a header/delimiter disagreement (the break), markdownlint
# catches an over-wide body row (the cause) and goes blind on the break
# because its parser stops recognizing a table at all. Measured over this
# corpus with only MD056 enabled, rumdl runs in 0.04s against
# markdownlint's 8.2s, which is why the Rust one is primary. Neither is
# redundant; that config's header carries the full table.
#
# NOT a formatter, and this changes nothing about formatting.
# `dev/fragments/markdown-formatting/` records the measured survey: no
# Rust markdown formatter joins a split inline code span — `rumdl fmt`
# does not reflow at all — so prettier owns formatting and keeps owning
# it. This is the LINTER slot beside `doubled-words` and
# `split-code-spans`.
#
# Not agentic-tools-specific — it lives under overlays/dev-tools/ beside
# the other agent-adjacent utilities.
#
# Free (MIT). ensureUnfreeCheck in default.nix passes free packages
# through unwrapped.
{
  inputs,
  final,
  ...
}: let
  # Cache-hit parity: every build input comes from THIS repo's nixpkgs
  # pin, never the consumer's `final`. `final.stdenv.hostPlatform.system`
  # is the only thing read from the consumer — see
  # dev/fragments/overlays/overlay-pattern.md.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchzip;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./rumdl-sources.json);

  # Bound once: `cargoDeps` reads the lock file out of this exact
  # derivation, so src and vendor set can never point at two revisions.
  # fetchzip, so the recorded hash is over the UNPACKED NAR — which is
  # why the updateScript below prefetches with --unpack.
  src = fetchzip {inherit (sources.src) url hash;};
in
  ourPkgs.rumdl.overrideAttrs (prev: {
    inherit (sources) version;
    inherit src;

    cargoDeps = ourPkgs.rustPlatform.importCargoLock {
      lockFile = "${src}/Cargo.lock";
      allowBuiltinFetchGit = true;
    };

    # Merge, never replace: buildRustPackage attaches helpers here and
    # dropping them triggers eval warnings. See the nix-standards
    # fragment.
    passthru =
      (prev.passthru or {})
      // {
        updateScript = vu.ghArchiveUpdateScript {
          pkgs = ourPkgs;
          pname = "rumdl";
          repo = "rvben/rumdl";
          sourcesFile = "overlays/dev-tools/rumdl-sources.json";
        };
      };
  })
