# Option declarations for `ai.programs.git` and `ai.programs.gh`: the git and
# GitHub CLI identity each harness runs with. `mkProgram` turns every leaf
# into a nullable `ai.<runtime>.programs.<name>` override as well, so the
# shared account (email, token) sits at the root and the per-harness name and
# signing key at the runtime.
#
# The leaf names are Home Manager's (`programs.git.settings`,
# `programs.git.signing.*`), cut down to what an identity needs. The token uses
# the repository's `credentials` type. This is not a mirror of Home Manager's
# modules: devenv has neither, and vendoring them would break config parity.
#
# One file, imported by `git.nix`, which `sharedOptions.nix` imports on both
# backends — so the two option trees cannot drift.
# cspell:ignore gpgsm openpgp
{
  lib,
  mkCredentialsOption,
  supportedRuntimes,
}: let
  # Home Manager's `programs.git.settings` type, restated: devenv has no
  # Home Manager to borrow it from.
  gitIniType = let
    primitive = lib.types.oneOf [lib.types.bool lib.types.int lib.types.str];
    multiple = lib.types.either primitive (lib.types.listOf primitive);
    section = lib.types.attrsOf multiple;
  in
    lib.types.attrsOf (lib.types.attrsOf (lib.types.either multiple section));

  # A string, never a `path`: a path literal would copy the private key into
  # the world-readable store. A string that already points there is refused
  # for the same reason.
  signingKeyType =
    lib.types.addCheck lib.types.str (value: !lib.hasPrefix "${builtins.storeDir}/" value)
    // {
      description = "string path outside ${builtins.storeDir} (a key in the store is world-readable)";
    };
in {
  git = {
    name = "git";
    inherit supportedRuntimes;
    options = {
      enable = lib.mkEnableOption ''
        a per-harness git identity. Each enabled harness gets its own gitconfig
        in the store, published as `GIT_CONFIG_GLOBAL` on the harness's
        process environment (Claude: `settings.env`). That file includes
        `~/.gitconfig` and the XDG `git/config` FIRST, so your own aliases and
        tooling still apply and everything set here overrides them. The
        project shell and your own `programs.git` are never touched
      '';

      settings = lib.mkOption {
        type = gitIniType;
        default = {};
        example = lib.literalExpression ''
          {
            user.email = "bot@example.com";
            url."https://github.com/".insteadOf = ["git@github.com:" "ssh://git@github.com/"];
          }
        '';
        description = ''
          Git configuration, as Home Manager's `programs.git.settings`.
          UNLIKE the other leaves, the root and runtime values are DEEP-merged
          (root first, runtime on top), so `ai.<runtime>.programs.git.settings.user.name`
          keeps the root `user.email`. Keys derived from `signing` and
          `credentials` are defaults; an explicit entry here at the same key
          wins. `include.path` entries are appended after the user configs
          the file always includes first.
        '';
      };

      signing = {
        key = lib.mkOption {
          type = lib.types.nullOr signingKeyType;
          default = null;
          example = "/run/user/1000/secrets/claude-signing-key";
          description = ''
            Path to the signing key, rendered as `user.signingKey`. For
            `format = "ssh"` this is the private key file, read by `ssh-keygen`
            at signing time, so no agent is involved. A string, never a Nix
            path, and never under the store: either would publish the key.
          '';
        };

        format = lib.mkOption {
          type = lib.types.nullOr (lib.types.enum ["openpgp" "ssh" "x509"]);
          default = null;
          description = ''
            Signature format, rendered as `gpg.format`, with
            `gpg.<format>.program` pinned to the store signer (`gpg`,
            `ssh-keygen`, `gpgsm`) as Home Manager does, so signing does not
            depend on PATH. No legacy default: set it explicitly.
          '';
        };

        signByDefault = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Sign every commit and tag (`commit.gpgSign`, `tag.gpgSign`).
            Evaluation fails for an enabled harness whose resolved `key` or
            `format` is null, so there is no silent unsigned fallback.
          '';
        };
      };

      credentials =
        mkCredentialsOption "the password git's credential helper returns for https://github.com"
        // {
          description = ''
            The GitHub token git pushes and fetches with. Renders an empty
            `credential."https://github.com".helper` (dropping every helper
            your own config set, so a push never falls back to your token)
            and then a store helper that reads this secret when git asks and
            answers `username=x-access-token`. Only the path reaches the
            store, and the token is never put in the environment. Set exactly
            one of `file` or `helper`.
          '';
        };
    };
  };

  gh = {
    name = "gh";
    inherit supportedRuntimes;
    options = {
      enable = lib.mkEnableOption ''
        the GitHub CLI config directory below for each enabled harness,
        published as `GH_CONFIG_DIR`. No `GH_TOKEN` is set: Copilot CLI would
        prefer it over its own login
      '';

      configDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/home/me/.config/ai-gh";
        description = ''
          Directory holding the harness's `gh` `config.yml` and `hosts.yml`,
          published as `GH_CONFIG_DIR`. It is not created or written here:
          render `hosts.yml` (it holds the token) with your secrets tool, or
          run `gh auth login` against it once. Required when `enable` is set.
        '';
      };
    };
  };
}
