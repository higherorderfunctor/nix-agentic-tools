{pkgs, ...}: let
  kimchi = pkgs.ai.kimchi;
  source = import ../lib/workflowsPackage.nix {inherit pkgs;};
  sources = ../sources.json;
in {
  checks.kimchi-workflows-source = pkgs.runCommand "kimchi-workflows-source-check" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    lock_version=$(${pkgs.yq-go}/bin/yq -r '.importers["."].dependencies["@kimchi-dev/kimchi-workflows"].version' ${kimchi.src}/pnpm-lock.yaml)
    lock_version="''${lock_version%%(*}"
    pin_version=$(${pkgs.jq}/bin/jq -er '.extraction.workflowsPackage.version' ${sources})
    pin_url=$(${pkgs.jq}/bin/jq -er '.extraction.workflowsPackage.url' ${sources})
    if [ "$lock_version" != "$pin_version" ]; then
      printf 'kimchi workflows: lock resolves %s, sources.json pins %s\n' "$lock_version" "$pin_version" >&2
      exit 1
    fi
    expected_url="https://registry.npmjs.org/@kimchi-dev/kimchi-workflows/-/kimchi-workflows-$lock_version.tgz"
    if [ "$pin_url" != "$expected_url" ]; then
      printf 'kimchi workflows: lock expects URL %s, sources.json pins %s\n' "$expected_url" "$pin_url" >&2
      exit 1
    fi
    package_version=$(${pkgs.jq}/bin/jq -er '.version' ${source}/package.json)
    if [ "$lock_version" != "$package_version" ]; then
      printf 'kimchi workflows: lock resolves %s, fetched package.json reports %s\n' "$lock_version" "$package_version" >&2
      exit 1
    fi
    ${pkgs.jq}/bin/jq -e '.name == "@kimchi-dev/kimchi-workflows"' ${source}/package.json > /dev/null
    for directory in dist docs examples src; do
      test -d "${source}/$directory"
    done
    test -s ${source}/README.md
    printf 'kimchi workflows: lock, sources.json and fetched package agree on %s\n' "$package_version" > "$out"
  '';
}
