# lib/credentials.nix — secret-handling primitives shared by any module
# that must get a value to a program WITHOUT baking it into the Nix store.
#
# Lifted out of lib/mcp.nix when a second, non-MCP consumer appeared
# (packages/glab). `mkCredentialsOption` and `mkCredentialsSnippet` are
# unchanged and re-exported from lib/mcp.nix, so every MCP server module
# keeps the exact option type and shell output it had before.
#
# The shared invariant across all of these: a secret is read at RUNTIME,
# from a path or a helper command, never interpolated into a derivation.
# Everything under /nix/store is world-readable.
{lib}: let
  inherit
    (lib)
    concatStringsSep
    mapAttrsToList
    mkOption
    types
    ;

  # ── Credentials option generator ──────────────────────────────────
  # Creates a discriminated union (attrTag) option for a single credential.
  # Exactly one of `file` or `helper` may be set; the type system enforces
  # mutual exclusion (no runtime assertion needed). Wrapped in nullOr so
  # optional credentials default to null.
  mkCredentialsOption = envVar:
    mkOption {
      type = types.nullOr (types.attrTag {
        file = mkOption {
          type = types.str;
          description = ''
            Path to a file containing the raw secret value, read at runtime.
            Not stored in the Nix store. Works with sops-nix, agenix, or any
            tool that decrypts secrets to files. Mapped to ${envVar}.
          '';
        };
        helper = mkOption {
          type = types.str;
          description = ''
            Path to an executable that outputs the raw secret value on stdout.
            Executed at service start. Mapped to ${envVar}.
          '';
        };
      });
      default = null;
      description = "Credential mapped to ${envVar}. Set exactly one of file or helper.";
    };

  # ── Secret option: credential PLUS an in-store literal ────────────
  # Same shape as `mkCredentialsOption` with a third branch, `plain`, for
  # a value the consumer is happy to have in the Nix store.
  #
  # A THREE-BRANCH `attrTag` rather than a `plain` string option beside a
  # nullable credential, because the two-option spelling can express the
  # invalid state — both set at once — and can then only reject it with a
  # runtime `throw`. `packages/gitlab-mcp/modules/mcp-server.nix` carries
  # exactly that `throw` today, and its own comment calls it UNVERIFIED
  # and asks for "a discriminated union so the invalid state can't be
  # constructed". This is that union. Retrofitting gitlab-mcp onto it is
  # deliberately NOT part of this change.
  #
  # `plain` is offered because not every configurable value is a secret:
  # a public GitLab host is ordinary configuration, and forcing it through
  # a file indirection would be ceremony. The description says plainly
  # which branch leaks and which does not, so the choice is informed
  # rather than accidental.
  mkSecretOption = {
    envVar,
    description,
  }:
    mkOption {
      type = types.nullOr (types.attrTag {
        plain = mkOption {
          type = types.str;
          description = ''
            Literal value, interpolated into the Nix store and therefore
            WORLD-READABLE. Correct for public configuration; never use it
            for a token. Mapped to ${envVar}.
          '';
        };
        file = mkOption {
          type = types.str;
          description = ''
            Path to a file containing the raw value, read at runtime and
            never placed in the Nix store. Works with sops-nix, agenix, or
            anything else that decrypts to a file. Mapped to ${envVar}.
          '';
        };
        helper = mkOption {
          type = types.str;
          description = ''
            Path to an executable printing the raw value on stdout, run at
            invocation time. Nothing is placed in the Nix store. Mapped to
            ${envVar}.
          '';
        };
      });
      default = null;
      description = ''
        ${description}

        Set exactly one of `plain`, `file` or `helper`; the type system
        rejects any other combination, so there is no runtime check to
        forget. Mapped to ${envVar}.
      '';
    };

  # Shell lines exporting ONE secret, or "" when it is unset.
  #
  # Absolute store paths for every external command — a wrapper spawned by
  # a tool that REPLACES the process environment (Claude Code's MCP `env`
  # field does exactly this) has no PATH, and a bare `cat` there fails
  # silently enough to look like a missing credential. See the
  # nix-standards fragment.
  # NOTE ON QUOTING — the `file` and `helper` branches use hand-written
  # `"${...}"` and NOT `escapeShellArg`, deliberately, and a review bot
  # has already suggested "fixing" this once.
  #
  # Both are already double-quoted, so a path containing WHITESPACE works
  # — that part of the suggestion was simply wrong. What escapeShellArg
  # would additionally buy is safety against a path containing a literal
  # `"`, and that is not a privilege boundary: the value comes from the
  # reader's own Nix configuration, and anyone who can set it can already
  # run arbitrary code at eval time.
  #
  # Against that, changing it is not free. This code MOVED here from
  # lib/mcp.nix unchanged, and every MCP server wrapper is generated from
  # it — re-quoting churns their store paths, and
  # `checks/module-eval.nix`'s `module-kimchi-wrapper-builds` asserts the
  # double-quoted form directly (`grep -q 'cat "/run/secrets/..."'`).
  # Hardening it is a defensible standalone change; it is not a drive-by.
  #
  # `plain` DOES use escapeShellArg, because it is new code and its value
  # is arbitrary user text rather than a path.
  # ── Empty-value guard ─────────────────────────────────────────────
  # An empty secret is never a usable one, and letting it through is a
  # SILENT failure with real consequences: the consuming program falls
  # back to its own default. For an MCP server that means starting
  # unauthenticated (a mode this repo has already lost weeks to — see the
  # nix-standards fragment's account of github-mcp/kagi-mcp); for glab it
  # means `host` falling back to gitlab.com and a self-managed token being
  # sent to the wrong instance.
  #
  # A sops/agenix file is empty far more often than one would like: a
  # rotation that half-applied, a key the reader cannot decrypt, a
  # template that rendered nothing. None of those announce themselves.
  #
  # `${ref}` rather than an indirect expansion because envVar is known at
  # generation time — the emitted line is a plain `[ -z "$GITLAB_TOKEN" ]`.
  emptyGuard = envVar: source: let
    ref = "$" + envVar;
  in ''
    if [ -z "${ref}" ]; then
      echo "${envVar} resolved empty from ${source} — refusing to continue, since the program would silently fall back to its default" >&2
      exit 1
    fi'';

  # ── Missing-file guard ────────────────────────────────────────────
  # Sibling of `emptyGuard`, for the failure one step earlier. Without it
  # a missing secret surfaces as a bare `cat: /run/…: No such file or
  # directory` — true, but it names neither the variable nor the option
  # that is misconfigured, and under `set -e` it aborts before the empty
  # guard's much better message can fire.
  #
  # The distinction is worth keeping separate from `emptyGuard`: a MISSING
  # file usually means the secret was never declared or the path is wrong,
  # while an EMPTY one usually means decryption or templating produced
  # nothing. Those send the reader to different places.
  # Two conditions, not one. `-r` alone is TRUE for a readable DIRECTORY
  # (measured), so a path pointing at a secrets directory rather than a
  # secret inside it sails past the guard and dies one line later on
  # `cat: …: Is a directory` — a message with none of the context this
  # guard exists to add.
  #
  # Testing `-d` rather than switching to `-f` on purpose: `-f` would also
  # reject a FIFO or character device, and those are readable by `cat` and
  # are a legitimate, if unusual, way to hand a process a secret. Reject
  # the case that is definitely wrong, not everything that is unusual.
  missingFileGuard = envVar: source: ''
    if [ -d "${source}" ]; then
      echo "${envVar} cannot be read from ${source} — that path is a directory, not a secret file" >&2
      exit 1
    fi
    if [ ! -r "${source}" ]; then
      echo "${envVar} cannot be read from ${source} — the file is missing or unreadable; check that the secret is declared and decrypted" >&2
      exit 1
    fi'';

  mkSecretExport = pkgs: envVar: secret:
    if secret == null
    then ""
    else if secret ? helper
    then ''
      ${envVar}="$("${secret.helper}")"
      ${emptyGuard envVar secret.helper}
      export ${envVar}''
    else if secret ? file
    then ''
      ${missingFileGuard envVar secret.file}
      ${envVar}="$(${pkgs.coreutils}/bin/cat "${secret.file}")"
      ${emptyGuard envVar secret.file}
      export ${envVar}''
    else if secret ? plain
    then ''
      ${envVar}=${lib.escapeShellArg secret.plain}
      export ${envVar}''
    else "";

  # ── Credentials helpers ──────────────────────────────────────────
  # credentialVars: { settingsOptionName = { envVar = "ENV_VAR"; ... }; }
  # settings: evaluated settings attrset — keys are looked up there.
  mkCredentialsSnippet = pkgs: credentialVars: settings:
    concatStringsSep "\n" (mapAttrsToList (optName: spec:
      mkSecretExport pkgs spec.envVar settings.${optName})
    credentialVars);
in {
  inherit
    mkCredentialsOption
    mkCredentialsSnippet
    mkSecretExport
    mkSecretOption
    ;
}
