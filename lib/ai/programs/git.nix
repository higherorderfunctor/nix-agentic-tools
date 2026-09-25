# `ai.programs.git` / `ai.programs.gh`: a git and GitHub CLI identity per
# harness, delivered as two environment variables on each runtime's internal
# module-env channel — `GIT_CONFIG_GLOBAL` (a store gitconfig) and
# `GH_CONFIG_DIR`. Imported by `sharedOptions.nix`, so Home Manager and devenv
# share this one module and its option tree.
#
# Deliberately NOT here:
# - No write into the user's own `programs.git`. `gitSshConfigWorkaround`
#   does that on Home Manager; an identity must not, or the agent's name
#   would become the user's.
# - No `GH_TOKEN`/`GITHUB_TOKEN`. Copilot CLI prefers either over its own
#   login, so a PAT there breaks Copilot's model access. git reads the token
#   through its credential helper; gh reads `hosts.yml` in `GH_CONFIG_DIR`.
# - Nothing on PATH. Claude's Bash tool re-runs shell init, which can put
#   the real binaries back in front; env vars survive it.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  credentials = import ../../credentials.nix {inherit lib;};
  moduleEnvironment = import ../module-environment.nix {inherit lib;};
  programFactory = import ../program.nix {inherit lib;};
  harnessNames = import ../runtimes.nix;
  specs = import ./git-options.nix {
    inherit lib;
    inherit (credentials) mkCredentialsOptionWith;
    supportedRuntimes = harnessNames;
  };
  git = programFactory.mkProgram specs.git;
  gh = programFactory.mkProgram specs.gh;

  runtimeEnabled = runtime: lib.attrByPath ["ai" runtime "enable"] false config;

  # `mkProgram` replaces a leaf when the runtime value is non-null. `settings`
  # is the one exception: a per-harness `user.name` must keep the shared
  # `user.email`, so it deep-merges root then runtime.
  resolveGit = runtime: let
    runtimeSettings = config.ai.${runtime}.programs.git.settings;
  in
    git.resolve config runtime
    // {
      settings =
        lib.recursiveUpdate config.ai.programs.git.settings
        (
          if runtimeSettings == null
          then {}
          else runtimeSettings
        );
    };

  # The signer each format runs, pinned so signing does not depend on PATH.
  # Same programs Home Manager's git module defaults to.
  signers = {
    openpgp = lib.getExe' pkgs.gnupg "gpg";
    ssh = lib.getExe' pkgs.openssh "ssh-keygen";
    x509 = lib.getExe' pkgs.gnupg "gpgsm";
  };

  # git runs an absolute helper path as `<helper> get|store|erase`. Only `get`
  # answers. The secret is read when git asks, so only its PATH is in the
  # store. A missing or empty secret must STOP git, not merely fail: git
  # ignores a helper's exit status and moves on to askpass (`SSH_ASKPASS`, or a
  # `core.askPass` from the included user config) and then the terminal. Only
  # a `quit=1` answer ends the lookup, so any failure path prints it.
  credentialHelper = secret:
    pkgs.writeShellApplication {
      name = "ai-git-credential-github";
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
      text = ''
        shopt -s inherit_errexit 2>/dev/null || :

        [ "''${1:-}" = get ] || exit 0
        trap '[ "$?" -eq 0 ] || printf "quit=1\n"' EXIT
        ${credentials.mkSecretAssignment pkgs "ai_git_token" secret}
        printf 'username=x-access-token\npassword=%s\n' "$ai_git_token"
      '';
    };

  # `GIT_CONFIG_GLOBAL` REPLACES both the XDG config and `~/.gitconfig`, so
  # the file includes them, in git's own order: XDG first, so `~/.gitconfig`
  # wins a key both set, as it does natively. git expands `~` in an include
  # path but no environment variable, so the XDG root is fixed at evaluation:
  # Home Manager's `xdg.configHome`, elsewhere git's default `~/.config`.
  userConfigs = [
    "${lib.attrByPath ["xdg" "configHome"] "~/.config" config}/git/config"
    "~/.gitconfig"
  ];

  # Everything after the include. `commit.gpgSign`, `tag.gpgSign` and
  # `tag.forceSignAnnotated` are ALWAYS written: left unset, a user config
  # that signs by default would sign the agent's commits, or its `git tag -m`
  # tags, with the user's key.
  gitconfigBody = cfg: let
    inherit (cfg) signing;
    derived = lib.foldl' lib.recursiveUpdate {} [
      (lib.optionalAttrs (signing.key != null) {user.signingKey = signing.key;})
      (lib.optionalAttrs (signing.format != null) {
        gpg = {
          inherit (signing) format;
          ${signing.format}.program = signers.${signing.format};
        };
      })
      {
        commit.gpgSign = signing.signByDefault;
        tag = {
          forceSignAnnotated = signing.signByDefault;
          gpgSign = signing.signByDefault;
        };
      }
      # The empty value resets the helper list, dropping every helper the
      # included user config set. Without it an agent push that this helper
      # cannot answer falls through to the user's own token.
      (lib.optionalAttrs (cfg.credentials != null) {
        credential."https://github.com".helper = ["" (lib.getExe (credentialHelper cfg.credentials))];
      })
    ];
  in
    lib.recursiveUpdate derived cfg.settings;

  # Two renders, concatenated. `toGitINI` sorts sections, which would put
  # `[commit]`, `[credential …]` and `[gpg]` BEFORE `[include]` — and since
  # the last value wins, the user's included config would then override the
  # agent's signing and re-append the user's credential helper after the
  # reset. The include must be the first section.
  renderGitconfig = runtime: body:
    pkgs.writeText "ai-gitconfig-${runtime}" (
      lib.generators.toGitINI {
        include.path = userConfigs ++ lib.toList (body.include.path or []);
      }
      + lib.generators.toGitINI (removeAttrs body ["include"])
    );

  states = lib.genAttrs harnessNames (runtime: let
    gitCfg = resolveGit runtime;
    ghCfg = gh.resolve config runtime;
    enabled = runtimeEnabled runtime;
    body = gitconfigBody gitCfg;
  in {
    inherit body ghCfg gitCfg runtime;
    gitActive = enabled && gitCfg.enable;
    ghActive = enabled && ghCfg.enable;
    gitconfig = renderGitconfig runtime body;
  });

  # `publish` also reaches runtimes built with the public `mkRuntime`, which
  # this module has no identity for.
  envFor = runtime:
    lib.optionalAttrs (states ? ${runtime}) (let
      state = states.${runtime};
    in
      lib.optionalAttrs state.gitActive {GIT_CONFIG_GLOBAL = "${state.gitconfig}";}
      // lib.optionalAttrs (state.ghActive && state.ghCfg.configDir != null) {
        GH_CONFIG_DIR = state.ghCfg.configDir;
      });

  # The value git would read for `section.key` in the rendered body. git
  # matches section and key names case-insensitively and the last value
  # wins; `toGitINI` renders names in sorted order, so every spelling is
  # collected in that order and the last one taken. `settings` deep-merges
  # by exact name, so `commit.gpgsign` sits BESIDE the derived `gpgSign`
  # rather than replacing it.
  gitValue = body: section: key: let
    matching = name: attrs:
      lib.filter (candidate: lib.toLower candidate == lib.toLower name) (lib.attrNames attrs);
    values = lib.concatMap (sectionName: let
      sectionBody = body.${sectionName};
    in
      lib.optionals (lib.isAttrs sectionBody)
      (lib.concatMap (keyName: lib.toList sectionBody.${keyName}) (matching key sectionBody)))
    (matching section body);
  in
    if values == []
    then null
    else lib.last values;

  # git's boolean spellings: `true`/`yes`/`on` in any case, or a non-zero
  # integer.
  gitTrue = value:
    value
    == true
    || (lib.isInt value && value != 0)
    || (lib.isString value
      && (lib.elem (lib.toLower value) ["true" "yes" "on"]
        || (builtins.match "-?[0-9]+" value != null && builtins.match "-?0+" value == null)));

  underStore = path: path != null && lib.hasPrefix "${builtins.storeDir}/" path;

  # Judged on the rendered body, as git reads it, so signing switched on
  # through `settings` — in any key spelling — is held to the same rule and a
  # key supplied there counts.
  assertionsFor = state: let
    prefix = "ai.${state.runtime}.programs";
    read = gitValue state.body;
    signs = lib.any gitTrue [
      (read "commit" "gpgSign")
      (read "tag" "forceSignAnnotated")
      (read "tag" "gpgSign")
    ];
    tokenFile = (state.gitCfg.credentials or {}).file or null;
  in
    lib.optionals state.gitActive [
      {
        assertion = !signs || read "user" "signingKey" != null;
        message = "${prefix}.git signs commits or tags but no signing key resolves for ${state.runtime}. Set ai.programs.git.signing.key or ${prefix}.git.signing.key; git would otherwise sign with whatever key your own config names, or fail.";
      }
      {
        assertion = !signs || read "gpg" "format" != null;
        message = "${prefix}.git signs commits or tags but no signing format resolves for ${state.runtime}. Set ai.programs.git.signing.format (\"ssh\", \"openpgp\" or \"x509\").";
      }
      {
        assertion = tokenFile == null || lib.hasPrefix "/" tokenFile;
        message = "${prefix}.git.credentials.file is not an absolute path. The credential helper reads it verbatim: nothing expands `~`, and a relative path resolves against the repository git is working in. Pass an absolute path.";
      }
      {
        assertion = !underStore tokenFile;
        message = "${prefix}.git.credentials.file points into ${builtins.storeDir}, where the token is world-readable. Pass the path of a decrypted secret as a string.";
      }
    ]
    ++ lib.optionals state.ghActive [
      {
        assertion = state.ghCfg.configDir != null;
        message = "${prefix}.gh.enable needs a config directory: set ai.programs.gh.configDir or ${prefix}.gh.configDir.";
      }
      {
        assertion = state.ghCfg.configDir == null || lib.hasPrefix "/" state.ghCfg.configDir;
        message = "${prefix}.gh.configDir is not an absolute path. It is published verbatim as GH_CONFIG_DIR: nothing expands `~`, and a relative path resolves against the harness's working directory. Pass an absolute path.";
      }
      {
        assertion = !underStore state.ghCfg.configDir;
        message = "${prefix}.gh.configDir points into ${builtins.storeDir}, where hosts.yml and its token are world-readable and gh cannot write. Pass a writable directory outside the store as a string.";
      }
    ];
in {
  imports = [git.module gh.module];

  config = lib.mkMerge [
    (lib.optionalAttrs (options ? assertions) {
      assertions = lib.concatMap assertionsFor (lib.attrValues states);
    })
    (moduleEnvironment.publish options envFor)
  ];
}
