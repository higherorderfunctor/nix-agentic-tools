rec {
  # SINGLE definition of "which file is the kiro chat binary", shared by the
  # read-only extractor (`mkKiroExtract`) and the in-place patcher
  # (`mkKiroRolloutPatch`). Emitted as Python source rather than a helper
  # module so both scripts can interpolate it and there is exactly one
  # locate rule in the tree; a second copy is precisely how the probe and the
  # patch would come to disagree about which file they are talking about.
  #
  # Locating by CONTENT rather than by filename is deliberate and load-bearing.
  # `wrapProgram` renames the real ELF (`kiro-cli-chat` ->
  # `.kiro-cli-chat-wrapped` -> ...`_`) and this repo wraps it a second time, so
  # any hard-coded name is one nixpkgs change away from pointing at nothing.
  # That is not hypothetical: `passthru.extracted` DID hard-code
  # `bin/.kiro-cli-chat-wrapped`, and nixpkgs f13ff45a dissolved the name
  # entirely by splitting the package (see packages/kiro-cli/packages/ai/kiro-cli/package.nix).
  #
  # TWO anchors, and both are required:
  #   * the rollout-manifest key, which only the chat binary carries — measured
  #     2026-08-10 on 2.16.2, where it appears 32 times in the ~556 MB chat ELF
  #     and ZERO times in the launcher or the terminal binary;
  #   * a native-executable magic number, so a small shell wrapper (or any other
  #     file that merely mentions the key) can never be selected in its place.
  #
  # The magic check is what stops "found something" from being mistaken for
  # "found the ELF". Selecting a ~400-byte wrapper would make every read below
  # come up empty and report a vocabulary change that did not happen — the
  # exact misdiagnosis this locator exists to prevent.
  kiroChatLocatorPy = ''
    import mmap
    import os

    KIRO_MANIFEST_MARKER = b'"treatment_percent"'

    # ELF (Linux) plus every Mach-O flavour a darwin .app bundle can carry:
    # thin and fat, 32- and 64-bit, both byte orders.
    KIRO_EXEC_MAGIC = (
        b"\x7fELF",
        b"\xfe\xed\xfa\xce",
        b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xcf\xfa\xed\xfe",
        b"\xca\xfe\xba\xbe",
        b"\xbe\xba\xfe\xca",
        b"\xca\xfe\xba\xbf",
        b"\xbf\xba\xfe\xca",
    )


    def kiro_chat_binaries(root):
        """Every real native executable under `root` carrying the manifest."""
        found = []
        for dirpath, _dirs, filenames in os.walk(root):
            for filename in sorted(filenames):
                path = os.path.join(dirpath, filename)
                # Symlinks are skipped rather than resolved. On darwin nixpkgs
                # installs the real Mach-O under
                # "$out/Applications/Kiro CLI.app/Contents/MacOS/" and leaves
                # "$out/bin/*" as symlinks into it, so following them would
                # report one binary twice and turn a healthy tree into an
                # ambiguity error.
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                if os.path.getsize(path) < 4:
                    continue
                with open(path, "rb") as handle:
                    if not handle.read(4).startswith(KIRO_EXEC_MAGIC):
                        continue
                    # mmap for the same reason the patcher uses it: the target
                    # is a ~556 MB binary and read() would peak that much RSS
                    # on a builder to look for a few hundred bytes. `find`
                    # scans the mapping through the buffer protocol, so nothing
                    # is materialized.
                    with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
                        if mapped.find(KIRO_MANIFEST_MARKER) != -1:
                            found.append(path)
        return found
  '';

  # Shared rollout-entry matcher: extraction and patch refusal use the
  # unmatched-site count returned by rollout_sites. The patcher also checks
  # replacement width and rejects names with no manifest entry.
  # A vendor state can be extracted without being patchable.
  kiroRolloutEntryPy = ''
    import re

    def entry_re(name):
        n = re.escape(name.encode())
        return re.compile(
            rb'"' + n + rb'": \{\n'
            rb'    "description": "[^"]*",\n'
            rb'    "treatment_percent": \d+'
            rb'(?:,\n    "(?:segment|channel)": "[^"]*")*\n'
            rb'  \}'
        )

    # Every `"<name>": {` site must match entry_re. Returns the matches and the
    # count of sites that did not match.
    def rollout_sites(mapped, name):
        key = rb'"' + re.escape(name.encode()) + rb'": \{'
        sites = len(re.findall(key, mapped))
        hits = list(entry_re(name).finditer(mapped))
        return hits, sites - len(hits)

    # The unlocked form the patcher writes. `description` is the padding
    # reservoir, so an entry narrower than the empty-description form cannot
    # hold it.
    def unlocked(name, description=b""):
        return (
            b'"' + name.encode() + b'": {\n'
            b'    "description": "' + description + b'",\n'
            b'    "treatment_percent": 100,\n'
            b'    "segment": "all"\n'
            b'  }'
        )

    def wide_enough(name, hit):
        return hit.end() - hit.start() >= len(unlocked(name))

  '';

  # Resolve the ONE kiro chat binary under a package root, printing its path.
  #
  # Every failure here is phrased as a LOCATION failure and says so explicitly,
  # because the caller's next step reports a content failure and the two used to
  # be indistinguishable: when the hard-coded path vanished under nixpkgs
  # f13ff45a, twelve greps failed with "No such file or directory" and the build
  # announced "upstream changed the hook-trigger vocabulary". A missing binary
  # and a changed binary are different bugs with different fixes; do not let
  # these messages drift back together. (The trigger greps are gone: triggers
  # now come from the engine's own map, `kiroHookTriggersExtractScript`.)
  kiroLocateChatScript = pkgs:
    pkgs.writeText "kiro-locate-chat-binary.py" ''
      ${kiroChatLocatorPy}
      import sys

      root = sys.argv[1]

      if not os.path.isdir(root):
          sys.stderr.write(
              "kiro-locate: cannot locate the kiro chat binary - %r is not a "
              "directory, so nothing was searched. This is a LOCATION failure "
              "(bad root, or the package layout moved); nothing was "
              "extracted.\n" % root
          )
          sys.exit(1)

      matches = kiro_chat_binaries(root)

      if not matches:
          sys.stderr.write(
              "kiro-locate: cannot locate the kiro chat binary - no native "
              "executable under %r carries the rollout manifest. This is a "
              "LOCATION failure, NOT a vocabulary change: nothing was "
              "extracted. Either the root points at a wrapper-only output "
              "(nixpkgs moved the real binaries to a separate derivation - "
              "check `passthru.unwrapped`), or upstream stopped shipping the "
              "manifest in the chat binary.\n" % root
          )
          sys.exit(1)

      if len(matches) > 1:
          # Deliberately fatal. The extract describes ONE binary, and silently
          # picking from several would emit a sidecar whose provenance nobody
          # can name - the failure mode the shape assertions elsewhere in this
          # file exist to prevent.
          sys.stderr.write(
              "kiro-locate: ambiguous - %d native executables under %r carry "
              "the rollout manifest, and the extract must describe exactly "
              "one. This is a LOCATION failure, NOT a vocabulary change: "
              "nothing was extracted.\n%s\n"
              % (len(matches), root, "\n".join("  " + m for m in matches))
          )
          sys.exit(1)

      sys.stdout.write(matches[0])
    '';

  # Reads the rollout manifest the kiro chat binary carries in rodata and emits
  # its feature names, vendor states and patchability as JSON. Genuinely
  # extracted, never curated: the
  # names ARE the enum a consumer may unlock, so a hand-copied list would drift
  # silently the first time upstream adds a flag.
  kiroRolloutExtractScript = pkgs:
    pkgs.writeText "kiro-rollout-extract.py" ''
      ${kiroRolloutEntryPy}
      import json, mmap, sys

      # The anchor bounds the block at both ends: it finds the pretty-printed
      # root's start, and the root's closing brace is the first "\n}" after it
      # (JSON escapes newlines inside strings). The parser decodes the slice.
      manifest = re.compile(rb'\{\n  "[a-z0-9_]+": \{\n    "description":')
      states = None
      with open(sys.argv[1], "rb") as fh:
          with mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ) as mm:
              for region in manifest.finditer(mm):
                  end = mm.find(b"\n}", region.start())
                  if end < 0:
                      sys.exit("kiro-extract: rollout manifest end not found at offset %d" % region.start())
                  end += 2
                  current, _ = json.JSONDecoder().raw_decode(mm[region.start():end].decode())
                  if states is not None and states != current:
                      sys.exit("kiro-extract: conflicting rollout copies")
                  states = current
              if states is None:
                  sys.exit("kiro-extract: no rollout manifest found")
              # Drop the vendor prose so the state readers (needsPatch's closed
              # formals, the option docs that embed each whole state) never
              # carry it; every other field is copied.
              states = {name: {key: value for key, value in entry.items() if key != "description"}
                        for name, entry in states.items()}
              patchability = {}
              for name in sorted(states):
                  hits, unmatched = rollout_sites(mm, name)
                  patchability[name] = {
                      "patchable": unmatched == 0,
                      "unmatchedSites": unmatched,
                  }
      names = sorted(states)

      json.dump({"rolloutFeatures": names, "rolloutPatchability": patchability, "rolloutStates": states}, sys.stdout)
    '';

  # TypeScript locates the TUI's registry, allowlist, and workspace merge.
  # The script validates their shapes, evaluates the two settings expressions,
  # and tests the selected merge against isolated fixtures in a VM. It never
  # executes the full vendor bundle.
  kiroSettingsExtractScript = pkgs:
    pkgs.writeShellScript "kiro-settings-extract" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      exec ${pkgs.nodejs}/bin/node ${../extract/settings.mjs} "$1" ${pkgs.typescript_5}/lib/node_modules/typescript
    '';

  # TypeScript locates the engine's frozen hook-trigger map by content and
  # asserts its shape; emits `hookTriggers` (canonical) and
  # `hookTriggerAliases` (alias -> canonical).
  kiroHookTriggersExtractScript = pkgs:
    pkgs.writeShellScript "kiro-hook-triggers-extract" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      exec ${pkgs.nodejs}/bin/node ${../extract/hook-triggers.mjs} "$1" ${pkgs.typescript_5}/lib/node_modules/typescript
    '';

  # embedded-kas.py's flags for a release whose CPU is `architecture`; shared
  # by `mkKiroExtract` and ./kas.nix.
  kiroEmbeddedArgs = pkgs: architecture: "--architecture ${pkgs.lib.escapeShellArg architecture} --zstd-library ${pkgs.lib.getLib pkgs.zstd}/lib/libzstd${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} --zstd ${pkgs.zstd}/bin/zstd";

  # Every fact one platform's release carries, as one JSON raw written to
  # "$out". Nothing in the release is executed, so the package's update and
  # drift check read every platform's release on one host.
  #   pkgs: this host's nixpkgs set.
  #   release: the fetched release archive, `.tar.gz` or `.dmg`.
  #   architecture: the release's CPU name, as embedded-kas.py takes it.
  mkKiroExtract = {
    pkgs,
    release,
    architecture,
  }: let
    embedded = kiroEmbeddedArgs pkgs architecture;
  in ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    jq="${pkgs.jq}/bin/jq"
    python3="${pkgs.python3}/bin/python3"

    ${pkgs.coreutils}/bin/mkdir release
    ${
      if pkgs.lib.hasSuffix ".dmg" release.name
      then "(cd release && ${pkgs.undmg}/bin/undmg ${release})"
      else "tar -xzf ${release} -C release"
    }

    # LOCATE, by content; its own failures are phrased as location failures.
    kiroChatBin=$("$python3" ${kiroLocateChatScript pkgs} "$PWD/release")

    "$python3" ${../extract/embedded-kas.py} "$kiroChatBin" kas ${embedded}
    hookTriggersJson=$(${kiroHookTriggersExtractScript pkgs} "$PWD/kas/node_modules/@kiro/agent/dist/server/acp-server.js")
    rolloutJson=$("$python3" ${kiroRolloutExtractScript pkgs} "$kiroChatBin")
    # Both settings fields come from the TUI JavaScript the chat binary
    # embeds; it has not been plaintext in the binary since 2.23.0.
    "$python3" ${../extract/embedded-tui.py} "$kiroChatBin" kiro-tui.js --frames ${../extract/embedded-kas.py} ${embedded}
    settingsJson=$(${kiroSettingsExtractScript pkgs} kiro-tui.js)
    # `-S` sorts every object's keys, so every release emits one shape and the
    # field order written here carries no meaning.
    "$jq" -nS --argjson hooks "$hookTriggersJson" \
      --argjson rollout "$rolloutJson" \
      --argjson settings "$settingsJson" \
      '{hookTriggerAliases: $hooks.hookTriggerAliases, hookTriggers: $hooks.hookTriggers, rolloutFeatures: $rollout.rolloutFeatures, rolloutPatchability: $rollout.rolloutPatchability, rolloutStates: $rollout.rolloutStates, settingKeys: $settings.settingKeys, workspaceOverridableSettings: $settings.workspaceOverridableSettings}' > "$out"
  '';

  # Same-LENGTH in-place rewrite of a rollout-manifest entry, flipping it to
  # `treatment_percent: 100` / `segment: "all"` with no `channel` gate.
  #
  # Length preservation is the whole trick, and it is not fussiness: the
  # manifest sits in rodata inside a ~556 MB ELF, so growing it by even one
  # byte would move section offsets and require a relink we cannot do. The
  # `description` field is unused by the gating logic, so it serves as the
  # padding reservoir — shrink or grow it to absorb the delta exactly.
  #
  # Locating the target by CONTENT rather than by filename is deliberate, and
  # the rule now lives ONCE in `kiroChatLocatorPy` — shared with
  # `mkKiroExtract`, which used to hard-code `bin/.kiro-cli-chat-wrapped` and
  # broke exactly as this comment predicted. Both consumers must agree on which
  # file is "the kiro chat binary"; a second copy of the walk is how they would
  # stop agreeing.
  #
  # Fails LOUD on any drift: a feature whose entry is absent, or whose entry
  # count does not equal the number of sites patched, aborts the build. A
  # half-patched binary is worse than an unpatched one, because which of the
  # duplicate manifest copies is consulted is not observable from here.
  mkKiroRolloutPatch = {
    features,
    pkgs,
  }: let
    script = pkgs.writeText "kiro-rollout-patch.py" ''
      ${kiroChatLocatorPy}
      ${kiroRolloutEntryPy}
      import sys

      # De-duplicated, order preserved. The module already calls lib.unique,
      # but this helper is callable on its own, and a repeated feature would
      # otherwise re-patch an already-patched entry (harmless, since the
      # rewrite is idempotent) and double its reported site count (not
      # harmless — that count is the drift signal).
      features = list(dict.fromkeys(f for f in sys.argv[1].split(",") if f))
      root = sys.argv[2]

      # mmap, not read()+bytearray. The target is a ~556 MB ELF, and the
      # read-then-copy shape peaked over 1 GB per file, which is enough to
      # make a small CI builder fail on a patch that changes ~200 bytes. The
      # rewrite is length-preserving, so an in-place mapped edit is exactly
      # the right tool: the kernel pages in only what the regex touches and
      # writes back only the dirtied pages. `re` operates on the mmap
      # directly via the buffer protocol, so nothing is materialized.
      totals = dict((f, 0) for f in features)

      # Located up front, read-only, by the SHARED rule. Two consequences worth
      # keeping: the "which file" question has one answer in this tree, and the
      # write-mode widening below now touches only the files actually being
      # patched instead of every file in the output.
      patched_paths = kiro_chat_binaries(root)

      if not patched_paths:
          sys.stderr.write(
              "kiro-rollout: no file under %s carries a rollout manifest. The "
              "binary layout changed; re-locate it before shipping an unlock.\n"
              % root
          )
          sys.exit(1)

      for path in patched_paths:
          mode = os.stat(path).st_mode
          # ACCESS_WRITE needs the descriptor opened r+b, so the mode is
          # widened first and restored below whether or not we wrote.
          os.chmod(path, mode | 0o200)
          try:
              with open(path, "r+b") as fh:
                  with mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_WRITE) as mm:
                      for name in features:
                          hits, unmatched = rollout_sites(mm, name)
                          if unmatched:
                              sys.stderr.write(
                                  "kiro-rollout: %r has %d site(s) in %s that did "
                                  "not match the expected entry shape. "
                                  "Refusing to half-patch.\n"
                                  % (name, unmatched, path)
                              )
                              sys.exit(1)
                          # Checked for every hit before any is written, so a
                          # short copy cannot leave its siblings patched.
                          for m in hits:
                              if not wide_enough(name, m):
                                  sys.stderr.write(
                                      "kiro-rollout: entry for %r is too short (%d bytes) to hold the "
                                      "unlocked form; upstream shortened the description.\n"
                                      % (name, m.end() - m.start())
                                  )
                                  sys.exit(1)
                          for m in hits:
                              pad = m.end() - m.start() - len(unlocked(name))
                              mm[m.start():m.end()] = unlocked(name, b"P" * pad)
                              totals[name] += 1
                      mm.flush()
          finally:
              os.chmod(path, mode)

      for name in features:
          if totals[name] == 0:
              sys.stderr.write(
                  "kiro-rollout: feature %r has no manifest entry. It was removed "
                  "or renamed upstream.\n" % name
              )
              sys.exit(1)
          sys.stderr.write("kiro-rollout: unlocked %r at %d site(s)\n" % (name, totals[name]))

      # STDOUT is the machine-readable half: one patched path per line, for the
      # caller to re-sign. Diagnostics all go to stderr so they cannot pollute
      # it.
      for p in patched_paths:
          print(p)
    '';
  in ''
    # Walks all of "$out", not "$out/bin". On Darwin nixpkgs installs the real
    # Mach-O into "$out/Applications/Kiro CLI.app/Contents/MacOS/" and leaves
    # "$out/bin/*" as SYMLINKS into it — and the patcher skips symlinks, so a
    # bin-only walk finds nothing there and fails the build. Linux is
    # unaffected: its binaries are real files under bin/.
    kiroRolloutPatched=$(${pkgs.python3}/bin/python3 ${script} \
      ${pkgs.lib.escapeShellArg (pkgs.lib.concatStringsSep "," features)} "$out")
    ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      # Patching a Mach-O invalidates its code signature, and arm64 macOS
      # REFUSES TO EXEC an invalidly-signed binary — SIGKILL at exec, not a
      # warning. So re-sign ad-hoc.
      #
      # This cannot be delegated to `autoSignDarwinBinariesHook`: that registers
      # a fixupOutputHook, which runs during fixupPhase — BEFORE postFixup —
      # so it would sign first and the patch would invalidate it again.
      # Grant write only if it is not already writable, and revoke only what we
      # granted. `chmod +w` / `-w` would have been wrong twice over: the class
      # is umask-dependent when omitted, and the revoke is UNCONDITIONAL, so an
      # already-writable 755 input would come back 555 — a mode change this
      # step has no business making. Restoring an exact saved mode is not an
      # option here: it needs `stat`, whose flags differ between GNU and BSD,
      # and this is the one code path that only ever runs on BSD userland.
      while IFS= read -r kiroRolloutFile; do
        [ -n "$kiroRolloutFile" ] || continue
        echo "kiro-rollout: re-signing $kiroRolloutFile"
        kiroRolloutGranted=0
        if [ ! -w "$kiroRolloutFile" ]; then
          ${pkgs.coreutils}/bin/chmod u+w "$kiroRolloutFile"
          kiroRolloutGranted=1
        fi
        ${pkgs.darwin.sigtool}/bin/codesign --force --sign - "$kiroRolloutFile"
        if [ "$kiroRolloutGranted" = 1 ]; then
          ${pkgs.coreutils}/bin/chmod u-w "$kiroRolloutFile"
        fi
      done <<< "$kiroRolloutPatched"
    ''}
  '';

  # The exec check is deliberately NOT part of the patch above, and the reason
  # is a real trap: `runHook postFixup` evaluates the postFixup ATTRIBUTE first
  # and the registered `postFixupHooks` second — and autoPatchelfHook is one of
  # those hooks. So inside postFixup the ELF still carries its FHS interpreter,
  # `execve` returns ENOENT, and bash reports the thoroughly misleading
  # "cannot execute: required file not found". Measured; it fails every Linux
  # build if you put it there.
  #
  # `postInstallCheck` runs well after all of fixupPhase, so the binary is
  # fully patchelf'd (Linux) and re-signed (Darwin) by the time it runs.
  #
  # What it buys: on Darwin it catches a botched signature, since arm64 macOS
  # SIGKILLs an invalidly-signed binary at exec; on Linux it catches a
  # corrupted ELF. `--version` suffices for both, because a signature failure
  # kills the process before any argument is parsed — and it needs NO
  # credentials, so it runs in the sandbox on any builder.
  #
  # It must target the CHAT binary specifically. nixpkgs' `versionCheckHook`
  # runs `meta.mainProgram`, which is the LAUNCHER, while the manifest lives in
  # the chat binary — so a dead chat binary would otherwise sail through a
  # green build.
  kiroRolloutVerify = ''
    echo "kiro-rollout: verifying the patched chat binary still runs"
    "$out/bin/kiro-cli-chat" --version > /dev/null
  '';
}
