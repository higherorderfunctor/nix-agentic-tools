# lib/packaging.nix — DRY version extraction + smoke test helpers.
#
# One exception: `fetchHuggingFaceModel` is consumer-facing, exported
# through the flake's `lib.packaging`. It lives here temporarily.
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
  # The flake attribute path of a package in the internal unfree-enabled set
  # (flake.nix `ciPackages`). The public `packages` omits unfree packages, so
  # every generated script that reads a package by name goes through here.
  ciAttr = {
    attr,
    pkgs,
  }: "ciPackages.${pkgs.stdenv.hostPlatform.system}.${attr}";

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
  # A successful build is read as "the recorded hash is right", and that
  # only holds when the build actually FETCHED. A fixed-output path is a
  # function of its name and its declared hash, so when nothing in either
  # moved — a nixpkgs, toolchain or pnpm bump at an unchanged package
  # version — the path is the one already in the local store or in cachix.
  # Nix substitutes it, the build succeeds, and this reports `ok` without
  # comparing anything. So a caller that has NOT first reset the key to
  # `lib.fakeHash` repairs a stale hash only when the old output is not
  # substitutable. The version-bump chain always resets it (`buildCandidate`
  # rewrites the sidecar from scratch); `fix_sidecar_hashes` in
  # dev/scripts/update-common.sh does not. A substituted stale output is
  # also what the verification build consumed, so no hash mismatch was
  # seen there either: the package builds, or it fails in its build phase
  # and the input PR opens red. It is never committed as a silently wrong
  # hash, but nothing here re-derives it.
  #
  # Runs from the repo root, and the sidecar must be GIT-TRACKED: a flake
  # only sees tracked files, so an untracked sidecar is invisible to the
  # eval this drives.
  #
  #   attr:        name under `ciPackages.<system>` (flake.nix flattens
  #                `pkgs.ai.generic` into it, so a generic package is
  #                reachable by its bare name; see `ciAttr`).
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

      # The expression carries no brace substitution sequence, so bash never
      # tries to expand any part of it.
      expr="(builtins.getFlake (toString ./.)).${ciAttr {inherit attr pkgs;}}.$attrPath"

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

  # The placeholder a Go overlay reads when its recorded floor is absent.
  # Every version satisfies it, so `mkGoToolchain` accepts it and the
  # floor validation passes vacuously. The toolchain itself never depends
  # on the floor: it is always the newest stable locked go-overlay release.
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
  # `mkGoToolchain` avoids with `lib.versionAtLeast`.
  #
  # Fails loud on a go.mod carrying no `go` directive rather than
  # printing empty. An empty floor is the worst possible outcome here: it
  # makes `mkGoToolchain`'s validation pass vacuously, so a source that
  # outran the locked Go would fail inside the Go build instead of at the
  # named throw — the exact failure this mechanism exists to remove.
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

  # Floor fixer for a Go package. Derives the floor from the FRESHLY PINNED
  # source's go.mod and writes it to exactly one package-owned destination:
  # a release package's JSON sidecar or a trunk package's recipe literal.
  #
  # WHY DERIVED AND NOT DECLARED. A hand-maintained floor literal is a pin,
  # and a stale-LOW floor makes `mkGoToolchain`'s validation pass vacuously.
  # Both destination modes therefore derive their value from pinned source;
  # recipe literals are updater-owned storage, not maintainer-owned data.
  #
  # Release packages run this through `extraExtract`; rev-tracked packages
  # expose it to update-pkg.sh, which invokes it before nix-update and also on
  # an unchanged-rev sweep.
  #
  # ORDER: AFTER the SRC hash fixer, and BEFORE the vendor fixer.
  #
  #   AFTER the src fixer, because this builds `.src` — a package whose
  #   `srcHash` also lives in the sidecar (glab) must have that restored
  #   first or this fails on the src mismatch instead.
  #
  #   BEFORE the vendor fixer, because `mkUpdateScript` rebuilds the sidecar
  #   from scratch, so `goFloor` is ABSENT (`goFloorUnknown`) until this
  #   runs. `mkGoToolchain` always selects the newest stable locked Go, so
  #   the order no longer picks a compiler; it makes a source that outran
  #   the locked go-overlay fail at `mkGoToolchain`'s named throw instead of
  #   inside the vendor build. `mkGoUpdateExtract` owns the sequence and
  #   `checks/packaging/go-floor-extract-order.nix` gates it.
  #
  #   attr:       flake package attribute (built through `ciAttr`'s `.src`)
  #   goModPath:  go.mod location inside src — NOT always the root;
  #               oh-my-posh keeps its module under `src/`.
  mkGoFloorFix = {
    attr,
    goModPath ? "go.mod",
    pkgs,
    pname,
    recipeFile ? null,
    sourcesFile ? null,
  }:
    assert pkgs.lib.assertMsg ((recipeFile == null) != (sourcesFile == null))
    "mkGoFloorFix requires exactly one of recipeFile or sourcesFile";
      (pkgs.writeShellScript "fix-go-floor-${pname}" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        ${goModFloorFn {inherit pkgs;}}

        src=$(${pkgs.nix}/bin/nix build --no-link --print-out-paths ".#${ciAttr {inherit attr pkgs;}}.src")
        floor=$(go_floor_of "$src/${goModPath}")

        ${
          if sourcesFile != null
          then ''
            ${pkgs.jq}/bin/jq --arg f "$floor" '. + {goFloor: $f}' "${sourcesFile}" \
              > "${sourcesFile}.new"
            ${pkgs.coreutils}/bin/mv "${sourcesFile}.new" "${sourcesFile}"
          ''
          else ''
            ${pkgs.python3}/bin/python3 - "$floor" "${recipeFile}" <<'PY'
            import os
            import re
            import sys
            from pathlib import Path

            floor, raw_path = sys.argv[1:]
            path = Path(raw_path)
            text = path.read_text()
            pattern = re.compile(r'^(\s*goFloor\s*=\s*)"[^"]*"(\s*;\s*)$', re.MULTILINE)
            matches = list(pattern.finditer(text))
            if len(matches) != 1:
                print(
                    f"{path}: expected exactly one goFloor literal, found {len(matches)}",
                    file=sys.stderr,
                )
                raise SystemExit(1)
            updated = pattern.sub(rf'\g<1>"{floor}"\g<2>', text, count=1)
            temporary = path.with_name(f"{path.name}.new")
            temporary.write_text(updated)
            os.replace(temporary, path)
            PY
          ''
        }
        echo "${pname}: goFloor = $floor"
      '')
    .overrideAttrs (prev: {
        passthru =
          (prev.passthru or {})
          // {
            goFloorDestination =
              if sourcesFile != null
              then "sidecar"
              else "recipe";
          };
      });

  # The (attrPath, drvPattern, key) triples that the sidecar hash fixers
  # below compose. Declared once and named, so the derivation-name
  # patterns — which are load-bearing rather than decorative; see
  # `fodHashFixFn` — cannot drift between the three consumers that replay
  # them: `mkGoUpdateExtract`, `mkNpmDepsFix`, and an
  # owner-declared `mkHashFix` such as kimchi's pnpm repair.
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
  # Builds the pure `passthru.<extract>` (default `extracted`) against the
  # just-written sources.json (dirty-tracked, so flake eval sees the new
  # version) and copies it over the committed path. ONE extraction source:
  # the drift check consumes the same passthru attribute, so the two cannot
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
    extract ? "extracted",
    pkgs,
    rows ? null,
  }: ''
    echo "${attr}: regenerating ${dest}"
    extracted=$(${pkgs.nix}/bin/nix build --no-link --print-out-paths \
      ".#${ciAttr {inherit attr pkgs;}}.passthru.${extract}")
    ${pkgs.coreutils}/bin/cp "$extracted" "${dest}"
    ${pkgs.coreutils}/bin/chmod 644 "${dest}"
    ${pkgs.nix}/bin/nix fmt -- "${dest}"
    echo "${attr}: wrote ${dest}"
    ${pkgs.lib.optionalString (rows != null) ''
      ${(import ./extracted {inherit pkgs;}).mkRowsRegen rows}
      echo "${attr}: wrote ${rows.path}"
    ''}
  '';

  # `passthru.regenerateExtracted`: the sidecar regeneration for a package
  # whose update never runs `mkUpdateScript`'s `extraExtract`. Two update
  # paths discover and run it, then commit the `sidecars` it lists:
  #
  #   dev/scripts/update-input.sh   a package owned by a flake input
  #                                 (`passthru.updateFlakeInput`)
  #   dev/scripts/update-pkg.sh     an `update.targets` row bumped by rev or
  #                                 by nix-update (git-absorb, git-revise)
  #
  # Without it the bump PR ships the old sidecar and fails the package's
  # drift check, and a failure holds the bump back on either path.
  #
  # `targets` are `mkExtractRegen` arguments: `attr` is the package name in
  # `ciPackages`, not a check path. `extract` selects its passthru key and
  # defaults to `extracted`; `dest` is the repository path it replaces. Optional
  # `rows = {name; path;}` names the drift check and its rows destination.
  mkRegenerateExtracted = {
    name,
    pkgs,
    targets,
  }:
    (pkgs.writeShellScript "${name}-regenerate-extracted" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${builtins.concatStringsSep "\n" (map (target: mkExtractRegen (target // {inherit pkgs;})) targets)}
    '')
    .overrideAttrs (prev: {
      passthru = (prev.passthru or {}) // {sidecars = map (target: target.dest) targets;};
    });

  # Source repair precedes floor extraction, which precedes vendor hashing.
  # The optional final extractor may compile against the same vendor tree.
  # Individual fixers remain exposed for input-bump repairs; the flat extract
  # script lets the ordering check inspect the actual chain.
  #
  # `fixVendorHash` must keep that exact passthru name: `fix_sidecar_hashes`
  # (dev/scripts/update-common.sh) finds it with `p.fixVendorHash or null`.
  # `fixSrcHash` has no caller (#1570). When a src hash goes stale without a
  # version bump, the failure shows up as a `fixVendorHash` error ("goModules
  # build failed without a '-go-modules' hash mismatch"), not a src error.
  # `extraAfter` runs inside this child script, where `$latest`, `$current`
  # and `$tmp` from `mkUpdateScript` are not exported.
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
    fixVendorHash = mkHashFix {
      inherit attr pkgs pname sourcesFile;
      name = "vendor";
      targets = [hashFixTargets.goVendor];
    };
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
      ${fixVendorHash}
      ${extraAfter}
    '';
  };

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
  # role as the Go vendor fixer in `mkGoUpdateExtract` and the same
  # `extraExtract` wiring, but it
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
    buildCandidate = ''
      tmp=$(${pkgs.coreutils}/bin/mktemp)
      ${pkgs.jq}/bin/jq -n --arg v "$latest" '{version: $v}' > "$tmp"

      ${builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (system: mkUrl: let
          # Braced so the template stays safe when the next character is a
          # valid identifier char (e.g. "..._''${ver}_amd64.deb" would
          # otherwise expand the undefined "$latest_amd64").
          url = mkUrl "\${latest}";
          # A URL containing %20 yields an illegal store name, so
          # nix-prefetch-url needs an explicit --name.
          nameArg =
            if builtins.match ".*%20.*" url != null
            then "--name ${pname}-prefetch"
            else "";
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

  # fetchHuggingFaceModel — a thin wrapper over nixpkgs' fetchFromHuggingFace,
  # exposed as the flake's lib.packaging.fetchHuggingFaceModel. The caller passes
  # `pkgs` in the same attrset, so the fetch is built on THEIR pkgs: their
  # fetchFromHuggingFace, and their allowUnfree / allowUnfreePredicate.
  #
  # nixpkgs does the fetching (fetchgit + git LFS) and owns its arguments:
  # repoId, rev, repoType, domain, sparseCheckout, nonConeMode, hash, meta,
  # passthru and every other fetchgit option pass straight through. This adds
  # only:
  #
  # - `backend` defaults to "lfs". nixpkgs defaults to "xet", which throws
  #   "not implemented yet".
  # - `files`, exact repo paths. They become `nonConeMode = true` plus anchored,
  #   glob-escaped `sparseCheckout` patterns. Pass `sparseCheckout` yourself for
  #   globs such as "/*.json"; the two are mutually exclusive, and a caller's
  #   `sparseCheckout` defaults `nonConeMode` to true as well.
  # - `rev` must be a full commit. `tag` is refused: a tag can be moved, and
  #   the default name and version are derived from the commit.
  # - `license` defaults to unfree ON PURPOSE. nixpkgs has no
  #   `licenses.unknown`, and check-meta treats a derivation with NO
  #   meta.license as free (hasUnfreeLicense requires meta.license to be set).
  #   Weights with no stated licence therefore have to be marked unfree
  #   explicitly: evaluating them then needs allowUnfree (or an
  #   allowUnfreePredicate on `pname`, the lowercased repo name), and
  #   Hydra-style public caches will not build them. That does NOT keep them
  #   out of a cache you push to yourself.
  # - `licenseFile` / `attribution`, for licences that require the notice to
  #   travel with the work (Apache-2.0 section 4(a), for one) when the
  #   repository does not ship it. Either one wraps the fetched tree in a
  #   derivation that symlinks its top-level entries and adds LICENSE /
  #   ATTRIBUTION at the root. With neither, the fetched tree IS the result.
  #   meta (licence included) is on BOTH layers, so the inner fetch, reachable
  #   through passthru.fetched, carries the same licence gate.
  # - `name` defaults to "<lowercased repo>-<short rev>" rather than "source",
  #   with a stable pname/version so lib.getName survives rev bumps and name
  #   overrides.
  # - meta.position points at the caller's `rev` when the caller gives no
  #   meta.description. nixpkgs takes it from meta.description, which the
  #   wrapper would otherwise always set, so it named this file.
  # - The result has no `override`. nixpkgs' makeOverridable version called
  #   fetchFromHuggingFace directly, skipping every default and check above, and
  #   kept the old name after a rev change. `overrideAttrs` stays, on both result
  #   shapes.
  fetchHuggingFaceModel = {
    pkgs,
    repoId,
    rev ? null,
    attribution ? null,
    backend ? "lfs",
    files ? null,
    license ? pkgs.lib.licenses.unfree,
    licenseFile ? null,
    meta ? {},
    name ? null,
    passthru ? {},
    ...
  } @ args: let
    inherit (pkgs) lib;
    pname = lib.toLower (baseNameOf repoId);
    version = builtins.substring 0 7 rev;
    drvName =
      if name == null
      then "${pname}-${version}"
      else name;
    # Only when the description is ours: nixpkgs already points a caller's own
    # meta.description at the caller.
    position = lib.optionalAttrs (!(meta ? description)) {
      pos = builtins.unsafeGetAttrPos "rev" args;
    };
    api = "https://${args.domain or "huggingface.co"}/api/${args.repoType or "model"}s/${repoId}";
    validPath = file:
      lib.isString file
      && !(lib.hasPrefix "/" file)
      && builtins.all (segment: !(builtins.elem segment ["" "." ".."])) (lib.splitString "/" file);
    # Non-cone patterns are gitignore syntax: the leading "/" anchors each path
    # at the repository root, and escaping keeps a literal `*`, `?` or `[` in a
    # file name from acting as a glob. A caller's own sparseCheckout also
    # defaults to non-cone: cone mode reads each entry as a DIRECTORY and always
    # checks out every root file, so "/*.json" would still fetch README.md,
    # .gitattributes and the rest of the root.
    selection =
      if files != null
      then {
        nonConeMode = true;
        sparseCheckout = map (file: "/" + lib.escape ["\\" "*" "?" "["] file) files;
      }
      else lib.optionalAttrs (args ? sparseCheckout) {nonConeMode = args.nonConeMode or true;};
    fetched = pkgs.fetchFromHuggingFace (
      removeAttrs args ["attribution" "files" "license" "licenseFile" "pkgs"]
      // selection
      // {
        inherit backend passthru;
        name = drvName;
        derivationArgs = (args.derivationArgs or {}) // position // {inherit pname version;};
        meta = {description = "${repoId} at ${version} (Hugging Face)";} // meta // {inherit license;};
      }
    );
    notices =
      lib.optional (licenseFile != null) {
        target = "LICENSE";
        source = "${licenseFile}";
      }
      ++ lib.optional (attribution != null) {
        target = "ATTRIBUTION";
        # Through writeText, never interpolated into shell.
        source = pkgs.writeText "${drvName}-attribution" attribution;
      };
  in
    assert lib.assertMsg (!(args ? tag)) "fetchHuggingFaceModel: pass a full commit as `rev`, not `tag`; a tag can be moved.";
    assert lib.assertMsg (lib.isString rev && builtins.match "[0-9a-f]{40}" rev != null) ''
      fetchHuggingFaceModel: rev must be a full 40-hex commit hash, got ${builtins.toJSON rev}.
      Branches and tags are mutable, so they would break the hash. Take the
      commit from the "sha" field of ${api},
      or from the repository's commit history.'';
    assert lib.assertMsg (!(meta ? license)) "fetchHuggingFaceModel: pass the licence as `license`, not `meta.license`.";
    assert lib.assertMsg (files == null || !(args ? sparseCheckout)) "fetchHuggingFaceModel: pass either `files` (exact paths) or `sparseCheckout` (patterns), not both.";
    assert lib.assertMsg (files == null || (lib.isList files && files != [])) "fetchHuggingFaceModel: files must be a non-empty list";
    assert lib.assertMsg (files == null || lib.allUnique (map lib.toLower files)) "fetchHuggingFaceModel: files must be unique, ignoring case (a case-insensitive filesystem would merge them)";
    assert lib.assertMsg (files == null || builtins.all validPath files) "fetchHuggingFaceModel: files must be relative paths with no empty, '.' or '..' segment";
      if notices == []
      then removeAttrs fetched ["override" "overrideDerivation"]
      else
        pkgs.runCommand drvName ({
            inherit pname version;
            inherit (fetched) meta;
            passthru = passthru // {inherit fetched;};
          }
          // position) ''
          mkdir "$out" # bare-commands: ok (runCommand builder PATH)
          # One copy of the weights, not two: each symlink is a store reference
          # that also retains the fetched tree against GC.
          find ${fetched} -mindepth 1 -maxdepth 1 -exec ln -s -t "$out" {} +
          # Refuse to shadow a notice the repository already ships. -iname
          # because a case-insensitive filesystem would merge license/LICENSE.
          notice() {
            if [ -n "$(find "$out" -mindepth 1 -maxdepth 1 -iname "$1")" ]; then
              echo "fetchHuggingFaceModel: the fetched tree already has $1. If the repository ships it, fetch it and drop licenseFile / attribution." >&2
              return 1
            fi
            cp "$2" "$out/$1" # bare-commands: ok (runCommand builder PATH)
          }
          ${lib.concatMapStrings (entry: ''
              notice ${lib.escapeShellArgs [entry.target entry.source]}
            '')
            notices}
        '';
}
