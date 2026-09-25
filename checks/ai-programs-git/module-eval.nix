# `ai.programs.git` / `ai.programs.gh` — the per-harness git and gh identity
# (lib/ai/programs/git.nix). Both backends, every runtime from the registry.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm harnessNames mkTest;
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };

  # Light stand-ins, so a wrapper test builds a makeWrapper script rather than
  # a whole CLI. The real packages' wrapping is covered by their own checks.
  exes = {
    claude = "claude";
    codex = "codex";
    copilot = "copilot";
    kimchi = "kimchi";
    kiro = "kiro-cli";
  };
  stub = exe:
    pkgs.writeShellScriptBin exe ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      exit 0
    '';
  launcherRuntimes = lib.remove "claude" harnessNames;

  tokenFile = "/run/secrets/ai-github-token";
  ghDir = "/run/ai-gh";
  keyFor = runtime: "/run/secrets/ai-${runtime}-signing-key";

  # The design's consumer shape: shared email, token and signing policy at the
  # root; each harness's own name and key at the runtime.
  identity = {
    ai =
      lib.genAttrs harnessNames (runtime: {
        enable = true;
        package = stub exes.${runtime};
        programs.git = {
          settings.user.name = "bot (${runtime})";
          signing.key = keyFor runtime;
        };
      })
      // {
        programs = {
          git = {
            enable = true;
            settings = {
              user.email = "bot@example.com";
              url."https://github.com/".insteadOf = ["git@github.com:" "ssh://git@github.com/"];
            };
            signing = {
              format = "ssh";
              signByDefault = true;
            };
            credentials.file = tokenFile;
          };
          gh = {
            enable = true;
            configDir = ghDir;
          };
        };
      };
  };

  channel = ev: runtime: ev.config.ai.${runtime}.internal._moduleEnvironmentVariables;
  claudeEnv = backend: ev:
    if backend == "hm"
    then ev.config.programs.claude-code.settings.env or {}
    else ev.config.files.".claude/settings.json".json.env or {};
  failedMessages = ev:
    map (entry: entry.message)
    (builtins.filter (entry: !entry.assertion) ev.config.assertions);
  ourFailures = ev: builtins.filter (lib.hasInfix ".programs.g") (failedMessages ev);

  # Every leaf under the two programs at both levels. Each program is a
  # submodule option, so descend through its type rather than the option.
  optionNames = ev: let
    programOptions =
      [ev.options.ai.programs.git ev.options.ai.programs.gh]
      ++ lib.concatMap (runtime: [
        ev.options.ai.${runtime}.programs.git
        ev.options.ai.${runtime}.programs.gh
      ])
      harnessNames;
    leaves = option: lib.collect lib.isOption (option.type.getSubOptions option.loc);
  in
    lib.sort lib.lessThan (map (option: lib.showOption option.loc) (lib.concatMap leaves programOptions));

  tokenKeys = ["GH_TOKEN" "GITHUB_TOKEN"];
in {
  checks = {
    # The declarations are one file imported by sharedOptions.nix on both
    # backends; this is what keeps it that way. The `elem` probes are the
    # positive control: an empty tree on both sides would compare equal.
    module-ai-programs-git-hm-devenv-option-parity = mkTest "ai-programs-git-hm-devenv-option-parity" (
      let
        hm = optionNames (evalHm {});
      in
        hm
        == optionNames (evalDevenv {})
        && builtins.all (name: builtins.elem name hm) [
          "ai.programs.git.credentials"
          "ai.programs.git.settings"
          "ai.programs.git.signing.format"
          "ai.programs.git.signing.key"
          "ai.programs.git.signing.signByDefault"
          "ai.programs.gh.configDir"
          "ai.claude.programs.git.signing.key"
          "ai.kimchi.programs.gh.configDir"
        ]
    );

    # Off by default, and never a write into the user's own git config: the
    # Home Manager `programs.git.settings` carries only the SSH workaround.
    module-ai-programs-git-inert-and-hands-off = mkTest "ai-programs-git-inert-and-hands-off" (
      let
        off = evalHm {ai.codex.enable = true;};
        on = evalHm identity;
      in
        !((channel off "codex") ? GIT_CONFIG_GLOBAL)
        && !((channel off "codex") ? GH_CONFIG_DIR)
        && builtins.attrNames on.config.programs.git.settings == ["core"]
        && builtins.attrNames on.config.programs.git.settings.core == ["sshCommand"]
    );

    # GIT_CONFIG_GLOBAL and GH_CONFIG_DIR reach every runtime on both backends,
    # the gitconfig differs per runtime (each has its own name and key), and no
    # token variable is emitted anywhere. Claude is checked at its real sink,
    # `settings.env`; the launcher runtimes by the wrapper test below.
    module-ai-programs-git-env-per-runtime = mkTest "ai-programs-git-env-per-runtime" (
      builtins.all (backend: let
        ev = backends.${backend} identity;
        configs = map (runtime: (channel ev runtime).GIT_CONFIG_GLOBAL or null) harnessNames;
        claude = claudeEnv backend ev;
      in
        builtins.all (value: value != null && lib.hasPrefix builtins.storeDir value) configs
        && lib.length (lib.unique configs) == lib.length harnessNames
        && builtins.all (runtime: (channel ev runtime).GH_CONFIG_DIR or null == ghDir) harnessNames
        && builtins.all (runtime: lib.hasSuffix "-ai-gitconfig-${runtime}" (channel ev runtime).GIT_CONFIG_GLOBAL) harnessNames
        && (claude.GIT_CONFIG_GLOBAL or null) == (channel ev "claude").GIT_CONFIG_GLOBAL
        && (claude.GH_CONFIG_DIR or null) == ghDir
        && builtins.all (key: !(claude ? ${key})) tokenKeys
        && builtins.all (runtime: builtins.all (key: !((channel ev runtime) ? ${key})) tokenKeys) harnessNames
        && ourFailures ev == [])
      (builtins.attrNames backends)
    );

    # A runtime can opt out, and a consumer's explicit entry still wins over
    # the module default (the channel's existing contract).
    module-ai-programs-git-runtime-opt-out-and-consumer-wins = mkTest "ai-programs-git-runtime-opt-out-and-consumer-wins" (
      builtins.all (backend: let
        ev = backends.${backend} (lib.recursiveUpdate identity {
          ai = {
            codex.programs.git.enable = false;
            claude.native.settings.env.GIT_CONFIG_GLOBAL = "/explicit/gitconfig";
          };
        });
      in
        !((channel ev "codex") ? GIT_CONFIG_GLOBAL)
        && (channel ev "codex").GH_CONFIG_DIR == ghDir
        && (claudeEnv backend ev).GIT_CONFIG_GLOBAL == "/explicit/gitconfig")
      (builtins.attrNames backends)
    );

    # A key under the store is world-readable; the type refuses it at either
    # level. The /run value is the positive control: the same probe must
    # succeed when only the path changes.
    module-ai-programs-git-store-signing-key-rejected = mkTest "ai-programs-git-store-signing-key-rejected" (
      let
        # Force BOTH levels: a store key at either one must throw.
        probe = settings: let
          inherit ((evalHm settings).config.ai) programs claude;
        in
          (builtins.tryEval (builtins.deepSeq [
              programs.git.signing.key
              claude.programs.git.signing.key
            ]
            true)).success;
        storeKey = "${builtins.storeDir}/00000000000000000000000000000000-key";
      in
        !(probe {ai.programs.git.signing.key = storeKey;})
        && !(probe {ai.claude.programs.git.signing.key = storeKey;})
        && probe {ai.programs.git.signing.key = "/run/secrets/key";}
        && probe {ai.claude.programs.git.signing.key = "/run/secrets/key";}
    );

    # Signing with nothing to sign with is an eval error (assertion), judged
    # on the rendered body so `settings` is held to the same rule; so is a
    # token under the store and gh without a directory. Only enabled runtimes
    # are held to it, and the full identity is the positive control.
    module-ai-programs-git-assertions = mkTest "ai-programs-git-assertions" (
      builtins.all (backend: let
        eval = config: backends.${backend} (lib.recursiveUpdate identity config);
        noKey = eval {ai.kiro.programs.git.signing.key = null;};
        noFormat = eval {ai.programs.git.signing.format = null;};
        settingsSigns = eval {
          ai = {
            programs.git = {
              signing.signByDefault = false;
              settings.commit.gpgSign = true;
            };
            kiro.programs.git.signing.key = null;
          };
        };
        keyViaSettings = eval {
          ai.kiro.programs.git = {
            signing.key = null;
            settings.user.signingKey = "/run/secrets/kiro-key";
          };
        };
        storeToken = eval {ai.programs.git.credentials.file = "${builtins.storeDir}/00000000000000000000000000000000-token";};
        noGhDir = eval {ai.programs.gh.configDir = null;};
        disabledRuntime = eval {
          ai.kiro = {
            enable = false;
            programs.git.signing.key = null;
          };
        };
        only = prefix: ev: let
          failures = ourFailures ev;
        in
          failures != [] && builtins.all (lib.hasPrefix prefix) failures;
      in
        only "ai.kiro.programs.git signs commits or tags but no signing key" noKey
        && lib.length (ourFailures noFormat) == lib.length harnessNames
        && builtins.any (lib.hasPrefix "ai.claude.programs.git signs commits or tags but no signing format") (ourFailures noFormat)
        && only "ai.kiro.programs.git signs commits or tags but no signing key" settingsSigns
        && ourFailures keyViaSettings == []
        && lib.length (ourFailures storeToken) == lib.length harnessNames
        && builtins.any (lib.hasPrefix "ai.codex.programs.git.credentials.file points into") (ourFailures storeToken)
        && builtins.any (lib.hasPrefix "ai.codex.programs.gh.enable needs a config directory") (ourFailures noGhDir)
        && ourFailures disabledRuntime == []
        && ourFailures (backends.${backend} identity) == [])
      (builtins.attrNames backends)
    );

    # The rendered file, read by real git against a fake HOME whose configs
    # stand in for the user's: an XDG config and a `~/.gitconfig` that signs
    # by default with the user's key, sets a github.com helper and an askpass
    # that would answer with the user's secret. Covers: `[include]` is the
    # FIRST section and keeps git's own XDG-then-home order; the per-runtime
    # `user.name` deep-merges with the root `user.email`; the credential reset
    # comes AFTER the user's helper; signing pins the store ssh-keygen and,
    # when off, is written off rather than inherited; the helper answers `get`
    # with the token, and on a missing token tells git to quit instead of
    # falling through to askpass.
    module-ai-programs-git-rendered-gitconfig = let
      hm = evalHm identity;
      devenv = evalDevenv identity;
      file = ev: runtime: (channel ev runtime).GIT_CONFIG_GLOBAL;
      tokenHelper = pkgs.writeShellScript "fake-token-helper" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf '%s\n' fake-token
      '';
      # Replace the credential outright: a recursive merge would set both arms.
      withHelper = evalHm (lib.updateManyAttrsByPath [
          {
            path = ["ai" "programs" "git" "credentials"];
            update = _: {helper = "${tokenHelper}";};
          }
        ]
        identity);
      unsigned = evalHm (lib.recursiveUpdate identity {ai.programs.git.signing.signByDefault = false;});
      askpass = pkgs.writeShellScript "operator-askpass" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf '%s\n' OPERATOR_SECRET
      '';
      userGitconfig = pkgs.writeText "user-gitconfig" ''
        [user]
          name = the-operator
          email = operator@example.com
          signingKey = /home/operator/.ssh/signing_key
        [alias]
          who = home
        [core]
          askPass = ${askpass}
        [credential "https://github.com"]
          helper = operator-helper
        [commit]
          gpgSign = true
        [tag]
          gpgSign = true
      '';
      xdgGitconfig = pkgs.writeText "xdg-gitconfig" ''
        [alias]
          who = xdg
      '';
    in
      pkgs.runCommand "module-test-ai-programs-git-rendered-gitconfig" {nativeBuildInputs = [pkgs.git];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        fail() {
          echo "FAIL: ai-programs-git-rendered-gitconfig: $1" >&2
          exit 1
        }
        # `--global` alone reads ONE file and skips its includes (git's rule
        # for any specific file), which would hide exactly what is tested.
        cfg() {
          git config --includes --global "$@"
        }
        fill() {
          printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill
        }
        export HOME="$PWD/home"
        mkdir -p "$HOME/.config/git"
        cp ${userGitconfig} "$HOME/.gitconfig"
        cp ${xdgGitconfig} "$HOME/.config/git/config"

        ${lib.concatMapStringsSep "\n" (runtime: ''
            export GIT_CONFIG_GLOBAL=${file hm runtime}
            [ "$(head -n1 "$GIT_CONFIG_GLOBAL")" = '[include]' ] || fail "${runtime}: first section is not [include]"
            [ "$(cfg user.name)" = 'bot (${runtime})' ] || fail "${runtime}: user.name"
            [ "$(cfg user.email)" = 'bot@example.com' ] || fail "${runtime}: root user.email lost by the runtime override"
            [ "$(cfg user.signingKey)" = '${keyFor runtime}' ] || fail "${runtime}: user.signingKey"
            [ "$(cfg commit.gpgSign)" = true ] || fail "${runtime}: commit.gpgSign"
            [ "$(cfg tag.gpgSign)" = true ] || fail "${runtime}: tag.gpgSign"
            [ "$(cfg gpg.format)" = ssh ] || fail "${runtime}: gpg.format"
            [ "$(cfg gpg.ssh.program)" = '${lib.getExe' pkgs.openssh "ssh-keygen"}' ] || fail "${runtime}: gpg.ssh.program"
            cfg --get-all url.https://github.com/.insteadOf > insteadof
            printf '%s\n' 'git@github.com:' 'ssh://git@github.com/' | cmp -s - insteadof || fail "${runtime}: insteadOf"
            # operator-helper, then the reset, then the agent's helper: git
            # drops everything before the empty value.
            cfg --get-all credential.https://github.com.helper > helpers
            [ "$(wc -l < helpers)" -eq 3 ] || fail "${runtime}: expected three helper entries"
            [ "$(sed -n 1p helpers)" = operator-helper ] || fail "${runtime}: include is not first"
            [ -z "$(sed -n 2p helpers)" ] || fail "${runtime}: reset does not follow the include"
            helper="$(sed -n 3p helpers)"
            case "$helper" in
              ${builtins.storeDir}/*/bin/ai-git-credential-github) ;;
              *) fail "${runtime}: agent helper is $helper" ;;
            esac
            grep -Fq '${tokenFile}' "$helper" || fail "${runtime}: helper does not read the token file"
            if grep -Eq 'GH_TOKEN|GITHUB_TOKEN' "$GIT_CONFIG_GLOBAL" "$helper"; then
              fail "${runtime}: token variable emitted"
            fi
            [ -z "$("$helper" store </dev/null)" ] || fail "${runtime}: helper answered a store request"
          '')
          harnessNames}

        # The token file does not exist in the sandbox: the helper must say
        # quit, and git must stop there rather than ask the user's askpass.
        export GIT_CONFIG_GLOBAL=${file hm "claude"}
        if "$helper" get </dev/null > answer 2>/dev/null; then
          fail "helper succeeded without a token file"
        fi
        grep -Fxq quit=1 answer || fail "helper did not answer quit=1 on a missing token"
        if fill > filled 2>/dev/null; then
          fail "credential fill succeeded without a token file"
        fi
        if grep -Fq OPERATOR_SECRET filled; then
          fail "missing token fell through to the user's askpass"
        fi

        # A readable token is answered as x-access-token.
        export GIT_CONFIG_GLOBAL=${file withHelper "claude"}
        fill > filled || fail "credential fill failed with a token helper"
        grep -Fxq username=x-access-token filled || fail "username is not x-access-token"
        grep -Fxq password=fake-token filled || fail "password is not the helper's token"

        # Signing off is written off: the user's gpgSign = true stays out.
        export GIT_CONFIG_GLOBAL=${file unsigned "claude"}
        [ "$(cfg commit.gpgSign)" = false ] || fail "unsigned: user's commit.gpgSign leaked through"
        [ "$(cfg tag.gpgSign)" = false ] || fail "unsigned: user's tag.gpgSign leaked through"

        # devenv includes git's default XDG path; `~/.gitconfig` still wins a
        # key both user files set, as it does natively.
        export GIT_CONFIG_GLOBAL=${file devenv "claude"}
        cfg --get-all include.path > includes
        printf '%s\n' '~/.config/git/config' '~/.gitconfig' | cmp -s - includes || fail "devenv include paths or order"
        [ "$(cfg alias.who)" = home ] || fail "XDG config overrides ~/.gitconfig"

        echo "PASS: ai-programs-git-rendered-gitconfig" > "$out"
      '';

    # The launcher runtimes carry their own gitconfig and the gh dir in the
    # wrapper they install, on both backends, and no token variable.
    module-ai-programs-git-launchers-carry-env = let
      wrappers = lib.concatMap (backend: let
        ev = backends.${backend} identity;
        installed =
          if backend == "hm"
          then ev.config.home.packages
          else ev.config.packages;
      in
        map (runtime: {
          inherit backend runtime;
          bin = exes.${runtime};
          packages = installed;
          gitconfig = (channel ev runtime).GIT_CONFIG_GLOBAL;
        })
        launcherRuntimes) (builtins.attrNames backends);
    in
      pkgs.runCommand "module-test-ai-programs-git-launchers-carry-env" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        fail() {
          echo "FAIL: ai-programs-git-launchers-carry-env: $1" >&2
          exit 1
        }
        ${lib.concatMapStringsSep "\n" (wrapper: ''
            found=
            for pkg in ${lib.concatMapStringsSep " " toString wrapper.packages}; do
              if [ -e "$pkg/bin/${wrapper.bin}" ]; then
                found="$pkg/bin/${wrapper.bin}"
              fi
            done
            [ -n "$found" ] || fail "${wrapper.backend}/${wrapper.runtime}: no installed ${wrapper.bin}"
            ${pkgs.gnugrep}/bin/grep -Fq GIT_CONFIG_GLOBAL "$found" || fail "${wrapper.backend}/${wrapper.runtime}: GIT_CONFIG_GLOBAL missing"
            ${pkgs.gnugrep}/bin/grep -Fq '${wrapper.gitconfig}' "$found" || fail "${wrapper.backend}/${wrapper.runtime}: its own gitconfig missing"
            ${pkgs.gnugrep}/bin/grep -Fq '${ghDir}' "$found" || fail "${wrapper.backend}/${wrapper.runtime}: GH_CONFIG_DIR missing"
            if ${pkgs.gnugrep}/bin/grep -Eq 'GH_TOKEN|GITHUB_TOKEN' "$found"; then
              fail "${wrapper.backend}/${wrapper.runtime}: token variable emitted"
            fi
          '')
          wrappers}
        echo "PASS: ai-programs-git-launchers-carry-env" > "$out"
      '';
  };
}
