# cspell:ignore urandom
# Module-level selection owns credentials; mkSandbox only transports a config file.
{
  args,
  factory,
  forges,
  identities,
  instance,
  lib,
  pkgs,
  runtime,
  runtimeIdentities,
  signers,
}: let
  connect = signing:
    factory (args
      // {
        doors = [
          {
            arguments = ["STDIO" "TCP:127.0.0.1:${toString instance.port}"];
            command = "${pkgs.socat}/bin/socat";
            port = guestPort;
          }
        ];
        inherit signing;
        packages = args.packages ++ lib.optional (signing != null) pkgs.openssh;
        repo = true;
        repoConfig = true;
      });
  connected = connect null;
  signed =
    if signers == {}
    then connected
    else
      connect {
        port = 2222;
        socket = null;
      };
  guestPort = 9418;
  plain = factory args;
  seeded = factory (args // {repo = true;});
  selector = import ./selector.nix {inherit identities pkgs runtime runtimeIdentities;};
  table = import ./select.nix {
    inherit identities lib runtime;
    forges = (import ./forges.nix {inherit lib;}) forges;
  };
  tableFile = pkgs.writeText "sandbox-${runtime}-selection.json" (builtins.toJSON table);
  users = pkgs.writeText "sandbox-${runtime}-users.json" (builtins.toJSON (lib.mapAttrs (_: entry: entry.user) identities));
  # session open validates references but only the daemon writes shared pins.
  # Its hooks read the resolved service config and current pins on every push.
  managementConfig = pkgs.writeText "sandbox-${runtime}-relay.json" instance.renderedConfig;
in
  (import ../../../../lib/strict-shell-application.nix pkgs {
    name = args.outName;
    runtimeInputs = [pkgs.coreutils pkgs.git pkgs.jq pkgs.openssh pkgs.util-linux];
    text = ''
      selected=$(${lib.getExe selector} ${tableFile})
      identity=$(jq -r .identity <<< "$selected")
      printf '%s %s\n' ${lib.escapeShellArg "${runtime}-sandbox: identities=${builtins.toJSON (builtins.attrNames identities)}${lib.optionalString runtimeIdentities " (runtime values replace ai.sandbox.git.identities)"};"} "$(jq -c '{token, identity}' <<< "$selected")" >&2
      # The selector prints {"repo":false} outside a checkout and null when the
      # checkout has no push remote.
      if jq -e '.repo == false' <<< "$selected" >/dev/null; then
        exec ${lib.getExe plain} "$@"
      fi
      if [[ $selected == null ]]; then
        exec ${lib.getExe seeded} "$@"
      fi
      signing_dir=""
      signing_service=""
      case "$identity" in
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (identity: signer: ''
          ${lib.escapeShellArg identity})
            signing_dir=${signer.runtimeDir}
            signing_service=${lib.escapeShellArg signer.service}
            ;;
        '')
        signers)}
        *) ;;
      esac
      signing_socket=""
      if [[ -n $signing_dir ]]; then
        signing_socket=$signing_dir/agent.sock
        # Another user could pre-create a predictable directory with an agent of
        # their own; trust only a directory, socket and public key this user owns.
        if [[ -L $signing_dir || ! -d $signing_dir || ! -O $signing_dir || $(stat -c %a -- "$signing_dir") != 700 ]]; then
          echo "${runtime}-sandbox: $signing_service runtime directory $signing_dir must be an owned, non-symlink 0700 directory; start or restart $signing_service" >&2
          exit 1
        fi
        if [[ ! -S $signing_socket || ! -O $signing_socket || ! -f $signing_socket.pub || ! -O $signing_socket.pub ]]; then
          echo "${runtime}-sandbox: $signing_service must own $signing_socket and $signing_socket.pub; start or restart $signing_service" >&2
          exit 1
        fi
        if ! public_key=$(SSH_AUTH_SOCK="$signing_socket" timeout 10 ssh-add -L); then
          echo "${runtime}-sandbox: signer unavailable or empty; start $signing_service" >&2
          exit 1
        fi
        mapfile -t public_keys <<< "$public_key"
        if (( ''${#public_keys[@]} != 1 )); then
          echo "${runtime}-sandbox: $signing_service must contain exactly one signing key; restart it" >&2
          exit 1
        fi
        # Agent comments can contain host paths; the guest needs only key bytes.
        read -r key_type key_data _ <<< "$public_key"
        public_key="$key_type $key_data"
        # The guest reaches only listing and signing through the door, but a host
        # process with the socket can swap the agent's key; the signer published
        # the key it loaded.
        if ! read -r key_type key_data _ < "$signing_socket.pub" || [[ $public_key != "$key_type $key_data" ]]; then
          echo "${runtime}-sandbox: $signing_service holds a key other than its configured signing key; restart it" >&2
          exit 1
        fi
      fi
      # The relay creates SHA-1 sessions; borrowing SHA-256 objects cannot work.
      if [[ $(git rev-parse --show-object-format) != sha1 ]]; then
        echo '${runtime}-sandbox: relay sessions require a SHA-1 repository' >&2
        exit 2
      fi
      credential=$(jq -r .credential <<< "$selected")
      upstream=$(jq -r .upstream <<< "$selected")
      state=${lib.escapeShellArg instance.stateDir}
      session() {
        # Refuse inherited init choices such as GIT_DEFAULT_HASH and templates.
        (cd "$state" && env -i PATH="$PATH" GIT_RELAY_CONFIG=${managementConfig} ${lib.getExe instance.package} session "$@")
      }
      umask 077
      ${pkgs.coreutils}/bin/mkdir -p "$state/locks"
      token=$(${pkgs.coreutils}/bin/od -An -tx1 -N16 /dev/urandom | ${pkgs.coreutils}/bin/tr -d ' \n')
      exec {session_lock}<>"$state/locks/$token"
      flock -n "$session_lock"
      config_dir=$(${pkgs.coreutils}/bin/mktemp -d -t ${runtime}-sandbox-session.XXXXXXXX)
      # Close while the publication lock is still held, including boot failures.
      # shellcheck disable=SC2329
      cleanup() {
        session close "$token" || echo '${runtime}-sandbox: session cleanup failed; relay GC will retry' >&2
        ${pkgs.coreutils}/bin/rm -rf -- "$config_dir"
      }
      trap cleanup EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      # The session borrows only the seed's copied history, never the host
      # object store; mkSandbox links the seed's objects here before boot.
      export SANDBOX_SEED_OBJECTS="$config_dir/seed-objects"
      session open --token "$token" --credential "$credential" --upstream "$upstream" --alternates "$SANDBOX_SEED_OBJECTS"
      if ! env -i PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        timeout 10 git ls-remote "git://127.0.0.1:${toString instance.port}/sessions/$token.git" >/dev/null; then
        echo '${runtime}-sandbox: relay unavailable; check ai.git-relay.instances.sandbox.port and start its service' >&2
        exit 1
      fi
      export SANDBOX_REPO_CONFIG="$config_dir/repo-config"
      git config --file "$SANDBOX_REPO_CONFIG" user.name "$(jq -r --arg identity "$identity" '.[$identity].name' ${users})"
      git config --file "$SANDBOX_REPO_CONFIG" user.email "$(jq -r --arg identity "$identity" '.[$identity].email' ${users})"
      git config --file "$SANDBOX_REPO_CONFIG" commit.gpgSign false
      git config --file "$SANDBOX_REPO_CONFIG" tag.gpgSign false
      git config --file "$SANDBOX_REPO_CONFIG" remote.origin.url "git://${connected.doorAddress}:${toString guestPort}/sessions/$token.git"
      git config --file "$SANDBOX_REPO_CONFIG" remote.origin.prune false
      if [[ -n $signing_socket ]]; then
        email=$(git config --file "$SANDBOX_REPO_CONFIG" user.email)
        export SANDBOX_ALLOWED_SIGNERS="$config_dir/allowed-signers"
        export SANDBOX_SIGNING_SOCKET="$signing_socket"
        printf '%s %s\n' "$email" "$public_key" > "$SANDBOX_ALLOWED_SIGNERS"
        git config --file "$SANDBOX_REPO_CONFIG" gpg.format ssh
        git config --file "$SANDBOX_REPO_CONFIG" user.signingKey "key::$public_key"
        git config --file "$SANDBOX_REPO_CONFIG" commit.gpgSign true
        git config --file "$SANDBOX_REPO_CONFIG" tag.gpgSign true
        git config --file "$SANDBOX_REPO_CONFIG" gpg.ssh.allowedSignersFile ${lib.escapeShellArg (signed.guestRuntimeFile "allowed-signers")}
        ${lib.getExe signed} "$@"
      else
        ${lib.getExe connected} "$@"
      fi
    '';
  }).overrideAttrs (old: {
    passthru = (old.passthru or {}) // {inherit connected plain seeded selector signed table tableFile;};
  })
