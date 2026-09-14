# lib/packaging.nix — DRY version extraction + smoke test helpers.
#
# Each helper reads a manifest from a Nix store path (src) at eval
# time and returns the upstream version string. Callers combine it
# with `builtins.substring 0 7 rev` to produce "x.y.z+abc1234".
#
# `rec` so a composed helper can call a sibling —
# `ghArchiveUpdateScript` is `mkUpdateScript` + `ghLatestVersionCmd`
# with one argument threaded through both, and duplicating either
# body to avoid the self-reference would be the DRY loss this file
# exists to prevent. Same shape as lib/ai/transformers/*.nix.
rec {
  # Format: "{upstream}+{shortrev}"
  mkVersion = {
    upstream,
    rev,
  }: "${upstream}+${builtins.substring 0 7 rev}";

  # Read version from Cargo.toml [package] section.
  readCargoVersion = path:
    (builtins.fromTOML (builtins.readFile path)).package.version;

  # Read version from [workspace.package] in a workspace root Cargo.toml.
  readCargoWorkspaceVersion = path:
    (builtins.fromTOML (builtins.readFile path)).workspace.package.version;

  # Read version from pyproject.toml [project] section.
  readPyprojectVersion = path:
    (builtins.fromTOML (builtins.readFile path)).project.version;

  # Read version from package.json.
  readPackageJsonVersion = path:
    (builtins.fromJSON (builtins.readFile path)).version;

  # Read __version__ = "..." from a Python file.
  readPythonDunderVersion = path: let
    content = builtins.readFile path;
    lines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" content);
    vLine = builtins.head (builtins.filter (l: builtins.match "^__version__ = \".*\"$" l != null) lines);
  in
    builtins.head (builtins.match "^__version__ = \"(.*)\"$" vLine);

  # Generate an installCheckPhase for MCP stdio servers.
  # Feeds /dev/null to stdin, captures stderr+stdout, verifies the process
  # started (non-empty output or specific marker). Kills after 2s timeout.
  mkMcpSmokeTest = {
    bin,
    args ? [],
    marker ? null,
  }: let
    argStr = builtins.concatStringsSep " " args;
    check =
      if marker != null
      then ''
        # Here-string, not `echo "$output" | grep -Fq`. stdenv arms
        # `set -o pipefail` for every build phase (setup line 12), and bash's
        # echo builtin writes a captured multi-line string a line at a time —
        # so `grep -Fq` exiting at its first match leaves the remaining writes
        # to EPIPE, poisoning the pipeline status and flipping this `if` to the
        # "marker not found" branch on output that DOES contain the marker.
        if grep -Fq "${marker}" <<<"$output"; then
          echo "smoke-test: found marker '${marker}'"
        else
          echo "smoke-test: marker '${marker}' not found in output:" >&2
          echo "$output" >&2
          exit 1
        fi
      ''
      else ''
        echo "smoke-test: process started (exit ok)"
      '';
  in ''
    runHook preInstallCheck
    echo "Running MCP smoke test for ${bin}..."
    output=$(timeout 2 $out/bin/${bin} ${argStr} < /dev/null 2>&1 || true)
    ${check}
    runHook postInstallCheck
  '';

  # Generate an updateScript for main-tracking packages that use a bare
  # `rev = "..."` in their overlay .nix file. Fetches the latest commit
  # SHA from the default branch via git ls-remote, then sed-replaces the
  # rev line. nix-update --version skip handles hash updates afterward.
  #
  # url: git remote URL (e.g., "https://github.com/owner/repo.git")
  # file: overlay .nix file path relative to repo root
  # rev: current rev string (used as the old value to replace)
  # pkgs: nixpkgs set (for git)
  mkGitRevUpdateScript = {
    url,
    file,
    rev,
    pkgs,
  }:
    pkgs.writeShellScript "update-rev" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      new_rev=$(${pkgs.git}/bin/git ls-remote "${url}" HEAD | ${pkgs.coreutils}/bin/cut -f1)
      # Still reachable under pipefail, and still required. pipefail now
      # catches the case this used to catch — ls-remote FAILING while cut
      # succeeds on empty input — one step earlier, at the assignment.
      # What it cannot catch is ls-remote SUCCEEDING and printing nothing
      # (an empty remote, or HEAD matching no ref): status 0, empty
      # capture, no errexit. That case lands here.
      if [ -z "$new_rev" ]; then
        echo "Failed to fetch latest rev from ${url}" >&2
        exit 1
      fi
      if [ "$new_rev" = "${rev}" ]; then
        echo "Already at latest rev"
        exit 0
      fi
      ${pkgs.gnused}/bin/sed -i "s|${rev}|$new_rev|" "${file}"
      echo "Updated rev: ${rev} -> $new_rev"
    '';

  # Shared body for sidecar hash fixers, including owner-declared pnpm
  # repairs. Emits a bash function
  # `fix_fod_hash <attrPath> <drvPattern> <sidecarKey>` that builds
  # `<attr>.<attrPath>` through the FLAKE'S OWN `packages` output — so the
  # derivation under test is the one consumers get, overlay stack and all
  # — and, on a fixed-output hash mismatch, writes the scraped `got:` hash
  # back to `sourcesFile` under `sidecarKey`.
  #
  # `drvPattern` is not decoration. A failing `src` — or any other
  # fixed-output derivation on the path — also prints `got:`, and writing
  # THAT into a vendor/deps key produces a plausible-looking WRONG hash
  # that nothing downstream would flag. So a mismatch is only trusted when
  # the message names a derivation matching the pattern.
  #
  # It is a shell FUNCTION rather than an inlined body because the npm
  # shape needs it TWICE in one script: `npmDeps` is downstream of `src`,
  # so a stale `srcHash` makes the `npmDeps` build fail on the SRC
  # mismatch and never reach the deps one. Two sequential invocations,
  # each its own `nix build`, is what lets the second read the sidecar the
  # first just wrote.
  #
  # Runs from the repo root, and the sidecar must be GIT-TRACKED: a flake
  # only sees tracked files, so an untracked sidecar is invisible to the
  # eval this drives.
  #
  #   attr:        name under `packages.<system>` (flake.nix flattens
  #                `pkgs.ai.generic` into it, so a generic package is
  #                reachable by its bare name). This repo has NO
  #                `legacyPackages` output — do not reach for one.
  #   sourcesFile: threaded explicitly by every caller.
  fodHashFixFn = {
    attr,
    pkgs,
    pname,
    sourcesFile,
  }: ''
    fix_fod_hash() {
      local attrPath="$1" drvPattern="$2" key="$3"
      local expr output hash tmp

      # builtins.getAttr keeps the expression free of a brace substitution
      # sequence, so bash never tries to expand any part of it.
      expr="(builtins.getAttr builtins.currentSystem (builtins.getFlake (toString ./.)).packages).${attr}.$attrPath"

      if output=$(${pkgs.nix}/bin/nix build --impure --no-link --expr "$expr" 2>&1); then
        echo "${pname}: $key ok"
        return 0
      fi

      hash=""
      # Here-string, not `echo "$output" | grep -q`. This runs under the
      # enclosing writeShellScript's `set -euETo pipefail`, `$output` is a
      # whole failed `nix build` transcript (tens of KB), and bash's echo
      # builtin writes it a line at a time — so `grep -q` exiting at its first
      # match sends the remaining writes to EPIPE and poisons the pipeline's
      # status even though the match SUCCEEDED. That flips this `if` false,
      # leaves `hash` empty, and reports a real hash mismatch as the unrelated
      # "build failed without a hash mismatch" error below. Measured at 3/200
      # on a 34 KB transcript.
      if ${pkgs.gnugrep}/bin/grep -q "fixed-output derivation '[^']*$drvPattern" <<<"$output"; then
        hash=$(echo "$output" | ${pkgs.gnugrep}/bin/grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' | ${pkgs.coreutils}/bin/head -n1 || :)
      fi
      if [ -z "$hash" ]; then
        echo "${pname}: $attrPath build failed without a '$drvPattern' hash mismatch:" >&2
        echo "$output" >&2
        exit 1
      fi

      echo "${pname}: $key -> $hash"
      tmp=$(${pkgs.coreutils}/bin/mktemp)
      ${pkgs.jq}/bin/jq --arg h "$hash" --arg k "$key" '.[$k] = $h' "${sourcesFile}" > "$tmp"
      ${pkgs.coreutils}/bin/mv "$tmp" "${sourcesFile}"
    }
  '';

  # Composed updateScript for packages whose src is a GitHub repo-archive
  # tarball at a release tag (fetchzip consumers): one `repo` value
  # derives BOTH the archive URL template and the version check, so the
  # two can never be pointed at different repositories.
  #
  # `unpack = true` is not optional here: a repo-archive tarball consumed
  # by fetchzip is hashed as the UNPACKED NAR, so a flat-file prefetch
  # hash would be recorded and every consumer would then fail its
  # fixed-output check.
  #
  # Composed over ghLatestVersionCmd and mkUpdateScript below — the set
  # is `rec`, so the entries stay in the group's alphabetical order and
  # definition order carries no meaning.
  # `sourcesFile` is required and passed through from the owner's repoPath.
  # The helper never assumes a directory layout for mutable source files.
  ghArchiveUpdateScript = {
    extraExtract ? "",
    pkgs,
    pname,
    repo,
    sourcesFile,
    tagPrefix ? "v",
  }:
    mkUpdateScript {
      inherit extraExtract pkgs pname sourcesFile;
      platforms = {
        src = ver: "https://github.com/${repo}/archive/${tagPrefix}${ver}.tar.gz";
      };
      unpack = true;
      versionCheck.cmd = ghLatestVersionCmd {inherit pkgs repo tagPrefix;};
    };

  # Shell command printing the latest GitHub release version, resolved
  # from the releases/latest redirect — no API call, so no token and no
  # rate-limit concerns, and GitHub excludes prereleases/drafts from
  # "latest". tagPrefix is stripped from the tag to yield the bare
  # version (e.g. tagPrefix = "rust-v" turns "rust-v0.145.0" into
  # "0.145.0"). Pair with mkUpdateScript's versionCheck.cmd.
  ghLatestVersionCmd = {
    pkgs,
    repo,
    tagPrefix ? "v",
  }: "${pkgs.curl}/bin/curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/${repo}/releases/latest | ${pkgs.gnused}/bin/sed -n 's|.*/tag/${tagPrefix}\\([0-9][^/]*\\)$|\\1|p'";

  # GitLab sibling of ghLatestVersionCmd. Prints the latest release
  # version of a project hosted on gitlab.com.
  #
  # An API call, unlike the GitHub one, because GitLab has no
  # releases/latest redirect to read a tag out of. Unauthenticated GET
  # against a public project, so still no token: gitlab.com allows 2000
  # unauthenticated GETs per minute per IP and the update sweep makes one
  # call per package 4x/day.
  #
  # `releases/permalink/latest` resolves to the release with the newest
  # `released_at` and EXCLUDES upcoming (future-dated) releases, which is
  # the property that makes it the analogue of GitHub's "latest".
  #
  # `project` is the URL-encoded path — the `/` in `owner/repo` must be
  # written `%2F`, which is why this takes an encoded string rather than
  # `repo` and encoding it here. Encoding it here would silently mangle a
  # caller that already encoded.
  #
  # Absolute store paths throughout: this string is interpolated into a
  # PATH-less writeShellScript by mkUpdateScript, and the
  # `versionCheck.cmd` scan in checks/shell/bare-commands.nix carries no
  # `/bin/` exclusion for exactly that reason.
  glLatestVersionCmd = {
    pkgs,
    project,
    tagPrefix ? "v",
  }: "${pkgs.curl}/bin/curl -fsSL https://gitlab.com/api/v4/projects/${project}/releases/permalink/latest | ${pkgs.jq}/bin/jq -r '.tag_name' | ${pkgs.gnused}/bin/sed -n 's|^${tagPrefix}\\([0-9].*\\)$|\\1|p'";

  # Resolve the Go toolchain for a package from its DECLARED FLOOR — the
  # `go` (or higher `toolchain`) directive in the package's own go.mod —
  # rather than from a pinned toolchain version.
  #
  #   floor satisfied by our pin  -> `ourGo`, no override, go-bin untouched
  #   floor above our pin         -> the LOWEST go-bin RELEASE that satisfies it
  #   floor above everything      -> throw, naming package, floor and newest
  #
  # WHY A FLOOR AND NOT A PIN. A pinned toolchain rots silently: it cannot
  # tell "still filling a real gap" from "nixpkgs caught up and this is now
  # a DOWNGRADE", and nothing announces the transition. The sibling repo
  # this was ported from demonstrates the failure live — it pins
  # oh-my-posh to Go 1.26.0, which was a gap-filler when written and is a
  # downgrade now that our pin ships 1.26.5. A floor is the durable fact
  # ("this package needs Go >= X"); the toolchain is derived from it.
  #
  # The shape is self-clearing with no timer and no cleanup PR: the moment
  # nixpkgs catches up, this returns `ourGo` and the go-bin path goes cold
  # by itself. It CANNOT EXPRESS A DOWNGRADE by construction. And the
  # requirement it exists for — a package raising its go.mod floor past
  # nixpkgs-unstable — is met automatically on the next eval instead of
  # waiting for a human to notice.
  #
  # Two alternatives were considered and rejected; do not reintroduce
  # either. A 30-day expiry timer fires on the CALENDAR, not on the
  # condition — it nags while the pin is still needed and stays silent
  # when the pin goes bad early. A hard throw once nixpkgs catches up
  # targets the right condition but turns a routine input bump into a red
  # PR a human must clear. go-overlay's own `fromGoMod` selector is also
  # out: it reads the floor from FETCHED SOURCE at eval time, which is
  # import-from-derivation, and this repo already tracks an open defect
  # where exactly that pattern dies under
  # `--option allow-import-from-derivation false`.
  #
  # PRERELEASES ARE FILTERED OUT, and that is load-bearing rather than
  # tidiness. go-bin carries 31 of them (1.17beta1 … 1.27rc3) alongside 131
  # releases (measured 2026-09-01). `go-bin.latest` reads 1.27.0 today,
  # but it HAS been a prerelease — it was 1.27rc2 when this was written —
  # which is why the selection resolves against `versions` rather than
  # any moving `latest`/`latestStable` selector: those are correct only
  # some of the time, and silently. Nix's component
  # comparison also sorts "1.27rc1" ABOVE "1.27.0" (a non-numeric
  # component loses a string compare to a numeric one), so an unfiltered
  # "lowest satisfying" would hand a package an rc toolchain the first
  # time a floor landed on an unreleased minor.
  #
  # Comparison is `lib.versionAtLeast` / `lib.versionOlder` throughout,
  # never string comparison — a string compare gets "1.9.0" vs "1.26.0"
  # backwards.
  #
  #   floor: bare version string from go.mod, e.g. "1.25.0"
  #   goBin: `go-bin` from an ourPkgs carrying go-overlay's overlay
  #   lib:   nixpkgs lib (for the version comparators)
  #   ourGo: `ourPkgs.go` — this repo's pinned toolchain
  #   pname: package name, for the throw message
  goToolchainForFloor = {
    floor,
    goBin,
    lib,
    ourGo,
    pname,
  }:
    if lib.versionAtLeast ourGo.version floor
    then ourGo
    else let
      releases =
        builtins.filter
        (v: builtins.match "[0-9]+\\.[0-9]+(\\.[0-9]+)?" v != null)
        (builtins.attrNames goBin.versions);
      ascending = builtins.sort lib.versionOlder releases;
      satisfying = builtins.filter (v: lib.versionAtLeast v floor) ascending;
      newest =
        if ascending == []
        then "none"
        else lib.last ascending;
    in
      if satisfying == []
      then
        throw ''
          ${pname}: needs Go >= ${floor}, but no toolchain that new is available.
            our nixpkgs pin ships go ${ourGo.version}
            newest go-bin release is ${newest}
          Run `nix flake update go-overlay` to pick up newly published toolchains.''
      else goBin.versions.${builtins.head satisfying};

  # The placeholder a Go overlay reads when its recorded floor is absent.
  # Every version satisfies it, so `goToolchainForFloor` returns `ourGo`
  # and applies no override.
  #
  # This is the `lib.fakeHash` of floors, and it exists for the same
  # reason: `mkUpdateScript` rebuilds the sidecar FROM SCRATCH
  # (`jq -n '{version: $v}'`), so `goFloor` is destroyed on every write
  # and restored by `mkGoFloorFix` as `extraExtract`. Between those two
  # moments the key does not exist, and `mkGoFloorFix` itself has to
  # evaluate the package to build its `.src` — so a `throw` here would
  # deadlock the very fixer that repairs it.
  #
  # Reading it is therefore SILENT by construction. That is deliberate,
  # and `checks/packaging/go-floor-drift.nix` is the loud half: it compares every
  # recorded floor against the package's real go.mod and fails naming the
  # package and the expected value. Same division of labour as the
  # extracted sidecars — permissive at eval, gated by a check.
  goFloorUnknown = "0";

  # Shell function printing the EFFECTIVE Go floor of a go.mod: the
  # higher of its `go` and `toolchain` directives.
  #
  # ONE definition, consumed by BOTH `mkGoFloorFix` (writes the floor at
  # bump time) and `checks/packaging/go-floor-drift.nix` (asserts it still matches
  # source). A second copy of this parse is precisely how the writer and
  # the gate would come to disagree about what the floor is, and the
  # disagreement would present as a drift check that cannot be made green.
  #
  # `toolchain` is spelled `go1.26.5` and `go` is spelled `1.26.5`; both
  # normalize to the bare version. `sort -V` orders them — a plain string
  # compare gets "1.9" vs "1.26" backwards, the same trap
  # `goToolchainForFloor` avoids with `lib.versionAtLeast`.
  #
  # Fails loud on a go.mod carrying no `go` directive rather than
  # printing empty. An empty floor is the worst possible outcome here: it
  # makes `goToolchainForFloor` return `ourGo`, so the seam silently does
  # nothing and the package builds against whatever toolchain happens to
  # be in scope — the exact failure this mechanism exists to remove.
  goModFloorFn = {pkgs}: ''
    go_floor_of() {
      gm="$1"
      gd=$(${pkgs.gnused}/bin/sed -n 's/^go[[:space:]]\{1,\}\([0-9][0-9.]*\).*/\1/p' "$gm" | ${pkgs.coreutils}/bin/head -n1)
      td=$(${pkgs.gnused}/bin/sed -n 's/^toolchain[[:space:]]\{1,\}go\([0-9][0-9.]*\).*/\1/p' "$gm" | ${pkgs.coreutils}/bin/head -n1)
      if [ -z "$gd" ]; then
        echo "go-floor: no 'go' directive in $gm (upstream restructured go.mod)" >&2
        return 1
      fi
      if [ -n "$td" ]; then
        printf '%s\n%s\n' "$gd" "$td" | ${pkgs.coreutils}/bin/sort -V | ${pkgs.coreutils}/bin/tail -n1
      else
        printf '%s\n' "$gd"
      fi
    }
  '';

  # Floor fixer for a Go package pinned via a sidecar. Derives the floor
  # from the FRESHLY PINNED source's go.mod and writes it back as
  # `goFloor`. Wired as `extraExtract`, the same seam the hash fixers use.
  #
  # WHY DERIVED AND NOT DECLARED. A hand-maintained floor literal is a
  # pin, and `goToolchainForFloor`'s own header explains at length why a
  # pinned toolchain rots silently. Moving the pin from toolchain-version
  # to floor-version made it rot more slowly, not never: the update
  # pipeline bumps these packages 4x/day and would never touch the
  # literal. A stale-LOW floor is the dangerous direction — the seam then
  # returns `ourGo` and quietly does nothing.
  #
  # The floor is a function of the pinned source, so it changes only when
  # the version changes — which is exactly when this runs. That is what
  # makes `extraExtract` (a version-bump-only seam) the correct home for
  # it, unlike `vendorHash`, which can be invalidated with no version
  # bump and therefore also needs a standalone `passthru` escape hatch.
  #
  # ORDER: AFTER the SRC hash fixer, and BEFORE the vendor fixer. Both
  # halves are load-bearing and the second one was missing until
  # 2026-09-01, which is the whole reason `mkGoUpdateExtract` below now
  # owns the sequence instead of each overlay restating it.
  #
  #   AFTER the src fixer, because this builds `.src` — a package whose
  #   `srcHash` also lives in the sidecar (glab) must have that restored
  #   first or this fails on the src mismatch instead.
  #
  #   BEFORE the vendor fixer, because that one builds `.goModules`,
  #   which COMPILES Go under the toolchain `goToolchainForFloor`
  #   selects. `mkUpdateScript`'s `buildCandidate` rebuilds the sidecar
  #   from scratch (`jq -n '{version: $v}'`), so at that moment `goFloor`
  #   is not stale — it is ABSENT, reads as `goFloorUnknown` ("0"), and
  #   every toolchain satisfies it, so the selector returns `ourGo`. A
  #   bump that raises the floor past our pin then dies with
  #   `go.mod requires go >= X (running go <ourGo>)` before the floor
  #   fixer it needed ever runs. Measured 2026-09-01: glab 1.116.0 and
  #   oh-my-posh 31.1.1 both wanted go 1.27.0 against ourGo 1.26.7, and
  #   both were HELD BACK on every sweep.
  #
  # The header used to say only "run this AFTER any hash fixer", and the
  # over-general half of that is what propagated. FOUR overlays carried a
  # paraphrase of it — gh, gluetun, oh-my-posh, otel-tui, each spelling it
  # "ORDER: hash fixer first, then the floor" — while beads carried no
  # such comment on either of its two chains and glab carried a longer,
  # different one. Seven CHAINS across six files ended up vendor-before-
  # floor; only four of them said why. (An earlier draft of this comment
  # said "six overlays copied it verbatim". Measured against the tree: the
  # verbatim string appeared exactly once, in this file.)
  #
  # In every paraphrasing overlay the justification was vacuous anyway:
  # `mkGoVendorFix` restores no src hash, so nothing was being ordered
  # before it for the stated reason.
  #
  # NOTE that preserving `goFloor` across the sidecar rewrite is NOT an
  # alternative fix, however much smaller the diff looks. The committed
  # floors were 1.26.5 (glab) and 1.26.0 (oh-my-posh); measured, BOTH
  # still select ourGo 1.26.7. Only deriving the floor from the fresh
  # source before the vendor build changes the outcome.
  #
  #   attr:       flake package attribute (built through `.#<attr>.src`)
  #   goModPath:  go.mod location inside src — NOT always the root;
  #               oh-my-posh keeps its module under `src/`.
  mkGoFloorFix = {
    attr,
    goModPath ? "go.mod",
    pkgs,
    pname,
    sourcesFile,
  }:
    pkgs.writeShellScript "fix-go-floor-${pname}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      ${goModFloorFn {inherit pkgs;}}

      src=$(${pkgs.nix}/bin/nix build --no-link --print-out-paths ".#${attr}.src")
      floor=$(go_floor_of "$src/${goModPath}")

      ${pkgs.jq}/bin/jq --arg f "$floor" '. + {goFloor: $f}' "${sourcesFile}" \
        > "${sourcesFile}.new"
      ${pkgs.coreutils}/bin/mv "${sourcesFile}.new" "${sourcesFile}"
      echo "${pname}: goFloor = $floor"
    '';

  # `buildGoModule` with its toolchain derived from `floor`. The one
  # composition every Go overlay here uses, so the floor -> toolchain ->
  # builder chain is written once instead of once per package.
  #
  # `pkgs` MUST carry go-overlay's overlay (for `go-bin`). It is purely
  # additive — `pkgs.go` is byte-identical with and without it — so
  # adding it to a package's `ourPkgs` moves no derivation, and every Go
  # package sharing one overlay list collapses to a single nixpkgs
  # instantiation rather than one apiece.
  mkGoBuilder = {
    floor,
    pkgs,
    pname,
  }:
    pkgs.buildGoModule.override {
      go = goToolchainForFloor {
        inherit floor pname;
        goBin = pkgs.go-bin;
        inherit (pkgs) lib;
        ourGo = pkgs.go;
      };
    };

  # The (attrPath, drvPattern, key) triples that the sidecar hash fixers
  # below compose. Declared once and named, so the derivation-name
  # patterns — which are load-bearing rather than decorative; see
  # `fodHashFixFn` — cannot drift between the three fixers that use them.
  hashFixTargets = {
    goVendor = {
      attrPath = "goModules";
      drvPattern = "-go-modules";
      key = "vendorHash";
    };
    npmDeps = {
      attrPath = "npmDeps";
      drvPattern = "-npm-deps";
      key = "npmDepsHash";
    };
    pnpmDeps = {
      attrPath = "pnpmDeps";
      drvPattern = "-pnpm-deps";
      key = "pnpmDepsHash";
    };
    src = {
      attrPath = "src";
      drvPattern = "-source";
      key = "srcHash";
    };
  };

  # `extraExtract` body regenerating a committed `*-extracted.json`
  # sidecar from the freshly-bumped package, inside the SAME version-bump
  # PR. Every package carrying a `passthru.extracted` needs one: without
  # it the sidecar keeps describing the OLD artifact and
  # `checks/<pkg>-extracted.nix` goes red on the bump. That is not
  # hypothetical — it is how glab's first-ever bump failed (PR #621),
  # glab having been the one extracted package that never wired it.
  #
  # Builds the pure `passthru.extracted` against the just-written
  # sources.json (dirty-tracked, so flake eval sees the new version) and
  # copies it over the committed path. ONE extraction source: the drift
  # check consumes the same `passthru.extracted`, so the two cannot
  # disagree about what "extracted" means.
  #
  # `nix fmt` is load-bearing, not tidiness. The extractors emit jq /
  # Go-encoder JSON, which pretty-prints EVERY array multi-line, while
  # biome — the repo's JSON formatter via treefmt — collapses short
  # arrays onto one line. Skip it and the sidecar lands not
  # treefmt-clean, trading the drift failure for a `checks.formatting`
  # one. It formats the WORKING-TREE copy after the `cp`, never the store
  # original — see .claude/rules/nix-standards.md.
  #
  # Absolute store paths throughout: this is spliced into a
  # `writeShellScript` the update pipeline invokes directly, which is
  # PATH-less.
  mkExtractRegen = {
    attr,
    dest,
    pkgs,
  }: ''
    echo "${attr}: regenerating ${dest}"
    extracted=$(${pkgs.nix}/bin/nix build --no-link --print-out-paths \
      ".#${attr}.passthru.extracted")
    ${pkgs.coreutils}/bin/cp "$extracted" "${dest}"
    ${pkgs.coreutils}/bin/chmod 644 "${dest}"
    ${pkgs.nix}/bin/nix fmt -- "${dest}"
    echo "${attr}: wrote ${dest}"
  '';

  # THE `extraExtract` CHAIN for a sidecar-pinned Go package. One call
  # emits every fixer that package needs, IN THE ONE LEGAL ORDER, so no
  # overlay ever restates a sequence again.
  #
  # It replaced `mkGoSrcVendorFix` (src+vendor welded into one script),
  # which could not express the correct order at all — see below.
  #
  # WHY THIS EXISTS. Every Go overlay used to hand-write
  # `extraExtract = "''${fixVendorHash}\n''${fixGoFloor}"`, and all seven
  # CHAINS got it backwards — seven across SIX files, because beads owns
  # two (its own and beads-dolt's). The vendor fixer builds `.goModules`, which
  # COMPILES Go under the toolchain `goToolchainForFloor` picks from the
  # sidecar's `goFloor`; the floor fixer is what WRITES that key. Since
  # `mkUpdateScript`'s `buildCandidate` rebuilds the sidecar from scratch
  # (`jq -n '{version: $v}'`), the floor is ABSENT — not stale — for the
  # whole window, reads as `goFloorUnknown` ("0"), and the selector
  # returns `ourGo`. A release that raises its go.mod floor past our pin
  # therefore dies with `go.mod requires go >= X` inside the vendor
  # fixer, before the floor fixer that would have fixed it ever runs.
  #
  # Measured 2026-09-01: glab 1.116.0 and oh-my-posh 31.1.1 both declare
  # `go 1.27.0`, ourGo was 1.26.7, go-bin had 1.27.0 available the whole
  # time, and both packages were HELD BACK on every 4x/day sweep.
  #
  # THE ORDER, and why each edge is real:
  #
  #   [src fixer]  -> floor fixer -> [guard] -> vendor fixer -> [extraAfter]
  #
  #   src BEFORE floor    the floor fixer builds `.src`; a package whose
  #                       srcHash lives in the sidecar holds `lib.fakeHash`
  #                       until the src fixer has run.
  #   floor BEFORE vendor the vendor fixer compiles Go. This is the edge
  #                       that was missing.
  #   vendor BEFORE extra `extraAfter` is for a package whose extract also
  #                       compiles Go against the vendor tree (glab's
  #                       config-key schema dump), so it needs both the
  #                       toolchain the floor selects AND `.goModules`.
  #
  # `extraAfter` RUNS IN A CHILD PROCESS now, which it did not before.
  # It used to be spliced inline into `mkUpdateScript`'s own shell, where
  # `$latest`, `$current` and `$tmp` were in scope; it is now inside this
  # `writeShellScript`, which does not export them. A snippet that reads
  # one would die under `set -u`. Today's only consumer,
  # `mkExtractRegen`, is self-contained. Keep it that way, or export
  # what a future one needs.
  #
  # `srcFromSidecar` is the ONLY axis packages differ on, and it is
  # decided by one thing: whether `mkUpdateScript` was given
  # `platforms = {...}` (it prefetches the src hash itself — gh, gluetun,
  # oh-my-posh, otel-tui, beads) or `platforms = {}` (the src hash comes
  # from a fixer — glab, whose upstream fetcher carries a `postFetch`
  # that `nix-prefetch-url --unpack` cannot reproduce).
  #
  # RETURNS a record, not a string: `extract` for `extraExtract`, plus
  # the individual fixers for `passthru`. `fixVendorHash` MUST keep that
  # exact name in passthru — `fix_sidecar_hashes`
  # (dev/scripts/update-common.sh) discovers it with a bare
  # `p.fixVendorHash or null` to self-heal a vendor hash invalidated by
  # an input bump with no version change. glab previously exposed only a
  # combined `fixHashes` and was silently outside that roster.
  #
  # HALF of glab's exposure is still unreachable, and that is a known gap
  # rather than a fixed one. `fix_sidecar_hashes` discovers dependency
  # fixers only, so `fixSrcHash` has no caller: a nixpkgs
  # fetcher change that invalidates glab's `srcHash` with no version bump
  # still cannot self-heal. It presents confusingly, too — `fixVendorHash`
  # builds `.goModules`, the `-source` FOD mismatches first, and
  # `fodHashFixFn` reports "goModules build failed without a
  # '-go-modules' hash mismatch". Bruno's `mkNpmDepsFix` avoids this by
  # restoring src+deps in ONE script; the Go side deliberately split them
  # so the floor fix could sit between, which is the trade.
  mkGoUpdateExtract = {
    attr,
    extraAfter ? "",
    goModPath ? "go.mod",
    pkgs,
    pname,
    sourcesFile,
    srcFromSidecar ? false,
  }: let
    fixSrcHash = mkHashFix {
      inherit attr pkgs pname sourcesFile;
      name = "src";
      targets = [hashFixTargets.src];
    };
    fixGoFloor = mkGoFloorFix {inherit attr goModPath pkgs pname sourcesFile;};
    fixVendorHash = mkGoVendorFix {inherit attr pkgs pname sourcesFile;};

    # Tripwire, not a safety net — by construction it cannot fire in the
    # chain below, because the floor fixer is two lines above it. It
    # exists so that if anyone ever reorders these again, the failure is
    # ONE self-describing line instead of what this bug actually looked
    # like: `goModules build failed without a '-go-modules' hash
    # mismatch` followed by a wall of nix output whose only real clue was
    # a `go.mod requires go >= X` buried in the last eight log lines.
    assertFloorPresent = pkgs.writeShellScript "assert-go-floor-${pname}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      if ! ${pkgs.jq}/bin/jq -e 'has("goFloor")' "${sourcesFile}" >/dev/null; then
        echo "${pname}: ${sourcesFile} has no goFloor, but the vendor fixer is about to compile Go." >&2
        echo "  The floor fixer must run BEFORE the vendor fixer. See mkGoUpdateExtract in lib/packaging.nix." >&2
        exit 1
      fi
    '';
  in {
    inherit fixGoFloor fixSrcHash fixVendorHash;

    # A single writeShellScript rather than a concatenated snippet, so
    # `checks/packaging/go-floor-extract-order.nix` has ONE flat file to read the
    # order out of. A package that composes its updateScript from
    # sub-scripts (beads runs two) would otherwise hide the ordering
    # behind a wrapper the check cannot see through.
    extract = pkgs.writeShellScript "go-update-extract-${pname}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      ${
        if srcFromSidecar
        then "${fixSrcHash}"
        else "# src hash came from mkUpdateScript's prefetch"
      }
      ${fixGoFloor}
      ${assertFloorPresent}
      ${fixVendorHash}
      ${extraAfter}
    '';
  };

  # Vendor-hash fixer for buildGoModule packages pinned via a sidecar:
  # builds `<attr>.goModules` through the full flake overlay stack with
  # the sidecar's current vendorHash and, on a hash mismatch, writes the
  # correct hash back to sourcesFile. Runs from the repo root.
  #
  # REQUIRED, not a convenience, because of how mkUpdateScript writes.
  # `buildCandidate` above opens with
  # `jq -n --arg v "$latest" '{version: $v}' > "$tmp"` — the candidate
  # sidecar is built FROM SCRATCH, so any key the writer does not itself
  # produce is DESTROYED on every write. `vendorHash` is exactly such a
  # key. That is why every Go overlay here reads
  # `sources.vendorHash or lib.fakeHash` (the `or` covers the transient
  # mid-update state) and why this runs as `extraExtract`, immediately
  # after the sidecar write.
  #
  # Exposed standalone as `passthru.fixVendorHash` as well, because a
  # nixpkgs or Go-toolchain bump can invalidate vendorHash with no
  # version bump at all, and `extraExtract` only fires on a version bump.
  # `fix_sidecar_hashes` (dev/scripts/update-common.sh) discovers this
  # attr across `packages.<system>` and runs it when an input bump's
  # build verification fails, so that case self-heals into the same
  # commit instead of parking the whole input update as HELD BACK.
  # Until 2026-07-25 that standalone had NO caller at all and this
  # comment claimed a re-run that did not exist — if you unwire
  # `fix_sidecar_hashes`, fix this sentence too.
  #
  # The build-and-scrape body lives in `fodHashFixFn` above; see its
  # header for the argument contract and for why the `-go-modules`
  # derivation-name pattern is load-bearing rather than decorative.
  mkGoVendorFix = args:
    mkHashFix (args
      // {
        name = "vendor";
        targets = [hashFixTargets.goVendor];
      });

  # Shared body of every sidecar hash fixer. Emits a writeShellScript
  # that sources `fodHashFixFn`'s `fix_fod_hash` and then calls it once
  # per target, in the order given.
  #
  # Shared by the Go, npm, source and owner-declared pnpm repairs. Callers
  # select the named (attrPath, drvPattern, key) targets; this helper owns
  # strict mode and invokes the common mismatch parser for each target.
  #
  # ORDER IS SIGNIFICANT and is the caller's responsibility: a derived
  # hash (`goModules`, `npmDeps`) is computed FROM `src`, so `src` must
  # be fixed first or the derived build fails on the src mismatch and
  # never reaches its own.
  mkHashFix = {
    attr,
    name,
    pkgs,
    pname,
    sourcesFile,
    targets,
  }:
    pkgs.writeShellScript "fix-${name}-${pname}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      ${fodHashFixFn {inherit attr pkgs pname sourcesFile;}}

      ${builtins.concatStringsSep "\n" (map (t: ''fix_fod_hash "${t.attrPath}" "${t.drvPattern}" "${t.key}"'') targets)}
    '';

  # Hash fixer for buildNpmPackage packages pinned via a sidecar. Same
  # role as `mkGoVendorFix` and the same `extraExtract` wiring, but it
  # restores TWO keys, in order: `srcHash` then `npmDepsHash`.
  #
  # Both keys, and not just the deps one, because a `buildNpmPackage`
  # overlay that re-points `src` by OVERRIDING the upstream fetcher
  # (`upstream.src.override { tag; hash; }` — the only way to keep an
  # upstream `postFetch` without restating it) cannot get its src hash
  # from `mkUpdateScript`'s prefetch path. Measured on bruno v4.0.0:
  # `nix-prefetch-url --unpack` of the repo-archive tarball yields
  # sha256-uZswYGMwVfiIG+dNec6mEno05UVbsWlVHoNFadipQlg=, while the
  # fetcher — whose `postFetch` runs `npm-lockfile-fix` over
  # package-lock.json — yields
  # sha256-M4oNx3nSe8hSAtZMVyXIW0qQIQkaOeQgpPsfjmmJ30E=. Recording the
  # prefetch hash would simply fail the consumer's fixed-output check. So
  # such a package passes `platforms = {}` to `mkUpdateScript` — the
  # sidecar then carries the version alone — and lets this restore both
  # hashes immediately afterwards.
  #
  # The order is forced: `npmDeps` is derived FROM `src`
  # (`build-support/node/build-npm-package` threads `src` and the patch
  # hooks into `fetchNpmDeps`), so a stale `srcHash` makes the deps build
  # fail on the SRC mismatch and never reach the deps one.
  #
  # Exposed standalone as `passthru.fixNpmDepsHash` for the same reason
  # its Go sibling is: a nixpkgs-side fetcher or builder change can
  # invalidate either hash with no version bump at all, and the sidecar's
  # version-equality early exit means that case fails LOUDLY on a hash
  # mismatch rather than self-healing.
  mkNpmDepsFix = args:
    mkHashFix (args
      // {
        name = "npm-deps";
        targets = [hashFixTargets.src hashFixTargets.npmDeps];
      });

  # Generate an updateScript for per-platform binary packages that use
  # sources.json. Fetches the latest version, prefetches each platform's
  # binary, writes version + per-platform hashes to sourcesFile.
  #
  # alwaysPrefetch: skip the version-equality early exit and prefetch on
  #   EVERY run, then decide whether to write by comparing the freshly
  #   built sidecar against the committed one. Defaults to false, which
  #   leaves every other caller on exactly today's control flow.
  #
  #   For a package whose artifact URL carries its version, the early
  #   exit is free and correct: same version means same URL means same
  #   bytes. For a package whose URL is VERSION-INDEPENDENT it is a
  #   silent-staleness bug — the version string becomes the ONLY change
  #   signal, so upstream re-serving modified content at the same URL
  #   without advancing its version leaves the committed hash stale and
  #   `fetchurl` failing until the version happens to move.
  #   `packages/dns-root-hints/packages/ai/generic/dns-root-hints/package.nix` is the only such consumer
  #   today (InterNIC re-serves one canonical URL; its "version" is a
  #   root-zone serial scraped out of the file body).
  #
  #   COST: one prefetch per opted-in package per sweep, every sweep,
  #   whether or not anything moved. For one small file 4x/day that is
  #   nothing; for a multi-hundred-MB per-platform release asset set it
  #   would not be. That asymmetry is why this is opt-in rather than the
  #   default, and why widening it should be argued per package.
  # versionCheck: { cmd = "curl ..."; } — shell command that prints the version
  # platforms: { "x86_64-linux" = ver: "https://.../${ver}/file.tar.gz"; ... }
  #   An EMPTY set is legal and means "record the version only". Use it
  #   when the package's src hash is not a plain prefetch of a URL — an
  #   overlay that re-points an upstream fetcher carrying a `postFetch`
  #   gets a hash over the POST-postFetch tree, which `nix-prefetch-url`
  #   cannot reproduce. Such a package pairs `platforms = {}` with an
  #   `extraExtract` fixer that scrapes the real hashes out of a build
  #   (see `mkNpmDepsFix`); recording the prefetch hash instead would put
  #   a plausible, wrong value in the sidecar.
  # sourcesFile: path to sources.json relative to repo root
  # extraExtract: extra shell appended after the sources.json write (e.g.
  #   regenerating a committed sidecar from the freshly-bumped binary).
  #   Defaults to "" so callers that don't need it are unaffected.
  # unpack: hash the UNPACKED tarball (`nix-prefetch-url --unpack`) — for
  #   fetchzip consumers of repo-archive tarballs, whose fixed-output hash
  #   is over the unpacked NAR, as opposed to the flat-file hash a
  #   fetchurl consumer wants. Wrong either way round: the prefetch
  #   succeeds and the recorded hash simply fails the consumer's check.
  # pkgs: nixpkgs set (for curl, jq, nix)
  mkUpdateScript = {
    alwaysPrefetch ? false,
    # Additional per-platform artifacts from the SAME release, keyed by a
    # sidecar attribute name: `{ <attr> = { <system> = ver: url; }; }`.
    # Each lands NESTED inside its system's entry —
    # `<system>.<attr> = {url, hash}` — so `meta.platforms`, which reads
    # `attrNames (removeAttrs sources ["version"])`, keeps seeing systems
    # and only systems.
    #
    # The point is version LOCKSTEP. A companion binary pinned by hand in
    # the overlay would keep its old URL when the pipeline bumps the main
    # artifact, leaving a mismatched pair that still evaluates — the worst
    # kind of breakage, because nothing fails until the two disagree at
    # runtime.
    extraAssets ? {},
    extraExtract ? "",
    pkgs,
    platforms,
    pname,
    sourcesFile,
    unpack ? false,
    versionCheck,
  }: let
    # Build the candidate sidecar in "$tmp": the version, then one
    # {url, hash} entry per platform. Identical in both modes — the two
    # flows differ only in whether they reach it and what they do with
    # the result — so it is bound once rather than duplicated.
    # A URL containing %20 yields an illegal store name, so nix-prefetch-url
    # needs an explicit --name. Shared by the primary asset and every
    # extraAsset: this was duplicated once and the copies immediately drifted,
    # leaving extra assets able to fail on a URL the primary handled fine.
    prefetchNameArg = name: url:
      if builtins.match ".*%20.*" url != null
      then "--name ${name}-prefetch"
      else "";

    buildCandidate = ''
      tmp=$(${pkgs.coreutils}/bin/mktemp)
      ${pkgs.jq}/bin/jq -n --arg v "$latest" '{version: $v}' > "$tmp"

      ${builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (system: mkUrl: let
          # Braced so the template stays safe when the next character is a
          # valid identifier char (e.g. "..._''${ver}_amd64.deb" would
          # otherwise expand the undefined "$latest_amd64").
          url = mkUrl "\${latest}";
          nameArg = prefetchNameArg pname url;
          unpackArg =
            if unpack
            then "--unpack"
            else "";
        in ''
          url="${url}"
          prefetched=$(${pkgs.nix}/bin/nix-prefetch-url --type sha256 ${unpackArg} ${nameArg} "$url")
          hash=$(${pkgs.nix}/bin/nix hash convert --to sri --hash-algo sha256 "$prefetched")
          ${pkgs.jq}/bin/jq --arg sys "${system}" --arg u "$url" --arg h "$hash" \
            '. + {($sys): {url: $u, hash: $h}}' "$tmp" > "''${tmp}.new" && ${pkgs.coreutils}/bin/mv "''${tmp}.new" "$tmp"

          ${builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (
              assetName: assetPlatforms:
              # An asset with no build for this system is simply absent: the
              # consumer sees no key and decides what that means. Emitting a
              # wrong-arch URL would be worse than emitting nothing.
                if !(builtins.hasAttr system assetPlatforms)
                then ""
                else let
                  assetUrl = (builtins.getAttr system assetPlatforms) "\${latest}";
                  # Distinct from the primary's name so two prefetches in one
                  # run cannot be confused for each other in the store.
                  assetNameArg = prefetchNameArg "${pname}-${assetName}" assetUrl;
                in ''
                  asset_url="${assetUrl}"
                  asset_prefetched=$(${pkgs.nix}/bin/nix-prefetch-url --type sha256 ${unpackArg} ${assetNameArg} "$asset_url")
                  asset_hash=$(${pkgs.nix}/bin/nix hash convert --to sri --hash-algo sha256 "$asset_prefetched")
                  ${pkgs.jq}/bin/jq --arg sys "${system}" --arg n "${assetName}" \
                    --arg u "$asset_url" --arg h "$asset_hash" \
                    '.[$sys] += {($n): {url: $u, hash: $h}}' "$tmp" > "''${tmp}.new" \
                    && ${pkgs.coreutils}/bin/mv "''${tmp}.new" "$tmp"
                ''
            )
            extraAssets))}
        '')
        platforms))}
    '';

    commitCandidate = ''
      ${pkgs.coreutils}/bin/mv "$tmp" "${sourcesFile}"
      echo "Updated ${sourcesFile}"
      ${extraExtract}
    '';

    # Default flow — the pre-alwaysPrefetch control flow, unchanged.
    # Version equality means "nothing moved", which is true for every
    # package whose artifact URL carries its version.
    defaultFlow = ''
      if [ "$latest" = "$current" ]; then
        echo "${pname}: already at $current"
        exit 0
      fi

      echo "${pname}: $current -> $latest"
      ${buildCandidate}
      ${commitCandidate}
    '';

    # Always-prefetch flow — the prefetch IS the change detector.
    alwaysFlow = ''
      # No version-equality early exit: for this package the version is
      # not a reliable change signal (see `alwaysPrefetch` in the header),
      # so the only way to learn whether upstream moved is to fetch and
      # hash it.
      ${buildCandidate}

      # Compare NORMALIZED (jq -S), so key order or whitespace in the
      # committed file cannot masquerade as a change. The version half and
      # the everything-else (hash) half are compared separately only so
      # the message below can name what actually moved; together they
      # cover the whole document.
      newHashes=$(${pkgs.jq}/bin/jq -S 'del(.version)' "$tmp")
      oldHashes=$(${pkgs.jq}/bin/jq -S 'del(.version)' "${sourcesFile}")

      if [ "$latest" = "$current" ] && [ "$newHashes" = "$oldHashes" ]; then
        # Deliberately does NOT write. An unconditional mv would churn the
        # file's mtime on every sweep and hand the update pipeline an
        # empty diff to try to commit.
        ${pkgs.coreutils}/bin/rm -f "$tmp"
        echo "${pname}: already at $current (version and hashes unchanged)"
        exit 0
      fi

      # Deferred until after the comparison on purpose. The default flow
      # announces "$current -> $latest" BEFORE prefetching, which here
      # would read "X -> X" whenever only the hash moved — the exact case
      # this mode exists to catch.
      if [ "$latest" != "$current" ] && [ "$newHashes" != "$oldHashes" ]; then
        echo "${pname}: version and hash moved: $current -> $latest"
      elif [ "$latest" != "$current" ]; then
        echo "${pname}: version moved: $current -> $latest"
      else
        echo "${pname}: hash moved at unchanged version $current (upstream re-served the same URL)"
      fi
      ${commitCandidate}
    '';
  in
    pkgs.writeShellScript "update-${pname}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      latest=$(${versionCheck.cmd})
      if [ -z "$latest" ]; then
        echo "${pname}: failed to fetch latest version" >&2
        exit 1
      fi

      current=$(${pkgs.jq}/bin/jq -r '.version' "${sourcesFile}")
      ${
        if alwaysPrefetch
        then alwaysFlow
        else defaultFlow
      }
    '';
}
