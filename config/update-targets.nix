# config/update-targets.nix — central config.update.targets contribution.
#
# Declares every package's update row EXCEPT effect-mcp, which carries its own
# co-located overlays/mcp-servers/effect-mcp.update.nix (disjoint keys, no
# collision). Merged with lib/update.nix (the option declaration) and the
# effect-mcp contribution by lib.evalModules into the `.#updateTargets` flake
# output — the single source of truth that replaced config/update-matrix.nix.
#
# `file` is a repo-relative POSIX path STRING equal to what
# resolve_overlay_file prints for each main-tracking upstream (asserted
# byte-identical by checks/update-targets-parity.nix); `null` for the binary
# (--use-update-script) packages, which self-manage their sources.
#
# All non-flake-input packages go through nix-update. Per-platform binary
# packages use --use-update-script.
_: {
  config.update.targets = {
    # ── Main-tracking (rev bumped from default branch, hashes via nix-update) ──
    agnix = {
      file = "overlays/agnix.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/agent-sh/agnix.git";
      dependsOn = ["rust-overlay"];
    };
    context7-mcp = {
      file = "overlays/mcp-servers/context7-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/upstash/context7.git";
    };
    git-absorb = {
      file = "overlays/git-tools/git-absorb.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/tummychow/git-absorb.git";
      dependsOn = ["rust-overlay"];
    };
    git-intel-mcp = {
      file = "overlays/mcp-servers/git-intel-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/hoangsonww/GitIntel-MCP-Server.git";
    };
    git-revise = {
      file = "overlays/git-tools/git-revise.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/mystor/git-revise.git";
    };
    github-mcp = {
      file = "overlays/mcp-servers/github-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/github/github-mcp-server.git";
    };
    gitlab-mcp = {
      file = "overlays/mcp-servers/gitlab-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/zereight/gitlab-mcp.git";
    };
    kagi-mcp = {
      file = "overlays/mcp-servers/kagi-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/kagisearch/kagimcp.git";
    };
    kiro-gateway = {
      file = "overlays/kiro-gateway.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/jwadow/kiro-gateway.git";
    };
    markdownlint-cli2 = {
      # Upstream ships no package-lock.json, so nixpkgs vendors one and the
      # build symlinks it in. `--generate-lockfile` regenerates OUR copy
      # beside the overlay on every bump; without it a version bump would
      # build new source against the old dependency set.
      file = "overlays/dev-tools/markdownlint-cli2.nix";
      flags = ["--generate-lockfile"];
    };
    mcp-language-server = {
      file = "overlays/mcp-servers/mcp-language-server.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/isaacphi/mcp-language-server.git";
    };
    mcp-proxy = {
      file = "overlays/mcp-servers/mcp-proxy.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/sparfenyuk/mcp-proxy.git";
    };
    modelcontextprotocol-filesystem-mcp = {
      file = "overlays/mcp-servers/modelcontextprotocol/default.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/modelcontextprotocol/servers.git";
    };
    # oxlint overrides three hashes: src, cargoDeps (fetchCargoVendor), pnpmDeps
    # (fetchPnpmDeps). The rev-bump pre-step writes the src hash itself, and
    # `--no-src` is REQUIRED so nix-update does not then try to re-derive it.
    #
    # Since 2026-08-04 `src` is an `applyPatches` over the fetch, not the fetch
    # itself (it carries the pnpm patched-dependency metadata that
    # `fetchPnpmDeps` must see). nix-update re-derives a src hash by rebuilding
    # `pkg.src` with `outputHash = ""`, which forces FLAT hashing — and an
    # `applyPatches` output is a DIRECTORY, so the build always dies with
    # `should be a non-executable regular file since recursive hashing is not
    # enabled`. That aborts the run before either dependency hash is touched, so
    # oxlint was held back on EVERY sweep for ten days. `--no-src` skips exactly
    # that pass and leaves `update_dependency_hashes` to do the work we need.
    #
    # The failure was invisible because nix-update reports it as
    # `failed to retrieve hash when trying to update oxlint.src` — the same
    # sentence a patch conflict produces. Measured on the 2026-08-08 sweep, where
    # the patch applied cleanly (`patch_hash stamped on 8 importer + 2 snapshot
    # entries`) and the run still failed on this. Do not read that message as
    # naming a patch problem; check for this one too.
    oxlint = {
      file = "overlays/dev-tools/oxlint.nix";
      flags = ["--version" "skip" "--no-src"];
      git = "https://github.com/oxc-project/oxc.git";
    };
    sympy-mcp = {
      file = "overlays/mcp-servers/sympy-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/sdiehl/sympy-mcp.git";
    };
    # tsgolint src uses fetchSubmodules (typescript-go). The rev-bump pre-step's
    # `nix flake prefetch` writes a submodule-less src hash, but nix-update then
    # self-corrects it — its `outputHash=""` src rebuild respects fetchSubmodules,
    # yielding the right hash (+ vendorHash) before the build-verify. Validated
    # 2026-07-21: standard main-tracking flow works, no bespoke updateScript.
    tsgolint = {
      file = "overlays/dev-tools/tsgolint.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/oxc-project/tsgolint.git";
    };

    # ── Binary packages (custom updateScript handles per-platform fetches) ──
    # arkenfox / btop / catppuccin-btop / fblog fetch a GitHub repo-archive
    # tarball via ghArchiveUpdateScript rather than a per-platform release
    # asset; dns-root-hints fetches one platform-independent file, as do
    # pnpm_10 / pnpm_11 (one npm registry tarball each, tracked per major
    # off npm's `latest-<N>` dist-tag). Same --use-update-script contract
    # either way — the script owns its sidecar.
    #
    # beads / gh / gluetun / oh-my-posh / otel-tui are on the same
    # ghArchiveUpdateScript contract but carry a SECOND hash: `vendorHash`,
    # which a Go package cannot derive from a lockfile the way importCargoLock
    # derives one from Cargo.lock. mkUpdateScript rebuilds the sidecar from
    # scratch on every write, so each of them threads a vendor fixer through
    # extraExtract. Beads' one target owns TWO independent child scripts — its
    # own release and the paired Dolt release — so either upstream can move
    # while the result remains one update/beads branch and PR. Nothing extra is
    # needed in this registry.
    #
    # bruno and glab are the same --use-update-script contract with a THIRD
    # variation: their src hash cannot come from a prefetch at all, because
    # the overlay re-points nixpkgs' fetcher and that fetcher's `postFetch`
    # mutates the tree the hash covers. Both therefore pass
    # `platforms = {}` (version only) and thread an `extraExtract` fixer
    # that restores `srcHash` FIRST and then the deps hash —
    # `fixNpmDepsHash` for bruno, `fixSrcHash` + `fixVendorHash` for
    # glab. Nothing extra is needed here either.
    #
    # glab is also the one row whose version check is NOT a GitHub one: the
    # project lives on gitlab.com, so its overlay uses
    # `vu.glLatestVersionCmd` instead. That is entirely inside the
    # updateScript and invisible to this registry.
    arkenfox = {flags = ["--use-update-script" "--override-filename" "overlays/generic/arkenfox.nix"];};
    beads = {flags = ["--use-update-script" "--override-filename" "overlays/dev-tools/beads.nix"];};
    bruno = {flags = ["--use-update-script" "--override-filename" "overlays/generic/bruno.nix"];};
    btop = {flags = ["--use-update-script" "--override-filename" "overlays/generic/btop.nix"];};
    bun = {flags = ["--use-update-script" "--override-filename" "overlays/generic/bun.nix"];};
    catppuccin-btop = {flags = ["--use-update-script" "--override-filename" "overlays/generic/catppuccin-btop.nix"];};
    chatgpt-codex = {flags = ["--use-update-script" "--override-filename" "overlays/chatgpt-codex.nix"];};
    # This key names the bot's branch (`update/claude-code`), and
    # .github/workflows/ci.yml gates the heron_brook reminder step on exactly
    # that branch. Rename it here and you must rename it there too, or the
    # reminder silently never fires — checks/claude-heron-brook.nix asserts the
    # two agree.
    claude-code = {flags = ["--use-update-script"];};
    copilot-cli = {flags = ["--use-update-script" "--override-filename" "overlays/copilot-cli.nix"];};
    dns-root-hints = {flags = ["--use-update-script" "--override-filename" "overlays/generic/dns-root-hints.nix"];};
    fblog = {flags = ["--use-update-script" "--override-filename" "overlays/generic/fblog.nix"];};
    gh = {flags = ["--use-update-script" "--override-filename" "overlays/dev-tools/gh.nix"];};
    glab = {flags = ["--use-update-script" "--override-filename" "overlays/dev-tools/glab.nix"];};
    gluetun = {flags = ["--use-update-script" "--override-filename" "overlays/generic/gluetun.nix"];};
    kimchi = {flags = ["--use-update-script" "--override-filename" "overlays/kimchi.nix"];};
    kiro-cli = {flags = ["--use-update-script" "--override-filename" "overlays/kiro-cli.nix"];};
    oh-my-posh = {flags = ["--use-update-script" "--override-filename" "overlays/generic/oh-my-posh.nix"];};
    otel-tui = {flags = ["--use-update-script" "--override-filename" "overlays/generic/otel-tui.nix"];};
    pnpm_10 = {flags = ["--use-update-script" "--override-filename" "overlays/generic/pnpm_10.nix"];};
    pnpm_11 = {flags = ["--use-update-script" "--override-filename" "overlays/generic/pnpm_11.nix"];};
    pnpm_12 = {flags = ["--use-update-script" "--override-filename" "overlays/generic/pnpm_12.nix"];};
    rumdl = {flags = ["--use-update-script" "--override-filename" "overlays/dev-tools/rumdl.nix"];};
  };

  # Packages excluded from the update loop entirely.
  # Regex patterns matched against flake package names.
  #
  # aihubmix-mcp is the one entry here excluded for a REASON THAT CAN
  # CHANGE, so it is the one to re-examine. It carries a local patch against
  # upstream's published build output, and no update script can re-author a
  # patch. Note what this is NOT about: the package tracks npm
  # `dist-tags.latest` (1.1.0). Being current did not make it sweepable —
  # getting there required re-authoring the patch BY HAND, because
  # build/tools/painting-tools.js was rewritten 288 -> 624 lines and 2 of
  # its 3 hunks stopped applying. A targets row would go RED the next time
  # upstream does that, permanently occupying a channel meant for TRANSIENT
  # failures. Currency is surfaced instead by update.yml's non-blocking
  # "Detect a newer @aihubmix/mcp on npm" step. Delete this line, delete
  # that step, and add a `--use-update-script` row the moment the patch can
  # be dropped entirely (upstream grows a native save-to-disk argument, or
  # takes the change) — the two mechanisms must never both be live.
  config.update.excludePatterns = [
    "^agnix-lsp$"
    "^agnix-mcp$"
    "^aihubmix-mcp$"
    "^docs"
    "^instructions-"
    "^nixos-mcp$"
    "^serena-mcp$"
  ];
}
