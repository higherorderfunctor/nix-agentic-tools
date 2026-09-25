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
{
  lib,
  mkCredentialsOptionWith,
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
    # `git.nix` deep-merges `settings` itself; the generated "non-null wins"
    # sentence would contradict that.
    overrideDescriptions.settings = ''
      Runtime override for the portable program option. Deep-merged over
      `ai.programs.git.settings`, root first and this value on top; null adds
      nothing.
    '';
    options = {
      enable = lib.mkEnableOption ''
        a per-harness git identity. Each enabled harness gets its own gitconfig
        in the store, published as `GIT_CONFIG_GLOBAL` on the harness's
        process environment (Claude: `settings.env`). That file includes the
        XDG `git/config` and `~/.gitconfig` FIRST, in git's own order, so your
        aliases and tooling still apply and everything set here overrides
        them. git expands no environment variable in an include path, so the
        XDG file is Home Manager's `xdg.configHome`, and `~/.config` on devenv
        whatever `$XDG_CONFIG_HOME` says. The project shell and your own
        `programs.git` are never touched. The identity covers HTTPS to
        github.com: a remote that stays SSH (including one a `pushInsteadOf`
        in your own config rewrites to SSH) still authenticates as whoever
        your SSH config says
      '';

      credentials = mkCredentialsOptionWith {
        description = ''
          The GitHub token git pushes and fetches with. Renders an empty
          `credential."https://github.com".helper` (dropping every helper
          your own config set, so a push never falls back to your token)
          and then a store helper that reads this secret on every
          credential request and answers `username=x-access-token`; if the
          secret is missing or empty it tells git to stop rather than
          prompt. Only the path reaches the store, and the token is never
          put in the environment. A `helper` executable runs on every
          request, not once at start. Set exactly one of `file` or `helper`.

          Left null, nothing is reset: git uses whatever helper your own
          config sets for github.com, which may be your token.
        '';
        file = ''
          Path to a file holding the raw GitHub token, read by the credential
          helper on every request git makes for https://github.com. Only the
          path reaches the store. Works with sops-nix, agenix, or any tool
          that decrypts secrets to files.
        '';
        helper = ''
          Path to an executable that prints the raw GitHub token on stdout.
          The credential helper runs it on every request git makes for
          https://github.com, not once at start.
        '';
      };

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
          the file always includes first. A key left unset here, such as
          `user.name` or `user.email`, is inherited from your own included
          config.
        '';
      };

      signing = {
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

        key = lib.mkOption {
          type = lib.types.nullOr signingKeyType;
          default = null;
          example = "/run/user/1000/secrets/claude-signing-key";
          description = ''
            Path to the signing key, rendered as `user.signingKey`. For
            `format = "ssh"` this is the private key file, read by `ssh-keygen`
            at signing time, so no agent is involved. A string, never a Nix
            path, and never under the store: either would publish the key.
            Left null, the `user.signingKey` from your own included config
            stays in effect, so an explicit `git commit -S` or `git tag -s`
            by the agent signs with the key your own config names.
          '';
        };

        signByDefault = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Sign every commit and tag. Rendered as `commit.gpgSign`,
            `tag.gpgSign` and `tag.forceSignAnnotated` whether true or false,
            so a signing default in your own config never signs the agent's
            commits or annotated tags with your key.
            Evaluation fails for an enabled harness that signs (through this
            or `settings`) while no key or format resolves.
          '';
        };
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
        prefer it over its own login. Nothing is unset either: gh prefers an
        inherited `GH_TOKEN` or `GITHUB_TOKEN` over `hosts.yml`, so a harness
        launched from a shell exporting one acts as that token's account, not
        as this identity. On Copilot, `GH_CONFIG_DIR` also becomes the source
        of its last-resort `gh` login, so that fallback now uses this
        directory's token
      '';

      configDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/home/me/.config/ai-gh";
        description = ''
          Directory holding the harness's `gh` `config.yml` and `hosts.yml`,
          published as `GH_CONFIG_DIR`. It is not created or written here:
          render `hosts.yml` (it holds the token) with your secrets tool, or
          run `gh auth login` against it once. Required when `enable` is set;
          evaluation fails for a directory under the store, where the token
          would be world-readable and gh cannot write.
        '';
      };
    };
  };
}
