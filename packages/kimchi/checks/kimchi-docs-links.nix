{pkgs, ...}: {
  checks.kimchi-docs-links = pkgs.runCommandLocal "kimchi-docs-links" {nativeBuildInputs = [pkgs.python3];} ''
    python3 ${./kimchi-docs-links.py} ${../packages/docs/kimchi-docs/fetch-docs.py}
    touch "$out"
  '';
}
