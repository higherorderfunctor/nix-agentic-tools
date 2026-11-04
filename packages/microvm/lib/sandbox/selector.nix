{
  identities,
  pkgs,
  runtime,
  runtimeIdentities,
}: let
  inherit (pkgs) lib;
  available = lib.concatStringsSep "; " (lib.mapAttrsToList (identity: settings: "${identity}: ${lib.concatStringsSep ", " (builtins.attrNames settings.remotes)}") identities);
  endpoint = import ../../../git-relay/lib/upstream.nix {inherit lib;};
in
  import ../../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-select";
    runtimeInputs = [pkgs.git pkgs.jq];
    text = ''
      refuse() {
        printf 'sandbox-select: %s\nai.${runtime}.sandbox.git.identities${lib.optionalString runtimeIdentities " (runtime assignments replace the inherited set)"}: %s\n' "$1" ${lib.escapeShellArg available} >&2
        exit 1
      }
      [[ $# == 1 ]] || refuse 'usage: sandbox-select <table.json>'
      table=$1
      if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
        printf 'null\n'
        exit 0
      fi

      branch=$(git symbolic-ref --quiet --short HEAD || :)
      remote=
      if [[ -n $branch ]]; then
        remote=$(git config --get "branch.$branch.pushRemote" || :)
      fi
      if [[ -z $remote ]]; then remote=$(git config --get remote.pushDefault || :); fi
      if [[ -z $remote && -n $branch ]]; then
        remote=$(git config --get "branch.$branch.remote" || :)
      fi
      if [[ -z $remote ]]; then
        mapfile -t remotes < <(git remote)
        if [[ ''${#remotes[@]} == 1 ]]; then remote=''${remotes[0]}; else remote=origin; fi
      fi
      mapfile -d "" -t urls < <(git config --null --get-all "remote.$remote.pushurl" || :)
      if [[ ''${#urls[@]} == 0 ]]; then
        mapfile -d "" -t urls < <(git config --null --get-all "remote.$remote.url" || :)
      fi
      if [[ ''${#urls[@]} == 0 ]]; then
        printf 'null\n'
        exit 0
      fi
      if [[ ''${#urls[@]} != 1 ]]; then
        printf -v listed '%s\n' "''${urls[@]}"
        refuse "remote $remote has several push URLs: $listed"
      fi
      url=''${urls[0]}

      host='${endpoint.hostPattern}'
      ssh="^${endpoint.sshPattern}$"
      network="^(https|git)://($host)(:[0-9]+)?(/[^[:cntrl:]]+)$"
      scp="^${endpoint.scpPattern}$"
      user="" port=""
      if [[ $url =~ $ssh ]]; then
        user=''${BASH_REMATCH[1]%@}
        token=''${BASH_REMATCH[2]}
        port=''${BASH_REMATCH[3]#:}
        path=/''${BASH_REMATCH[4]}
      elif [[ $url =~ $network ]]; then
        token=''${BASH_REMATCH[2]}
        path=''${BASH_REMATCH[4]}
      elif [[ $url != *://* && $url =~ $scp ]]; then
        user=''${BASH_REMATCH[1]%@}
        token=''${BASH_REMATCH[2]}
        path=''${BASH_REMATCH[3]}
        # SCP paths are literal; SSH URLs decode percent escapes before forwarding.
        path=''${path//%/%25}
        # Git's /~/ URL form keeps SCP paths relative to the SSH user's home.
        case $path in
          /*) ;;
          ~*) path=/$path ;;
          *) path=/~/$path ;;
        esac
      else
        refuse "unsupported push URL: $url"
      fi
      selected=$(jq -ce --arg token "$token" '.[$token] // empty' "$table") || refuse "unmatched remote token: $token"
      if [[ -z $user ]]; then user=$(jq -r '.sshUser' <<< "$selected"); fi
      if [[ -z $port ]]; then port=$(jq -r '.sshPort' <<< "$selected"); fi
      if [[ ! $port =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
        refuse "invalid SSH port: $port"
      fi
      forge=$(jq -r '.forge' <<< "$selected")
      jq -cn --argjson selected "$selected" --arg token "$token" --arg upstream "ssh://$user@$forge:$port$path" \
        '{credential: $selected.credential, identity: $selected.identity, token: $token, upstream: $upstream}'
    '';
  }
