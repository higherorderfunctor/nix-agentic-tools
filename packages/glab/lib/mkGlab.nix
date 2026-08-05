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

  # A synchronized token must be read back through glab's keyring-aware config
  # path. Exporting GITLAB_TOKEN here would take precedence over that stored
  # credential and keep exposing it to every glab process, defeating the mode.
  invocationSecretKeys =
    if cfg.keyringSync.enable or false
    then builtins.filter (name: name != "token") secretKeys
    else secretKeys;

  secretExports =
    lib.concatStringsSep "\n"
    (builtins.filter (s: s != "")
      (map (n: credentialsLib.mkSecretExport pkgs (envVarOf n) (cfg.${n} or null)) invocationSecretKeys));

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

  # Shell-QUOTED, so nothing in the value expands. An earlier revision
  # interpolated it bare so the devenv facet could pass
  # `$DEVENV_STATE/glab-cli`; that turned out to be unnecessary —
  # `devenv.state` is available at eval time, so the facet passes a real
  # path — and it meant a `$(…)` in the value would run on every glab
  # invocation. Both facets now build the path in Nix, where the values
  # are known anyway, which is also why `~` no longer needs a caveat.
  configDirExport =
    if cfg.configDir == null
    then ""
    else ''
      GLAB_CONFIG_DIR=${lib.escapeShellArg cfg.configDir}
      export GLAB_CONFIG_DIR'';

  # ── Preflight + hosts: seeding ───────────────────────────────────
  # `glab auth status` is the one command that does NOT read the resolved
  # configuration: it enumerates `cfg.Hosts()`, the `hosts:` block of
  # config.yml (internal/commands/auth/status/status.go). Env vars set the
  # global `host` and the token, but they never populate that list, so an
  # env-only setup makes `auth status` report gitlab.com and "No token
  # found" while every other command works fine. That is a trap: it is the
  # first thing anyone runs when debugging auth.
  #
  # Seeding is done by glab ITSELF rather than by editing YAML here. glab
  # owns this file and rewrites it (comments, key order, 4-space indent),
  # so hand-written YAML would drift; `config set --host` writes it in
  # glab's own format and needs no yq in the closure.
  #
  # NOTE the flag is `--host` and NOT `-h`, which collides with help and
  # silently writes a `gitlab.com` entry instead. Measured on 1.110.0.
  #
  # The inner binary is invoked by STORE PATH, never as `glab`: on PATH
  # `glab` is this wrapper, and calling it here would recurse.
  preflight = ''
    glab_preflight() {
      local dir configFile mode host proto line

      # Spelled out rather than nested `:-` defaults so that an unset HOME
      # produces a message naming the fix instead of bash's bare
      # `HOME: unbound variable` under `set -u`. Not hypothetical here: a
      # wrapper spawned by a tool that REPLACES the environment (Claude
      # Code's MCP `env` field does exactly that — see the nix-standards
      # fragment) can arrive with no HOME at all.
      #
      # Note bash evaluates a `:-` default lazily, so the old nesting was
      # already safe whenever GLAB_CONFIG_DIR or XDG_CONFIG_HOME was set;
      # only the all-unset case aborted. This keeps that property and adds
      # the message.
      dir="''${GLAB_CONFIG_DIR:-}"
      if [ -z "$dir" ]; then
        dir="''${XDG_CONFIG_HOME:-}"
        if [ -z "$dir" ]; then
          if [ -z "''${HOME:-}" ]; then
            echo "glab: cannot locate a config directory — HOME, XDG_CONFIG_HOME and GLAB_CONFIG_DIR are all unset; set glab.configDir to name one explicitly" >&2
            return 1
          fi
          dir="$HOME/.config"
        fi
        dir="$dir/glab-cli"
      fi

      if [ ! -d "$dir" ]; then
        ${pkgs.coreutils}/bin/mkdir -p -m 0700 "$dir" || {
          echo "glab: cannot create config directory $dir" >&2
          return 1
        }
      fi
      # Both bits: a directory can be writable but not SEARCHABLE, and
      # creating or reading config.yml inside it needs `-x` as well. With
      # only `-w` that case slips through and fails later on the file
      # operation, with a message further from the cause.
      if [ ! -w "$dir" ] || [ ! -x "$dir" ]; then
        echo "glab: config directory $dir is not writable and searchable (need w+x)" >&2
        return 1
      fi

      configFile="$dir/config.yml"

      # glab HARD-REFUSES a config.yml that is not 0600 ("has the
      # permissions 664, but glab requires 600"), which a stray umask can
      # cause and which reads as a confusing failure. Repair rather than
      # refuse: a group- or world-readable glab config is never deliberate.
      if [ -f "$configFile" ]; then
        mode="$(${pkgs.coreutils}/bin/stat -c '%a' "$configFile" 2>/dev/null || echo unknown)"
        if [ "$mode" != "600" ] && [ "$mode" != "unknown" ]; then
          # Warn rather than swallow. If the repair fails — a file owned by
          # someone else, a read-only mount — glab is about to refuse with
          # the very permissions error this is here to prevent, and the
          # reader needs to know the repair was attempted and lost. Still
          # non-fatal: the caller may have meant to run a command that does
          # not touch the config at all.
          ${pkgs.coreutils}/bin/chmod 600 "$configFile" \
            || echo "glab: could not repair permissions on $configFile (mode $mode); glab requires 600 and will refuse to read it" >&2
        fi
      fi

      # glab stores BARE hostnames; the configured value may carry a
      # scheme and a path. Both strips are bash builtins, so this costs no
      # process and works with no PATH.
      host="''${GITLAB_HOST:-}"
      [ -n "$host" ] || return 0

      # Capture the scheme BEFORE stripping it. Seeding a hardcoded
      # `api_protocol https` would write a value contradicting an
      # `http://` instance — plausible for an internal or development
      # GitLab. glab's own default for the key is https, so that is the
      # right fallback when no scheme is given.
      proto=https
      case "$host" in
        http://*) proto=http ;;
      esac

      host="''${host#*://}"
      host="''${host%%/*}"

      # Fast path. A false NEGATIVE is harmless — `config set` is
      # idempotent — but a false POSITIVE is not: it skips seeding while
      # the entry is genuinely absent, which is the bug this exists to fix.
      #
      # NO REGEX. An earlier revision matched with `grep -E` and escaped
      # the dots, on the stated grounds that hostnames are [A-Za-z0-9.-]
      # so `.` was the only metacharacter possible. That was wrong:
      # GITLAB_HOST can carry a bracketed IPv6 literal (`[2001:db8::1]`),
      # where `[` and `]` either change the match or make grep error out.
      # Rather than chase a complete escaping rule, compare the trimmed
      # line to the host as a FIXED STRING — which removes the entire
      # class of escaping bugs instead of patching the current one.
      #
      # Pure builtins: the read loop, the trim, and `=` all work with no
      # PATH and spawn no process.
      if [ -f "$configFile" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
          # Strip leading whitespace; glab indents host keys, and the
          # indent width is its business, not ours.
          line="''${line#"''${line%%[![:space:]]*}"}"
          if [ "$line" = "$host:" ]; then
            return 0
          fi
        done < "$configFile"
      fi

      # Non-fatal: a seeding failure must never stop glab from running,
      # because everything except `auth status` works without it.
      #
      # But do not swallow it either, for the same reason the chmod above
      # warns. A silent failure here reproduces EXACTLY the symptom this
      # whole function exists to remove — `auth status` reporting
      # gitlab.com and no token — with nothing to connect the two. It
      # repeats on every invocation because the entry stays absent, which
      # is the point: the condition is live, not historical.
      "${lib.getExe cfg.package}" config set --host "$host" api_protocol "$proto" \
        >/dev/null 2>&1 \
        || echo "glab: could not seed the hosts: entry for $host in $configFile; \`glab auth status\` will report gitlab.com and no token until this succeeds (other commands are unaffected)" >&2
    }

    glab_preflight'';

  wrapperText = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    ${lib.concatStringsSep "\n\n" (builtins.filter (s: s != "") [configDirExport exports preflight])}

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
