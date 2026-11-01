{
  lib,
  pkgs,
}: let
  git = lib.getExe pkgs.git;
in {
  clone = ''
    head="$(< /run/sandbox-command/repo-head)"
    branch="$(< /run/sandbox-command/repo-branch)"
    ${git} clone --quiet --shared --no-checkout /run/sandbox/seed /home/sandbox/repo
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
  export = import ../../../lib/strict-shell-application.nix pkgs {
    name = "sandbox-repo-export";
    runtimeInputs = [pkgs.coreutils pkgs.git];
    text = ''
      cd /home/sandbox/repo
      exclusions=()
      while IFS= read -r root; do
        exclusions+=("^$root")
      done < /run/sandbox-seed-roots
      head=()
      if git rev-parse --verify --quiet 'HEAD^{commit}' > /dev/null; then
        head=(HEAD)
      fi
      if [[ $(git rev-list --count --all "''${head[@]}" "''${exclusions[@]}") == 0 ]]; then
        exit 3
      fi
      bundle="$(mktemp)"
      trap 'rm -f -- "$bundle"' EXIT
      git bundle create "$bundle" --all "''${head[@]}" "''${exclusions[@]}"
      cat -- "$bundle"
    '';
  };
}
