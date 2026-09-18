# The smoke gate: does the thing this repo just built actually START?
#
# The `build` CI context proves the derivation succeeds. It does not prove the
# CLI runs, and on this package the gap between those is where every known
# failure lives: upstream returns None from its embeddings path, serves an
# HTTP 200 "Dashboard HTML not found" page when the SPA is missing, and warns
# and continues when `setup.py` cannot find the frontend. Nothing here fails
# loudly on its own, and the repo tracks KiroCrew `main` at roughly four bumps
# a day, so a silent regression would ride in on a green PR.
#
# It lives under `checks.` deliberately: that rides the existing required
# `test` context, so gating updates on it costs no branch-ruleset change. And
# it takes the built package as a real input, so the drv changes on every bump
# — a check whose inputs do not move would serve a cached pass on exactly the
# PRs it exists to gate.
#
# `runCommandLocal`, not `runCommand`, and the non-substitutability is the
# point rather than a side effect: this check's whole value is that the binary
# ran HERE. A substituted result asserts only that it ran somewhere once.
{pkgs, ...}: {
  checks.kiro-crew-smoke = let
    crew = pkgs.ai.kiro-crew;
  in
    pkgs.runCommandLocal "kiro-crew-smoke-check" {} ''
      fail() {
        printf 'kiro-crew-smoke: %s\n' "$1" >&2
        exit 1
      }

      # A writable HOME. Crew's data root is `$HOME/.kiro/crew`, and a build
      # sandbox has no home directory at all — a CLI that tries to create it
      # would fail on something unrelated to what this check is asking.
      export HOME="$PWD/home"
      mkdir -p "$HOME"

      # ── 1. The version the binary REPORTS matches the one the recipe CLAIMS
      #
      # This is the load-bearing assertion, not the liveness one. The recipe
      # carries `upstreamVersion` as a literal under an `# upstream:` marker
      # that `dev/scripts/update-pkg.sh` rewrites from the freshly prefetched
      # tree, because reading `pyproject.toml` at eval time would be IFD. If
      # that rewrite is ever skipped — it is skipped whenever the prefetch does
      # not happen — the package ships claiming one version and running
      # another, with nothing to notice. This notices.
      #
      # `--version` is a deliberate fast path in `kiro_crew._bootstrap:main`:
      # it prints and returns WITHOUT importing `kiro_crew.cli`. So it proves
      # the console script and the top-level package, and step 2 is what proves
      # the rest.
      reported="$(${crew}/bin/kirocrew --version)" \
        || fail "kirocrew --version exited non-zero"

      expected="kirocrew ${crew.passthru.upstreamVersion}"
      if [ "$reported" != "$expected" ]; then
        fail "version drift.
        binary reports: $reported
        recipe claims:  $expected
      The recipe's upstreamVersion literal is stale. It is rewritten by
      update-pkg.sh from the prefetched tree; a rev bump that skipped the
      prefetch leaves it behind. Re-read the version out of the pinned
      pyproject.toml and update the '# upstream:' marked literal."
      fi
      printf 'kiro-crew-smoke: %s\n' "$reported"

      # ── 2. The real CLI import graph loads
      #
      # `--help` goes through `_import_cli()`, so it executes every module-scope
      # import in `kiro_crew.cli` and everything it pulls in. That is the check
      # `pythonImportsCheck = ["kiro_crew"]` cannot make: the top-level package
      # imports fine on a build whose dependencies are incomplete, because the
      # CLI's imports are what actually exercise them.
      #
      # A missing dependency does not merely fail here — `_bootstrap._self_heal`
      # first tries `pip install -e`, which cannot work in a sandbox, and then
      # exits 1 with the module name. That is the diagnosis, already printed.
      helpOut="$(${crew}/bin/kirocrew --help 2>&1)" \
        || fail "kirocrew --help exited non-zero, so kiro_crew.cli did not import:
      $helpOut"

      case "$helpOut" in
        *kirocrew*) : ;;
        *) fail "kirocrew --help printed no usage naming the program:
      $helpOut" ;;
      esac
      printf 'kiro-crew-smoke: the CLI import graph loaded\n'

      # ── 3. No GPL blob survived into the output
      #
      # `prepareVendoredLibs` relinks the vendored libraries onto nixpkgs' libgomp
      # and deletes auditwheel's hashed copy, which is GPL-3.0-or-later shipped
      # with no licence text anywhere in the artifact. Getting that wrong is a
      # REDISTRIBUTION defect, not a build failure: the derivation succeeds and
      # the binary cache serves it. So assert the absence, in the installed
      # tree, rather than trusting a patchPhase that ran hours earlier.
      vendored="${crew}/${pkgs.python313.sitePackages}/kiro_crew/_vendor/llama_cpp_libs"
      if [ -d "$vendored" ]; then
        if find "$vendored" -type f -name 'libgomp*' -print -quit | grep -q .; then
          fail "a vendored libgomp survived into the output. It is
      GPL-3.0-or-later with no licence text in the artifact, and this output is
      redistributed through a public binary cache. See prepareVendoredLibs."
        fi
        printf 'kiro-crew-smoke: no vendored libgomp in the output\n'
      fi

      # ── 4. The distribution stamp survived into the wheel
      #
      # `postPatch` runs upstream's stamper over the SOURCE tree. Whether
      # setuptools then carries `_build_info.py` into site-packages is a
      # separate question, and the answer decides whether
      # `kiro-crew-distribution-nix.patch` does anything at all: `beacon`
      # resolves the baked module first and falls back to "source", the
      # git-checkout answer, which routes this install to an in-place update
      # that cannot succeed against a read-only store. Both halves succeed
      # silently if this file goes missing.
      buildInfo="${crew}/${pkgs.python313.sitePackages}/kiro_crew/_build_info.py"
      [ -f "$buildInfo" ] || fail "_build_info.py did not reach site-packages, so
      beacon.distribution() reports 'source' and this install is offered an
      in-place update it cannot apply."
      ${pkgs.gnugrep}/bin/grep -q 'DISTRIBUTION = "nix"' "$buildInfo" \
        || fail "the installed _build_info.py does not stamp nix:
      $(cat "$buildInfo")"
      printf 'kiro-crew-smoke: the installed build stamps distribution=nix\n'

      # ── 5. The notices that binary redistribution requires
      #
      # Neither text is in upstream's `package_data`, so neither reaches
      # site-packages on its own. `postInstall` installs both; this is what
      # notices if that ever stops happening.
      for notice in LICENSE llama.cpp-LICENSE; do
        [ -s "${crew}/share/doc/kiro-crew/licenses/$notice" ] \
          || fail "$notice is missing or empty under share/doc/kiro-crew/licenses"
      done
      printf 'kiro-crew-smoke: licence notices present\n'

      # ── 6. The dashboard actually landed in the INSTALLED tree
      #
      # `setup.py`'s BuildWithFrontend prints a warning and CONTINUES when the
      # frontend is absent, and the gateway then serves an unauthenticated
      # "Dashboard HTML not found" page with HTTP 200. The derivation asserts
      # this too; repeating it here is what puts it in the required `test`
      # context, where a bump that broke the npm build is caught by CI rather
      # than by opening the dashboard.
      #
      # A content test, not a size floor: Vite emits content-hashed
      # `/assets/index-<hash>.js` references, while the SOURCE template
      # references `/src/main.tsx`. A byte count cannot tell those apart.
      index="${crew}/${pkgs.python313.sitePackages}/kiro_crew/static/dist/index.html"
      [ -f "$index" ] || fail "the installed dashboard has no index.html at $index"
      ${pkgs.gnugrep}/bin/grep -q '/assets/' "$index" \
        || fail "the installed index.html carries no built asset reference; a Vite build emits /assets/<name>-<hash>.js, the source template references /src/main.tsx"
      printf 'kiro-crew-smoke: the dashboard is installed and built\n'

      touch "$out"
    '';
}
