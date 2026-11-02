pkgs:
import ../../../lib/strict-shell-application.nix pkgs {
  name = "sandbox-ssh-signer";
  runtimeInputs = [pkgs.coreutils pkgs.openssh];
  text = ''
    if (( $# != 2 )); then
      echo 'sandbox-ssh-signer: usage: sandbox-ssh-signer <socket> <key-file>' >&2
      exit 2
    fi
    socket=$1
    key_file=$2
    if [[ $socket != /* || $key_file != /* ]]; then
      echo 'sandbox-ssh-signer: socket and key file must be absolute paths' >&2
      exit 2
    fi
    if [[ -e $socket ]]; then
      echo "sandbox-ssh-signer: socket already exists: $socket" >&2
      exit 1
    fi
    if [[ ! -f $key_file || ! -r $key_file ]]; then
      echo 'sandbox-ssh-signer: key file must be a readable regular file' >&2
      exit 1
    fi
    # Keep the inherited agent unavailable to every child of this signer.
    unset SSH_AUTH_SOCK
    ssh-agent -D -a "$socket" &
    agent_pid=$!
    trap 'kill "$agent_pid" 2>/dev/null || :; wait "$agent_pid" 2>/dev/null || :' EXIT
    for _ in {1..100}; do
      [[ -S $socket ]] && break
      if ! kill -0 "$agent_pid" 2>/dev/null; then
        echo 'sandbox-ssh-signer: ssh-agent exited before creating its socket' >&2
        exit 1
      fi
      sleep 0.1
    done
    if [[ ! -S $socket ]]; then
      echo "sandbox-ssh-signer: timed out waiting for socket: $socket" >&2
      exit 1
    fi
    SSH_AUTH_SOCK=$socket ssh-add -- "$key_file"
    wait "$agent_pid"
  '';
}
