# The stand-in SSH transport the git-relay checks share: the relay package
# with its SSH hop replaced, and the upstream hook that records the forward.
{pkgs}: let
  strict = import ../../../lib/strict-shell-application.nix pkgs;
  # This transport only replaces SSH's network hop. Git still chooses the
  # repository's key and host pin, and invokes its ordinary receive-pack. It
  # stands in for OpenSSH naming the key file on stderr, as it does for a
  # missing or unreadable one, on every call so any path that lets SSH's
  # stderr through shows it.
  fakeSsh = strict {
    name = "ssh";
    runtimeInputs = [pkgs.git];
    text = ''
      while (($#)); do
        case $1 in
          -G) exit 0 ;;
          -i) echo "Warning: Identity file $2 not accessible" >&2; shift 2 ;;
          -F|-o|-p) shift 2 ;;
          -*) echo "fake ssh: unexpected option $1" >&2; exit 1 ;;
          *) shift; break ;;
        esac
      done
      [[ $# == 1 ]] || { echo "fake ssh: expected one remote command" >&2; exit 1; }
      case $1 in
        "git-receive-pack "*|"git-upload-pack "*) exec ${pkgs.bash}/bin/bash -c "$1" ;;
        *) echo "fake ssh: unexpected remote command" >&2; exit 1 ;;
      esac
    '';
  };
  # receive-pack keeps the SSH command so the caller can inspect the actual
  # identity selection; rejecting one ref checks the forward's atomicity.
  upstreamHook = strict {
    name = "git-relay-upstream-update";
    text = ''
      printf '%s' "''${GIT_SSH_COMMAND-unset}" >"$GIT_DIR/forward-ssh"
      [[ $1 != refs/heads/reject ]]
    '';
  };
in {
  inherit fakeSsh upstreamHook;

  relay = pkgs.callPackage ../packages/ai/generic/git-relay/package.nix {
    openssh = fakeSsh;
    strictShellApplication = import ../../../lib/strict-shell-application.nix;
  };
}
