{
  lib,
  pkgs,
  ...
}: let
  identities = {
    empty.remotes = {};
    personal.remotes."github.com".forge = "github.com";
    professional.remotes.work.forge = "git.example.org";
  };
  forges = {
    "git.example.org" = {
      sshPort = 2222;
      sshUser = "forge-user";
    };
    "github.com" = {
      sshPort = 22;
      sshUser = "git";
    };
  };
  runtime = "codex";
  table = import ../lib/sandbox/select.nix {inherit lib runtime identities forges;};
  tableFile = pkgs.writeText "sandbox-selector-table.json" (builtins.toJSON table);
  selector = import ../lib/sandbox/selector.nix {
    inherit pkgs runtime identities;
    runtimeIdentities = true;
  };
  inheritedSelector = import ../lib/sandbox/selector.nix {
    inherit pkgs runtime identities;
    runtimeIdentities = false;
  };
  sshProbe = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-selector-ssh-probe";
    text = ''
      printf '%s\n' "$@" >"''${SSH_CAPTURE:?}"
      exit 1
    '';
  };
  mkLintedCheck = import ../../../lib/mk-linted-check.nix {inherit pkgs;};
in {
  checks.microvm-sandbox-selector = mkLintedCheck "microvm-sandbox-selector" {
    runtimeInputs = [pkgs.coreutils pkgs.git pkgs.gnugrep pkgs.jq selector];
    text = ''
      base="$TMPDIR/selector fixtures"
      mkdir -p "$base/home"
      export HOME="$base/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
      table=${tableFile}
      jq -e 'keys == ["github.com", "work"] and .work == {
        credential: "codex-professional", forge: "git.example.org", identity: "professional",
        sshPort: 2222, sshUser: "forge-user"
      }' "$table"
      repo() {
        cd "$base"
        git init --quiet --initial-branch=main "$1"
        cd "$1"
      }
      expect() {
        local upstream=$1 token=$2 identity=$3 actual
        actual=$(sandbox-select "$table")
        jq -e --arg upstream "$upstream" --arg token "$token" --arg identity "$identity" '
          . == {credential: ("codex-" + $identity), identity: $identity, token: $token, upstream: $upstream}
        ' <<< "$actual"
      }
      probe() {
        rm -f "$base/ssh-command"
        if SSH_CAPTURE="$base/ssh-command" GIT_SSH_COMMAND=${lib.getExe sshProbe} GIT_SSH_VARIANT=ssh \
          git ls-remote "$1" >/dev/null 2>&1; then
          echo 'fake SSH unexpectedly succeeded' >&2
          exit 1
        fi
        [[ $(tail -n 1 "$base/ssh-command") == "$2" ]]
        printf 'SSH path verified: %s\n' "$2"
      }
      refuse() {
        if sandbox-select "$table" >"$base/result" 2>"$base/error"; then
          echo "unexpected selection success in $PWD" >&2
          exit 1
        fi
        grep -F -- "$1" "$base/error"
        grep -F 'ai.codex.sandbox.git.identities (runtime assignments replace the inherited set)' "$base/error"
        grep -F 'empty: ; personal: github.com; professional: work' "$base/error"
      }
      cd "$base"
      [[ $(sandbox-select "$table") == null ]]
      repo no-remotes
      [[ $(sandbox-select "$table") == null ]]
      repo no-origin
      git remote add one git@github.com:one
      git remote add two git@github.com:two
      [[ $(sandbox-select "$table") == null ]]

      while IFS='|' read -r name url upstream; do
        repo "$name"
        git remote add origin "$url"
        expect "$upstream" github.com personal
      done <<'URLS'
      scp|git@github.com:owner/repo.git|ssh://git@github.com:22/~/owner/repo.git
      scp-no-user|github.com:owner/repo|ssh://git@github.com:22/~/owner/repo
      scp-percent|git@github.com:owner/repo%20.git|ssh://git@github.com:22/~/owner/repo%2520.git
      scp-absolute|git@github.com:/srv/repo.git|ssh://git@github.com:22/srv/repo.git
      scp-tilde|github.com:~other/repo|ssh://git@github.com:22/~other/repo
      ssh|ssh://github.com/owner/repo.git|ssh://git@github.com:22/owner/repo.git
      ssh-explicit|ssh://alice@github.com:2200/absolute/repo|ssh://alice@github.com:2200/absolute/repo
      ssh-home|ssh://github.com/~/owner/repo.git|ssh://git@github.com:22/~/owner/repo.git
      ssh-percent|ssh://github.com/owner/repo%20.git|ssh://git@github.com:22/owner/repo%20.git
      https|https://github.com:443/owner/repo.git|ssh://git@github.com:22/owner/repo.git
      git|git://github.com/owner/repo|ssh://git@github.com:22/owner/repo
      URLS

      while IFS='|' read -r name url original forwarded; do
        cd "$base/$name"
        upstream=$(sandbox-select "$table" | jq -r .upstream)
        probe "$url" "$original"
        probe "$upstream" "$forwarded"
      done <<'PATHS'
      scp-percent|git@github.com:owner/repo%20.git|git-upload-pack 'owner/repo%20.git'|git-upload-pack '~/owner/repo%20.git'
      ssh-percent|ssh://github.com/owner/repo%20.git|git-upload-pack '/owner/repo .git'|git-upload-pack '/owner/repo .git'
      PATHS

      repo alias
      git remote add origin work:owner/repo.git
      expect ssh://forge-user@git.example.org:2222/~/owner/repo.git work professional
      git remote set-url origin ssh://alice@work:2200/absolute/repo.git
      expect ssh://alice@git.example.org:2200/absolute/repo.git work professional
      git config url.file:///wrong/.insteadOf ssh://alice@work:2200/
      git config url.file:///also-wrong/.pushInsteadOf ssh://alice@work:2200/
      expect ssh://alice@git.example.org:2200/absolute/repo.git work professional

      repo precedence
      git remote add origin git@github.com:origin
      git remote add branch git@github.com:branch
      git remote add default git@github.com:default
      git remote add push git@github.com:push
      expect ssh://git@github.com:22/~/origin github.com personal
      git config branch.main.remote branch
      expect ssh://git@github.com:22/~/branch github.com personal
      git config remote.pushDefault default
      expect ssh://git@github.com:22/~/default github.com personal
      git config branch.main.pushRemote push
      expect ssh://git@github.com:22/~/push github.com personal

      repo sole-remote
      git remote add upstream git@github.com:sole.git
      expect ssh://git@github.com:22/~/sole.git github.com personal
      git -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m fixture
      git checkout --quiet --detach
      expect ssh://git@github.com:22/~/sole.git github.com personal

      repo pushurl
      git remote add origin https://unmatched.example.org/fetch.git
      git config --add remote.origin.url git@github.com:second-fetch.git
      git config remote.origin.pushurl git@github.com:push.git
      expect ssh://git@github.com:22/~/push.git github.com personal
      git config --add remote.origin.pushurl git@github.com:second-push.git
      refuse 'several push URLs'
      grep -F 'git@github.com:push.git' "$base/error"
      grep -F 'git@github.com:second-push.git' "$base/error"
      git config --unset-all remote.origin.pushurl
      refuse 'several push URLs'
      git config remote.origin.pushurl ""
      refuse 'unsupported push URL:'
      git config --add remote.origin.pushurl git@github.com:push.git
      refuse 'several push URLs'

      repo refusals
      git remote add origin git@unmatched.example.org:repo.git
      refuse 'unmatched remote token: unmatched.example.org'
      for url in ../local /absolute/local file:///local https://github.com/ ssh://github.com:0/repo ssh://github.com:65536/repo; do
        git remote set-url origin "$url"
        refuse 'sandbox-select:'
      done
      # Identities inherited from the root are not runtime assignments, so the
      # replacement notice stays out of the refusal.
      repo inherited
      git remote add origin git@unmatched.example.org:repo.git
      if ${lib.getExe inheritedSelector} "$table" 2>"$base/error"; then
        echo 'inherited selector unexpectedly succeeded' >&2
        exit 1
      fi
      grep -F 'unmatched remote token: unmatched.example.org' "$base/error"
      grep -F 'ai.codex.sandbox.git.identities: empty: ; personal: github.com; professional: work' "$base/error"
      if grep -F 'replace the inherited set' "$base/error"; then
        echo 'inherited selector printed the replacement notice' >&2
        exit 1
      fi
      echo 'selector fixtures passed'
    '';
  };
}
