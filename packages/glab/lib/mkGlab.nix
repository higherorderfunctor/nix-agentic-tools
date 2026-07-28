# Builds a glab wrapped to supply its host URL, token and settings from
# module configuration at INVOCATION time.
#
# ── Why a wrapper and not a config file ─────────────────────────────
# glab's own config lives at `$GLAB_CONFIG_DIR/config.yml` (default
# `~/.config/glab-cli/`), and writing it declaratively is not an option
# for two independent reasons:
#
#   1. glab REFUSES to read a config.yml that is not mode 0600. Measured
#      against 1.110.0: "has the permissions 664, but glab requires 600".
#      home-manager's `home.file` and Nix store symlinks land 0444/0644,
#      so a declaratively managed config.yml makes glab refuse to start.
#   2. glab WRITES to that file (aliases, `last_seen_version`, the
#      auth-login bookkeeping). Pointing it at a read-only store path
#      breaks those paths.
#
# Environment variables have neither problem, and they are not a partial
# substitute: `GetFromEnvWithSource` resolves EVERY config key through
# `EnvKeyEquivalence`, which returns the key's explicit `EnvVars` or falls
# back to `strings.ToUpper(name)`. Measured against 1.110.0 with a
# populated config.yml: `GITLAB_HOST`, `GITLAB_URI` and a bare
# `GIT_PROTOCOL` (a key with NO explicit override, so it exercises the
# uppercase fallback) each won over the file.
#
# ── Why symlinkJoin and not wrapProgram ─────────────────────────────
# `wrapProgram --set` bakes the value into the store, which is exactly
# what a secret must not do. The wrapper below reads the file (or runs
# the helper) on each invocation instead. Joining rather than shadowing
# keeps upstream's manpages and shell completions, which a bare
# `writeShellScriptBin` on PATH would hide.
{
  lib,
  pkgs,
  cfg,
}: let
  credentialsLib = import ../../../lib/credentials.nix {inherit lib;};

  # Key partitioning + env-var mapping live in ONE place, shared with
  # ../modules/options.nix, which declares the options these exports
  # render. `secretKeys` is already deduplicated and deterministically
  # ordered there, so the generated script is stable.
  glabSchema = import ./schema.nix {inherit lib;};
  inherit (glabSchema) envVarOf secretKeys;

  secretExports =
    lib.concatStringsSep "\n"
    (builtins.filter (s: s != "")
      (map (n: credentialsLib.mkSecretExport pkgs (envVarOf n) (cfg.${n} or null)) secretKeys));

  # Non-secret settings: plain exports, no store-visibility concern.
  # Booleans become "true"/"false", which is what glab's own bool parser
  # accepts alongside 1/0.
  renderValue = v:
    if builtins.isBool v
    then
      (
        if v
        then "true"
        else "false"
      )
    else toString v;

  settingExports =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (name: value: ''
      ${envVarOf name}=${lib.escapeShellArg (renderValue value)}
      export ${envVarOf name}'')
    (lib.filterAttrs (_: v: v != null) cfg.settings));

  # extraSettings uses the uppercase fallback, matching what glab does
  # for any key with no explicit EnvVars override.
  extraExports =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (name: value: ''
      ${lib.toUpper name}=${lib.escapeShellArg value}
      export ${lib.toUpper name}'')
    cfg.extraSettings);

  exports =
    lib.concatStringsSep "\n"
    (builtins.filter (s: s != "") [secretExports settingExports extraExports]);

  wrapperText = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    ${exports}

    exec "${lib.getExe cfg.package}" "$@"
  '';

  wrapper = pkgs.writeShellScript "glab-wrapper" wrapperText;
in
  pkgs.symlinkJoin {
    name = "glab-wrapped-${cfg.package.version}";
    paths = [cfg.package];

    # Replace only bin/glab. Everything else in the join — man pages,
    # bash/fish/zsh completions — is upstream's, untouched.
    postBuild = ''
      rm -f "$out/bin/glab"
      ln -s "${wrapper}" "$out/bin/glab"
    '';

    # The script SOURCE, not its store path. checks/module-eval.nix
    # asserts on it, and reading the path back would be import-from-
    # derivation inside `nix flake check` — a string costs nothing.
    passthru = {inherit wrapperText;};

    meta =
      cfg.package.meta
      // {
        description = "${cfg.package.meta.description or "GitLab CLI"} (wrapped with declarative configuration)";
        mainProgram = "glab";
      };
  }
