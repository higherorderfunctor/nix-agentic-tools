# Real patch paths reject fuzz, backup leakage, lost hooks and Git rejects.
{
  packageLib,
  pkgs,
  ...
}: {
  checks.patch-helper = let
    inherit (pkgs) lib;
    patching = packageLib.patching {inherit pkgs;};
    original = "offset\nheader\na\nb c\nc\nold\nd\ne\nf\n";
    expected = pkgs.writeText "expected" "offset\nheader\na\nb c\nc\nnew\nd\ne\nf\n";
    input = (pkgs.writeTextDir "target" original).overrideAttrs {
      passthru.rev = "fixture-revision";
      meta.description = "fixture metadata";
    };
    patch = strip:
      pkgs.writeText "change-p${toString strip}.patch" ''
        --- ${lib.optionalString (strip == 1) "a/"}target
        +++ ${lib.optionalString (strip == 1) "b/"}target
        @@ -2,7 +2,7 @@
         a
         b c
         c
        -old
        +new
         d
         e
         f
      '';
    compressed = pkgs.runCommand "change.patch.gz" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      gzip -c ${patch 1} > "$out"
    '';
    options = strip: {
      patchFiles = [
        (
          if strip == 1
          then compressed
          else patch strip
        )
      ];
      inherit strip;
      prePatch = "printf 'pre ' > hooks";
      postPatch = "printf post >> hooks";
    };
    sources = map (strip: patching.source ((options strip) // {src = input;})) [0 1];
    derivations = map (strip:
      pkgs.stdenvNoCC.mkDerivation (patching.attrs ((options strip)
        // {
          name = "patch-phase-p${toString strip}";
          src = input;
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            cp -R . "$out"
          '';
        }))) [0 1];
    # Isolated subprocesses run the actual stdenv patchPhase for refusals.
    phase = extra:
      pkgs.writeShellScript "patch-phase" ''
        source ${pkgs.stdenvNoCC}/setup
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${lib.toShellVars (patching.attrs ({patchFiles = [(patch 1)];} // extra))}
        patchPhase
      '';
    finish = pkgs.writeShellScript "patch-output" ''
      source ${pkgs.stdenvNoCC}/setup
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${(patching.attrs {postFixup = "printf fixed >> \"$out/hooks\"";}).postFixup}
    '';
    manual = backend: strip:
      patching.command {
        inherit backend strip;
        patchFiles = [(patch strip)];
      };
    rejectsOverride = builtins.tryEval (builtins.deepSeq (patching.attrs {patchFlags = ["--fuzz=2"];}) true);
  in
    assert !rejectsOverride.success;
    assert builtins.all (src: src.rev == "fixture-revision" && src.meta.description == "fixture metadata") sources;
      pkgs.runCommand "patch-helper" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir "$out"
        for tree in ${lib.escapeShellArgs (sources ++ derivations)}; do
          cmp ${expected} "$tree/target"
          test "$(cat "$tree/hooks")" = "pre post"
          ${patching.validate ''"$tree"''}
        done
        # The historical flags reproduce offset backups on the identical input.
        mkdir baseline
        cp ${input}/target baseline/target
        (cd baseline; patch -p1 --fuzz=0 < ${patch 1})
        test -f baseline/target.orig
        cmp ${input}/target baseline/target.orig
        cmp ${expected} baseline/target
        printf 'baseline: offset created target.orig\n' > "$out/results"

        fresh() {
          mkdir "$1"
          cp ${input}/target "$1/target"
        }
        expect_failure() {
          if "$@" > failure.log 2>&1; then
            cat failure.log >&2
            echo 'expected refusal' >&2
            exit 1
          fi
        }
        ${lib.concatMapStringsSep "\n" (backend:
          lib.concatMapStringsSep "\n" (strip: let
            name = "${backend}-p${toString strip}";
            script = pkgs.writeShellScript name (manual backend strip);
          in ''
            fresh ${name}
            (cd ${name}; ${script})
            cmp ${expected} ${name}/target
            fresh ${name}-drift
            sed -i 's/^a$/changed/' ${name}-drift/target
            (cd ${name}-drift; expect_failure ${script})
            ${lib.optionalString (backend == "git") (patching.validate "${name}-drift")}
            for suffix in orig rej; do
              fresh ${name}-$suffix
              touch ${name}-$suffix/existing.$suffix
              (cd ${name}-$suffix; expect_failure ${script}; grep -F 'contamination' failure.log)
              cmp ${input}/target ${name}-$suffix/target
            done
          '') [0 1]) ["git" "gnu"]}

        fresh baseline-drift
        sed -i 's/^a$/changed/' baseline-drift/target
        (cd baseline-drift; patch -p1 < ${patch 1})
        printf 'offset\nheader\nchanged\nb c\nc\nnew\nd\ne\nf\n' > drift-expected
        cmp drift-expected baseline-drift/target
        fresh phase-drift
        sed -i 's/^a$/changed/' phase-drift/target
        (cd phase-drift; expect_failure ${phase {}}; grep -F 'FAILED' failure.log)
        for suffix in orig rej; do
          fresh phase-$suffix
          touch phase-$suffix/existing.$suffix
          (cd phase-$suffix; expect_failure ${phase {}}; grep -F 'contamination' failure.log)
          cmp ${input}/target phase-$suffix/target
        done
        fresh final-output
        out="$PWD/final-output" ${finish}
        test "$(cat final-output/hooks)" = fixed
        for suffix in orig rej; do
          fresh final-$suffix
          touch final-$suffix/existing.$suffix
          out="$PWD/final-$suffix" expect_failure ${finish}
          grep -F 'contamination' failure.log
        done
        fresh post-hook
        (cd post-hook; expect_failure ${phase {postPatch = "touch introduced.orig";}}; grep -F 'introduced.orig' failure.log)
        # CodeQL retains whitespace tolerance, still requiring all context.
        fresh git-whitespace
        sed -i 's/^b c$/b  c/' git-whitespace/target
        (cd git-whitespace; ${patching.command {
          backend = "git";
          ignoreSpaceChange = true;
          patchFiles = [(patch 1)];
        }})
        printf 'offset\nheader\na\nb  c\nc\nnew\nd\ne\nf\n' > whitespace-expected
        cmp whitespace-expected git-whitespace/target
        printf '%s\n' 'PASS: stdenv, applyPatches, GNU, Git; p0/p1; compressed patch; hooks; metadata; drift and contamination refusals' >> "$out/results"
        cat "$out/results"
      '';
}
