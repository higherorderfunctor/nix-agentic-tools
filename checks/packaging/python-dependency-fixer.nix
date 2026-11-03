# Exercise mkPythonDependencyFix against a mocked PyPI index and prefetch:
# a moved requirement rewrites the sidecar, an unchanged selection skips the
# prefetch, and resolver or prefetch failures leave the sidecar untouched.
{pkgs, ...}: {
  checks.python-dependency-fixer = let
    vu = import ../../lib/packaging.nix;
    inherit (pkgs) python3;
    # The resolver runs `python3 -I`, which still processes site-packages
    # `.pth` files, so the mock enters through the interpreter's package set
    # rather than a test seam in production code.
    fakePypi = python3.pkgs.toPythonModule (pkgs.symlinkJoin {
      name = "fake-pypi";
      paths = [
        (pkgs.writeTextDir "${python3.sitePackages}/fake_pypi.pth" "import fake_pypi\n")
        (pkgs.writeTextDir "${python3.sitePackages}/fake_pypi.py" ''
          import io
          import json
          import urllib.request


          def urlopen(url):
              assert url == "https://pypi.org/pypi/mcp/json", url
              releases = {version: [] for version in ["1.29.0", "1.30.0", "1.30.1", "1.31.0rc1", "2.0.0"]}
              return io.BytesIO(json.dumps({"releases": releases}).encode())


          urllib.request.urlopen = urlopen
        '')
      ];
    });
    # Logs each prefetch to ./prefetch.log; `prefetch` is its exit status.
    fakeNix = prefetch:
      pkgs.symlinkJoin {
        name = "fake-nix";
        paths = [
          (pkgs.writeShellScriptBin "nix-prefetch-url" ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :

            printf '%s\n' "$*" >>prefetch.log
            printf '%s\n' fixture-base32
            exit ${toString prefetch}
          '')
          (pkgs.writeShellScriptBin "nix" ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :

            test "$*" = 'hash convert --to sri --hash-algo sha256 fixture-base32'
            printf '%s\n' sha256-fixture
          '')
        ];
      };
    fixer = prefetch:
      vu.mkPythonDependencyFix {
        dependencies.mcp = {
          repo = "example/sdk";
          sourcesFile = "./sources.json";
        };
        pkgs =
          pkgs
          // {
            nix = fakeNix prefetch;
            python3 = python3 // {withPackages = f: python3.withPackages (ps: f ps ++ [fakePypi]);};
          };
        pname = "fixture";
        pyproject = "./pyproject.toml";
      };
  in
    pkgs.runCommand "python-dependency-fixer-check" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      fail() {
        printf 'FAIL: %s\n' "$*" >&2
        exit 1
      }
      require() {
        printf '[project]\ndependencies = ["mcp%s"]\n' "$1" >pyproject.toml
      }
      pin() {
        printf '{"src":{"hash":"sha256-old","url":"old"},"version":"%s"}\n' "$1" >sources.json
        cp sources.json sources.before
        rm -f prefetch.log
      }
      unchanged() {
        cmp -s sources.before sources.json || fail "$1 rewrote the sidecar"
      }

      require '>=1.30,<2'
      pin 1.29.0
      ${fixer 0} || fail 'changed requirement exited non-zero'
      test "$(jq -cS . sources.json)" = '{"src":{"hash":"sha256-fixture","url":"https://github.com/example/sdk/archive/v1.30.1.tar.gz"},"version":"1.30.1"}' \
        || fail "changed requirement wrote $(cat sources.json)"
      test "$(cat prefetch.log)" = '--type sha256 --unpack https://github.com/example/sdk/archive/v1.30.1.tar.gz' \
        || fail "changed requirement prefetched $(cat prefetch.log)"

      pin 1.30.1
      ${fixer 0} || fail 'unchanged selection exited non-zero'
      unchanged 'unchanged selection'
      test ! -e prefetch.log || fail 'unchanged selection prefetched'

      require '>=3'
      pin 1.29.0
      ! ${fixer 0} || fail 'unsatisfiable requirement exited zero'
      unchanged 'unsatisfiable requirement'

      require '>=1.30,<2'
      pin 1.29.0
      ! ${fixer 1} || fail 'failed prefetch exited zero'
      unchanged 'failed prefetch'
      test -e prefetch.log || fail 'failed prefetch case never reached the prefetch'

      touch "$out"
    '';
}
