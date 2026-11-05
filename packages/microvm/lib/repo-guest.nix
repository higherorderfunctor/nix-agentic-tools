{
  lib,
  pkgs,
}: let
  git = lib.getExe pkgs.git;
in {
  clone = ''
    head="$(< /run/sandbox/repo-head)" # bare-commands: ok
    branch="$(< /run/sandbox/repo-branch)"
    ${git} clone --quiet --shared --no-checkout /mnt/seed /home/sandbox/repo
    if [[ -n $head ]]; then
      if [[ -n $branch ]]; then
        ${git} -C /home/sandbox/repo checkout --quiet -B "$branch" "$head"
      else
        ${git} -C /home/sandbox/repo -c advice.detachedHead=false checkout --quiet --detach "$head"
      fi
    else
      ${git} -C /home/sandbox/repo symbolic-ref HEAD "refs/heads/$branch"
    fi
    cd /home/sandbox/repo
  '';
  # The runtime session launcher supplies origin and identity after clone/init.
  configure = ''
    ${git} config --unset-all remote.origin.url
    if [[ -n $branch ]]; then
      ${git} config "branch.$branch.remote" origin
      ${git} config "branch.$branch.merge" "refs/heads/$branch"
    fi
    ${lib.getExe (import ../../../lib/git-tool-settings/repo-config.nix {inherit pkgs;})} include . /run/sandbox/repo-config
  '';
  export = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-repo-export";
    runtimeInputs = [pkgs.coreutils pkgs.git];
    text = ''
      cd /home/sandbox/repo
      exclusions=()
      while IFS= read -r root; do
        exclusions+=("^$root")
      done < /run/sandbox-seed-roots
      head=() # bare-commands: ok
      if git rev-parse --verify --quiet 'HEAD^{commit}' > /dev/null; then
        head=(HEAD) # bare-commands: ok
      fi
      if [[ $(git rev-list --count --all "''${head[@]}" "''${exclusions[@]}") == 0 ]]; then
        exit 3
      fi
      bundle="$(${pkgs.coreutils}/bin/mktemp)"
      trap 'rm -f -- "$bundle"' EXIT
      git bundle create "$bundle" --all "''${head[@]}" "''${exclusions[@]}"
      ${pkgs.coreutils}/bin/cat -- "$bundle"
    '';
  };
}
