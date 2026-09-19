# pjrpc 2.2.0 — the JSON-RPC dispatcher the scribe daemon serves its socket
# with (MECH-SCRIBE-RPC, WORK-RPC-ON-PJRPC-AND-PYDANTIC).
#
# ── Why a derivation here rather than an overlay ─────────────────────────────
#
# The same reasoning devenv.nix records for `boardElkjs`, and it is about what
# an overlay COSTS rather than any doubt about the pattern. An overlay entry is
# a PUBLISHED package of this flake: it lands in `pkgs.ai.*` and
# `packages.<system>`, owes a `config.checks.cacheHitParity` row, owes either a
# `config.update.targets` row or a written `passthru.updateTargetExempt`
# reason, and — being version-tracked against a registry — owes a sidecar plus
# an update script the 4x/day sweep runs. None of that buys anything for a
# library that only this repository's own dev scripts import, and publishing
# pjrpc as a product of nix-agentic-tools misstates what this repo ships.
#
# ── Why it is NOT declared in devenv.nix, where boardElkjs is ────────────────
#
# Because its consumer is `./mkExtract.nix`, and devenv.nix is not that
# factory's only caller. flake.nix builds the SAME factory once for the seven
# grammar checks (`strictdocGrammarExtract`), handing it nothing but `lib`,
# `pkgs` and `strictdoc`. A pjrpc declared in devenv.nix and threaded in as an
# argument would therefore be absent from the flake-check copy — and since the
# install check below is meant to make a missing pjrpc a BUILD failure, that
# absence would redden `nix flake check` rather than reach the daemon. One
# wrap for a session and for CI is the invariant mkExtract.nix's header states;
# this file is where a dependency of that wrap has to live to keep it.
#
# ── The pin ──────────────────────────────────────────────────────────────────
#
# 2.2.0, released 2026-08-08, Unlicense, `python >=3.10,<4.0`. ZERO hard
# dependencies: everything in `[tool.poetry.extras]` — pydantic included — is
# optional, so nothing is added to the closure but this pure-Python tree. The
# hash came from `nix store prefetch-file --json` on the PyPI sdist.
#
# NO EXTRAS. `pjrpc.server.validators.pydantic` imports pydantic at module
# scope, and pydantic is ALREADY in the strictdoc venv this package is spliced
# onto (a fastapi/uvicorn transitive). Declaring the extra here would build a
# second pydantic into the closure for no import that resolves differently.
# That is also why `pythonImportsCheck` stops at `pjrpc.server`: the validator
# module is unimportable in THIS package's own check environment and perfectly
# importable in the environment that uses it — mkExtract.nix's install check is
# what asserts the pair, because that is where the pair exists.
{
  lib,
  python3Packages,
}:
python3Packages.buildPythonPackage rec {
  pname = "pjrpc";
  version = "2.2.0";
  pyproject = true;

  src = python3Packages.fetchPypi {
    inherit pname version;
    hash = "sha256-M4v9meCtXg8N8NzOmr+kJieEm/EN+prEwtl88o1mkT0=";
  };

  build-system = [python3Packages.poetry-core];

  # The sdist carries no tests directory, so there is nothing for a check
  # phase to run and an empty one would only be a slower no-op.
  doCheck = false;

  pythonImportsCheck = [
    "pjrpc"
    "pjrpc.server"
  ];

  meta = {
    description = "Extensible JSON-RPC library";
    homepage = "https://github.com/dapper91/pjrpc";
    license = lib.licenses.unlicense;
    platforms = lib.platforms.unix;
  };
}
