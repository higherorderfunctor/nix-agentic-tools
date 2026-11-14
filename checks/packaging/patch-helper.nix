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
    options = strip: {
      patchFiles = [(patch strip)];
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
    dependencyMap = pkgs.writeText "patched-dependencies.json" (builtins.toJSON {
      "@other/plain" = "plain.patch";
      "@scope/patched@1.0.0" = "scoped.patch";
    });
    dependencyCheck = layout: directory:
      pkgs.writeShellScript "check-patched-dependencies" (patching.validateDependencies {
        inherit directory layout;
        patchedDependencies = lib.escapeShellArg dependencyMap;
      });
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

        # Match every direct peer by manifest, including name-only keys. A
        # dependent's patch hash and an unrelated registry backup are not ours.
        for peer in first second; do
          for spec in '@scope/patched 1.0.0 @scope+patched@1.0.0' '@other/plain 2.0.0 @other+plain@2.0.0'; do
            read -r name version encoded <<< "$spec"
            root="dependencies/$encoded$peer/node_modules/$name"
            mkdir -p "$root"
            printf '{"name":"%s","version":"%s"}' "$name" "$version" > "$root/package.json"
          done
        done
        for spec in 'unrelated 1.0.0 unrelated@1.0.0_patch_hash' '@scope/patched 9.0.0 @scope+patched@9.0.0'; do
          read -r name version encoded <<< "$spec"
          root="dependencies/$encoded/node_modules/$name"
          mkdir -p "$root"
          printf '{"name":"%s","version":"%s"}' "$name" "$version" > "$root/package.json"
          touch "$root/upstream.orig"
        done
        ${dependencyCheck "pnpm" "dependencies"}
        for peer in first second; do
          for spec in '@scope/patched @scope+patched@1.0.0' '@other/plain @other+plain@2.0.0'; do
            read -r name encoded <<< "$spec"
            root="dependencies/$encoded$peer/node_modules/$name"
            for suffix in orig rej; do
              touch "$root/leaked.$suffix"
              expect_failure ${dependencyCheck "pnpm" "dependencies"}
              grep -F "$root/leaked.$suffix" failure.log
              rm "$root/leaked.$suffix"
            done
          done
        done
        # Packed runtime roots have dependency symlinks; only the mapped
        # package's own bytes are patch output, not its unrelated dependencies.
        mkdir -p runtime/patched/node_modules runtime/unrelated
        printf '{"name":"@other/plain","version":"2.0.0"}' > runtime/patched/package.json
        printf '{"name":"unrelated","version":"1.0.0"}' > runtime/unrelated/package.json
        touch runtime/unrelated/upstream.orig
        ln -s ../../unrelated runtime/patched/node_modules/unrelated
        ${dependencyCheck "runtime" "runtime"}
        for suffix in orig rej; do
          touch runtime/patched/leaked.$suffix
          expect_failure ${dependencyCheck "runtime" "runtime"}
          grep -F "runtime/patched/leaked.$suffix" failure.log
          rm runtime/patched/leaked.$suffix
        done
        printf 'PASS: dependency map selects all peers; unrelated artifacts survive; every matched peer rejects orig/rej\n' >> "$out/results"

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
        printf '%s\n' 'PASS: stdenv, applyPatches, GNU, Git; p0/p1; hooks; metadata; drift and contamination refusals' >> "$out/results"
        cat "$out/results"
      '';
}
