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
  # "found the ELF". Selecting a ~400-byte wrapper would make every trigger
  # probe below come up empty and report a vocabulary change that did not
  # happen — the exact misdiagnosis this locator exists to prevent.
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

  # Resolve the ONE kiro chat binary under a package root, printing its path.
  #
  # Every failure here is phrased as a LOCATION failure and says so explicitly,
  # because the caller's next step reports a content failure and the two used to
  # be indistinguishable: when the hard-coded path vanished under nixpkgs
  # f13ff45a, twelve greps failed with "No such file or directory" and the build
  # announced "upstream changed the hook-trigger vocabulary". A missing binary
  # and a changed binary are different bugs with different fixes; do not let
  # these messages drift back together.
  kiroLocateChatScript = pkgs:
    pkgs.writeText "kiro-locate-chat-binary.py" ''
      ${kiroChatLocatorPy}
      import sys

      root = sys.argv[1]

      if not os.path.isdir(root):
          sys.stderr.write(
              "kiro-locate: cannot locate the kiro chat binary - %r is not a "
              "directory, so nothing was searched. This is a LOCATION failure "
              "(bad root, or the package layout moved); the hook-trigger "
              "vocabulary was never probed.\n" % root
          )
          sys.exit(1)

      matches = kiro_chat_binaries(root)

      if not matches:
          sys.stderr.write(
              "kiro-locate: cannot locate the kiro chat binary - no native "
              "executable under %r carries the rollout manifest. This is a "
              "LOCATION failure, NOT a hook-trigger vocabulary change: nothing "
              "was probed. Either the root points at a wrapper-only output "
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
              "one. This is a LOCATION failure, NOT a hook-trigger vocabulary "
              "change: nothing was probed.\n%s\n"
              % (len(matches), root, "\n".join("  " + m for m in matches))
          )
          sys.exit(1)

      sys.stdout.write(matches[0])
    '';

  # Kiro hook triggers — the northbound soft-enum `knownTriggers`. Unlike Claude,
  # Kiro has NO clean extract-all anchor: its PascalCase trigger names are polluted
  # by the camelCase `ChatTriggerType` telemetry enum + unrelated tokens, so a
  # mkClaudeExtract-style array grep would capture red herrings. Instead PROBE a
  # baked candidate universe (the union of documented v2+v3 triggers) for binary
  # presence — present -> `hookTriggers`, absent -> `documentedAbsent`
  # (doc-ahead-of-binary). Fail loud if NONE present (anchor gone = binary
  # hook-trigger shape change), mirroring mkClaudeExtract's guards. A brand-new
  # trigger absent from the candidate universe is invisible here — the impure
  # docs-diff (deferred) covers that; grow `candidates` from the docs on a new one.
  #   root: store path of the derivation that CARRIES the kiro binaries — its
  #         `$out`, never a path inside `bin/`. The chat binary is resolved
  #         under it by CONTENT, inside the builder, by `kiroLocateChatScript`;
  #         nothing about the wrapper naming is assumed. Pass the UNWRAPPED
  #         derivation where nixpkgs splits one out, since a wrapper-only output
  #         carries no binary to probe.
  #   pkgs: nixpkgs set (gnugrep, coreutils, jq, python3 — python3 drives both
  #         the content-based locate and the rollout-manifest extraction, the
  #         latter not being expressible as a line-oriented grep because the
  #         entries span newlines).
  #   dest: output path (default "/dev/stdout"; pass "$out" in runCommand).
  # Reads the rollout manifest the kiro chat binary carries in rodata and emits
  # its feature NAMES as a JSON array. Genuinely extracted, never curated: the
  # names ARE the enum a consumer may unlock, so a hand-copied list would drift
  # silently the first time upstream adds a flag.
  #
  # The shape assertion is the load-bearing half. A dead anchor still matches
  # SOMETHING — that is exactly how the claude model-catalog grep rotted (see
  # overlays.md § IFD Patterns) — so this demands the two entries stable across
  # the 2.x line AND a floor on the entry count, rather than merely checking
  # that the result is non-empty.
  kiroRolloutExtractScript = pkgs:
    pkgs.writeText "kiro-rollout-extract.py" ''
      import json, mmap, re, sys

      # mmap for the same reason the patcher uses it: the input is a ~556 MB
      # ELF and read() would peak that much RSS on a builder to scan for a few
      # hundred bytes of manifest. `re` scans the mapping through the buffer
      # protocol, so nothing is materialized.
      ent = re.compile(
          rb'\n  "([a-z0-9_]+)": \{\n    "description": "[^"]*",\n'
          rb'    "treatment_percent": \d+'
      )
      with open(sys.argv[1], "rb") as fh:
          with mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ) as mm:
              names = sorted({m.decode() for m in ent.findall(mm)})

      required = {"tangent", "workflows"}
      missing = sorted(required - set(names))
      if missing or len(names) < 6:
          sys.stderr.write(
              "kiro-extract: rollout manifest shape changed - found %d entries, "
              "missing %s. Re-derive the regex against the binary before "
              "trusting any unlock.\n" % (len(names), missing)
          )
          sys.exit(1)

      json.dump(names, sys.stdout)
    '';

  # Kiro workspace-settings allowlist — which `cli.json` keys a PROJECT-LOCAL
  # `.kiro/settings/cli.json` may actually override.
  #
  # Kiro's TUI resolves settings as "global, then workspace on top, but only for
  # keys on an allowlist":
  #
  #   function vr(){ let e = dA();            // global ~/.kiro/settings/cli.json
  #     try { let n = Qq(Eq());               // workspace .kiro/settings/cli.json
  #       for (let [t,a] of Object.entries(n))
  #         if (Cq.has(t)) e[t] = a           // <- the allowlist
  #     } catch(n){ ee.warn("[cli-settings] failed to read workspace cli.json:", n) }
  #     return e }
  #
  # A key OUTSIDE `Cq` written to a workspace file is read, filtered out, and
  # dropped with no warning — which is why the devenv backend needs this list to
  # refuse such a key at eval instead of emitting a file Kiro will ignore.
  #
  # Extracted, never curated, for the same reason `rolloutFeatures` is: the set
  # IS the contract, and a hand-copied copy drifts silently the first time
  # upstream adds a key.
  #
  # ANCHORED ON CONTENT, NOT ON HANDLES. `Cq` and `pn` above are esbuild
  # collision suffixes, not stable names (see the kiro primitives corpus), so
  # this keys off a member the set has carried since the mechanism shipped
  # (`"chat.enableTangentMode"`) and resolves symbolic members through the
  # SCREAMING -> "dotted.key" registry the same bundle carries.
  #
  # AN EMPTY RESULT IS A REAL ANSWER, not a failure, and the difference is why
  # this does not simply assert non-empty like the rollout extractor does. The
  # workspace merge is NEW in 2.21.1: measured across the store, 2.18.1, 2.19.0,
  # 2.20.2 and 2.21.0 have no such set and no `[cli-settings]` workspace warning
  # at all, so on those the honest answer is "this kiro honors NO workspace
  # override" — and wedging the update pipeline on an upstream revert of a
  # release-old mechanism would be a merge-blocking liability, not a signal.
  #
  # What IS fatal is anything that means the probe cannot answer:
  #   * the settings-key registry missing entirely (the JS payload is not what
  #     we think it is, so "no allowlist" would be a guess, not a finding);
  #   * more than one candidate set (ambiguous; the extract describes one);
  #   * a member that resolves to nothing or to two different keys (a PARTIAL
  #     allowlist is worse than none — it would reject valid keys).
  kiroSettingsExtractScript = pkgs:
    pkgs.writeText "kiro-settings-extract.py" ''
      import json, mmap, re, sys

      # `[^\]]` bounds the body at the first `]`, so the match cannot run away
      # across the whole binary. The cost is that a `]` anywhere inside the set
      # TRUNCATES it, and truncation has two outcomes, both handled below and
      # neither by the resolution assertions:
      #
      #   * the `]` is not followed by `)`, so nothing matches at all - caught
      #     by the merge-marker guard, which knows the set must exist;
      #   * the `]` IS followed by `)` (a member like `g(z[0])`), so the match
      #     succeeds on a PREFIX. Measured: a 24-member set truncated that way
      #     yields 12 keys, resolves cleanly, clears the size floor and exits 0
      #     - a short allowlist that looks entirely plausible and would make the
      #     module reject the 12 keys it lost. The BRACKET CHECK below is what
      #     catches that: a flat set of strings and `pn.KEY` references contains
      #     no `[` at all, so one in the captured body proves truncation.
      SET_RE = re.compile(rb'new Set\(\[([^\]]{20,4000})\]\)')
      PAIR_RE = re.compile(rb'([A-Z][A-Z0-9_]{2,}):"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+)"')
      MEMBER_RE = re.compile(rb'"([^"]+)"|[A-Za-z_$][A-Za-z0-9_$]*\.([A-Z][A-Z0-9_]+)')
      PROBE = b'"chat.enableTangentMode"'
      CONTROL = "CHAT_DEFAULT_MODEL"
      # Present iff the workspace-merge code itself is present: it is the warn
      # branch of the very function that consults the allowlist. This is what
      # tells an EMPTY capture ("upstream has no workspace merge") apart from a
      # FAILED one ("it does, and we could not read its set") - without it,
      # under-capture emits [] and the module then rejects every key, which is
      # the worst possible direction for this list to be wrong in.
      MERGE_MARKER = b"[cli-settings] failed to read workspace cli.json"


      def die(msg):
          sys.stderr.write("kiro-extract: " + msg + "\n")
          sys.exit(1)


      # mmap for the same reason the rollout extractor and the patcher use it:
      # the input is a ~800 MB binary and read() would peak that much RSS on a
      # builder to scan for a few hundred bytes.
      with open(sys.argv[1], "rb") as fh:
          with mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ) as mm:
              symbols = {}
              for m in PAIR_RE.finditer(mm):
                  symbols.setdefault(m.group(1).decode(), set()).add(m.group(2).decode())
              if CONTROL not in symbols:
                  die(
                      "the embedded settings-key registry is unrecognizable - no "
                      "%s entry among %d SCREAMING:\"dotted.key\" pairs. This is an "
                      "ANCHOR failure, not a finding: nothing can be concluded "
                      "about which settings a workspace cli.json may override."
                      % (CONTROL, len(symbols))
                  )
              bodies = [m.group(1) for m in SET_RE.finditer(mm) if PROBE in m.group(1)]
              merges_workspace = mm.find(MERGE_MARKER) != -1

      if len(bodies) > 1:
          die(
              "ambiguous - %d candidate workspace-override sets carry %s, and the "
              "extract must describe exactly one."
              % (len(bodies), PROBE.decode())
          )

      if not bodies and merges_workspace:
          die(
              "this kiro DOES merge a workspace cli.json - it carries the "
              "%r warning - but no allowlist set carrying %s could be read. "
              "Emitting an empty list here would make the module reject every "
              "workspace setting, so this fails instead. The set literal has "
              "most likely outgrown the body bound or gained a nested member; "
              "re-derive SET_RE against the binary."
              % (MERGE_MARKER.decode(), PROBE.decode())
          )

      for body in bodies:
          if b"[" in body:
              die(
                  "the workspace-override set was TRUNCATED - its captured body "
                  "contains a '[', which a flat set of keys never does, so a "
                  "nested member ended the match early and the keys after it "
                  "were lost. A short allowlist is worse than none here: the "
                  "module would reject the keys that fell off. Re-derive SET_RE "
                  "against the binary."
              )

      keys, unresolved, ambiguous = set(), [], []
      for body in bodies:
          for m in MEMBER_RE.finditer(body):
              if m.group(1):
                  keys.add(m.group(1).decode())
                  continue
              sym = m.group(2).decode()
              vals = symbols.get(sym)
              if not vals:
                  unresolved.append(sym)
              elif len(vals) > 1:
                  ambiguous.append("%s -> %s" % (sym, sorted(vals)))
              else:
                  keys.add(next(iter(vals)))

      # The two emitted lists fail in OPPOSITE directions and therefore need
      # opposite guards. For the allowlist, which is used to REJECT, the danger
      # is under-capture. For `settingKeys`, which is used to STOP A WALK, the
      # danger is OVER-capture: a spurious key makes the flattener halt early
      # and emit nested JSON kiro cannot read. The guards below all constrain
      # the allowlist, so this one constrains the registry — every symbol must
      # name exactly one key, not merely every symbol the allowlist references.
      registry_ambiguous = sorted(
          "%s -> %s" % (k, sorted(v)) for k, v in symbols.items() if len(v) > 1
      )
      if registry_ambiguous:
          die(
              "the settings-key registry maps symbols to more than one key (%s), "
              "so the regex is over-matching and `settingKeys` would carry an "
              "invented boundary." % registry_ambiguous
          )

      if unresolved:
          die(
              "the workspace-override set references key symbols with no registry "
              "entry (%s); a PARTIAL allowlist is worse than none, because it "
              "would reject settings kiro actually honors."
              % sorted(set(unresolved))
          )
      if ambiguous:
          die(
              "the workspace-override set references key symbols that resolve two "
              "ways (%s), so the registry regex is over-matching." % sorted(set(ambiguous))
          )
      # A sanity floor, NOT the control against under-capture - the bracket check
      # above is that. A floor tight enough to catch truncation on its own would
      # have to sit just under the current count and would then fire the first
      # time upstream legitimately retired a key.
      if bodies and len(keys) < 10:
          die(
              "the workspace-override set matched but yielded only %d keys; its "
              "member shape changed." % len(keys)
          )

      # `settingKeys` is every key the bundle's own registry names, and it is
      # emitted for a different consumer than the allowlist: it is the FLATTEN
      # BOUNDARY. Kiro's cli.json is flat dotted keys whose VALUES may be
      # objects, and nothing in the shape of a Nix attrset says where the key
      # stops and the value begins. `chat.modelDefaults` is a key whose value is
      # an object of per-model records; without this list the module flattens
      # straight through it and writes `chat.modelDefaults.<model>.<field>`,
      # which kiro does not match. Knowing the key lets the flattener stop
      # there.
      #
      # Registry-only, deliberately NOT merged with the allowlist here. The
      # sidecar reports what each probe measured; combining two measurements
      # into one field is a policy decision and belongs at the consumer, where
      # it can be read.
      json.dump(
          {
              "settingKeys": sorted({v for vals in symbols.values() for v in vals}),
              "workspaceOverridableSettings": sorted(keys),
          },
          sys.stdout,
      )
    '';

  mkKiroExtract = {
    pkgs,
    root,
    dest ? "/dev/stdout",
  }: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    grep="${pkgs.gnugrep}/bin/grep"
    jq="${pkgs.jq}/bin/jq"
    sort="${pkgs.coreutils}/bin/sort"
    python3="${pkgs.python3}/bin/python3"

    # STEP 1 — LOCATE. Resolved by content in the builder, so eval does no
    # filesystem guessing and the IFD profile is unchanged. Its own failures are
    # phrased as location failures and are not reachable from step 2's message.
    kiroChatBin=$("$python3" ${kiroLocateChatScript pkgs} "${root}")

    # Belt and braces, and NOT redundant: it fires before the probe loop, so a
    # path that is somehow unreadable is reported as such instead of turning
    # every grep below into a false "trigger absent" verdict.
    if [ ! -f "$kiroChatBin" ] || [ ! -r "$kiroChatBin" ]; then
      echo "kiro-extract: located chat binary '$kiroChatBin' is missing or unreadable; nothing was probed (LOCATION failure, not a vocabulary change)" >&2
      exit 1
    fi

    # STEP 2 — PROBE. Documented v2+v3 trigger universe: Jun-5 docs (5) + v3
    # docs (11) + the v2 `AgentSpawn` name (v3 maps it -> SessionStart).
    # Alphabetical; grow from docs.
    candidates=(AgentSpawn Manual PostFileCreate PostFileDelete PostFileSave PostTaskExec PostToolUse PreTaskExec PreToolUse SessionStart Stop UserPromptSubmit)

    present=()
    absent=()
    for t in "''${candidates[@]}"; do
      # Status is captured and CLASSIFIED rather than swallowed. grep exits 1
      # for "no match" — the documented-absent case this loop is built around —
      # and 2 for "could not read the file". The old `|| true` collapsed the two
      # into "absent", so twelve unreadable-file errors presented as an empty
      # trigger vocabulary. Tolerate 1; never tolerate 2.
      kiroGrepStatus=0
      "$grep" -qaF -e "$t" "$kiroChatBin" || kiroGrepStatus=$?
      case "$kiroGrepStatus" in
        0) present+=("$t") ;;
        1) absent+=("$t") ;;
        *)
          echo "kiro-extract: grep exited $kiroGrepStatus reading '$kiroChatBin' while probing trigger '$t' — the binary could not be read, so no conclusion about the trigger vocabulary is possible" >&2
          exit 1
          ;;
      esac
    done
    if [ "''${#present[@]}" -lt 1 ]; then
      echo "kiro-extract: no documented trigger present in '$kiroChatBin' (the binary was read successfully, so upstream changed the hook-trigger vocabulary)" >&2
      exit 1
    fi

    hookTriggersJson=$(printf '%s\n' "''${present[@]}" | "$sort" -u | "$jq" -R . | "$jq" -s .)
    if [ "''${#absent[@]}" -gt 0 ]; then
      documentedAbsentJson=$(printf '%s\n' "''${absent[@]}" | "$sort" -u | "$jq" -R . | "$jq" -s .)
    else
      documentedAbsentJson='[]'
    fi
    rolloutFeaturesJson=$("$python3" ${kiroRolloutExtractScript pkgs} "$kiroChatBin")
    # Appended rather than slotted in alphabetically: the field order here is
    # the sidecar's on-disk order, and reordering it would churn the committed
    # JSON for every reader without telling anyone anything.
    # ONE scan for both settings fields: they share the key registry, and a
    # second pass over a ~800 MB binary to re-derive the same regex would be
    # both slower and a second place for that regex to drift.
    settingsJson=$("$python3" ${kiroSettingsExtractScript pkgs} "$kiroChatBin")
    # Model availability is server-side and account-dependent. Suggestions come
    # from the public documentation snapshot, refreshed independently of releases.
    modelsJson=$("$python3" ${../extract/models.py} ids ${../model-catalog.json})

    "$jq" -n --argjson hookTriggers "$hookTriggersJson" --argjson documentedAbsent "$documentedAbsentJson" \
      --argjson models "$modelsJson" \
      --argjson rolloutFeatures "$rolloutFeaturesJson" \
      --argjson settings "$settingsJson" \
      '{hookTriggers: $hookTriggers, documentedAbsent: $documentedAbsent, models: $models, rolloutFeatures: $rolloutFeatures, settingKeys: $settings.settingKeys, workspaceOverridableSettings: $settings.workspaceOverridableSettings}' > "${dest}"
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
      import re
      import sys

      # De-duplicated, order preserved. The module already calls lib.unique,
      # but this helper is callable on its own, and a repeated feature would
      # otherwise re-patch an already-patched entry (harmless, since the
      # rewrite is idempotent) and double its reported site count (not
      # harmless — that count is the drift signal).
      features = list(dict.fromkeys(f for f in sys.argv[1].split(",") if f))
      root = sys.argv[2]

      def entry_re(name):
          n = re.escape(name.encode())
          return re.compile(
              rb'"' + n + rb'": \{\n'
              rb'    "description": "[^"]*",\n'
              rb'    "treatment_percent": \d+'
              rb'(?:,\n    "(?:segment|channel)": "[^"]*")*\n'
              rb'  \}'
          )

      def replacement(name, width):
          core = (
              b'"' + name.encode() + b'": {\n'
              b'    "description": "%s",\n'
              b'    "treatment_percent": 100,\n'
              b'    "segment": "all"\n'
              b'  }'
          )
          pad = width - len(core % b"")
          if pad < 0:
              sys.stderr.write(
                  "kiro-rollout: entry for %r is too short (%d bytes) to hold the "
                  "unlocked form; upstream shortened the description.\n"
                  % (name, width)
              )
              sys.exit(1)
          return core % (b"P" * pad)

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
                          key = rb'"' + re.escape(name.encode()) + rb'": \{'
                          sites = len(re.findall(key, mm))
                          hits = list(entry_re(name).finditer(mm))
                          if len(hits) != sites:
                              sys.stderr.write(
                                  "kiro-rollout: %r appears %d time(s) in %s but "
                                  "only %d matched the expected entry shape. "
                                  "Refusing to half-patch.\n"
                                  % (name, sites, path, len(hits))
                              )
                              sys.exit(1)
                          for m in hits:
                              mm[m.start():m.end()] = replacement(
                                  name, m.end() - m.start()
                              )
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
