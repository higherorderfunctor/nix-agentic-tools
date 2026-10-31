# cspell:ignore iceman longcat mimo multimodal
# OpenCode Go preset families, their pool hints and their drift from the
# pinned catalog. Every tier is a provisional routing judgment from the
# per-model research; none was measured on the operator's Go workload.
{lib}: let
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  fact = facts.get (facts.load {dir = ../../cliproxyapi/extracted;}).aggregate "opencodeGo";
  inherit ((import ../../cliproxyapi/lib/providers.nix {inherit lib;}).vendors.opencode-go) refuses;
  vendor = "opencode-go";
  # Catalog ids a Go credential may serve; the Claude OAuth credential owns the rest.
  catalog = lib.filter (id: !(refuses id)) (builtins.attrNames fact.models);

  # Shell-style glob as a full-match POSIX regex: `*`, `?` and `[...]`/`[!...]`.
  globRegex = glob:
    (lib.foldl' (state: char:
      if state.class
      then
        state
        // {
          class = char != "]";
          out =
            state.out
            + (
              if char == "!" && lib.hasSuffix "[" state.out
              then "^"
              else char
            );
        }
      else
        state
        // {
          class = char == "[";
          out =
            state.out
            + (
              if char == "*"
              then ".*"
              else if char == "?"
              then "."
              else if builtins.elem char ["." "+" "(" ")" "|" "{" "}" "^" "$" "\\"]
              then "\\${char}"
              else char
            );
        }) {
      class = false;
      out = "";
    } (lib.stringToCharacters glob))
    .out;
  matchesId = family: id: builtins.match (globRegex family.match) id != null;
  matches = family: lib.filter (matchesId family) catalog;

  families = {
    go-beam-free = {
      avoidFor = "sole judging; reasoning across huge documents; time-critical work that depends on free capacity";
      effort = "high for bounded reasoning; max is vendor advice, gains above high unknown";
      match = "beam-free";
      tier = "mid";
      useFor = "bounded rule reasoning; checkable implementation attempts while free capacity lasts";
    };
    go-deepseek-v4-pro = {
      avoidFor = "image input; sole final judge; trusting April preview scores for the served checkpoint";
      effort = "high default, max for named hard reasoning; best setting untested on Go";
      match = "deepseek-v4-pro";
      tier = "strong";
      useFor = "bounded code repair and implementation; repository investigation with independent verification";
    };
    "go-deepseek-v4.1-flash" = {
      avoidFor = "sole correctness judge; hardest autonomous tasks without review";
      effort = "high; low for mechanical tasks; max only after a task-specific check";
      match = "deepseek-v4.1-flash";
      tier = "strong";
      useFor = "bounded implementation; tests drafted against explicit behavior; image-assisted repository tasks";
    };
    go-gemini-4-argon = {
      avoidFor = "routine cheap work; trusting full 1M recall; output over 65K tokens through Go";
      effort = "medium default, high for hard multi-file work, low for extraction";
      match = "gemini-4-argon";
      tier = "strong";
      useFor = "hard terminal and coding tasks; multimodal document analysis; large-context reasoning with checks";
    };
    "go-grok-4.7" = {
      avoidFor = "cheap mechanical work; xhigh by default; relying on full-window recall";
      effort = "high (vendor default); xhigh only for named hard tasks, at high token use";
      match = "grok-4.7";
      tier = "strong";
      useFor = "agentic knowledge work; coding with acceptance checks; an alternate-vendor implementer";
    };
    go-hy3 = {
      avoidFor = "image input; sole judging; hardest architecture or long unattended runs";
      effort = "none, low or high; vendor recommends high for coding";
      match = "hy3";
      tier = "mid";
      useFor = "provisional: bounded code writing and text agent tasks with verification";
    };
    go-hy4-preview = {
      avoidFor = "hardest autonomous terminal work; latency-sensitive tasks; sole judging";
      effort = "none or high; high for coding";
      match = "hy4-preview";
      tier = "mid";
      useFor = "provisional: bounded coding, migrations, tests and web apps with review";
    };
    go-iceman-contributor-free = {
      avoidFor = "long autonomous tool loops; sole judging; inputs that must not be used for training";
      effort = "leave unset; no effort levels advertised";
      match = "iceman-contributor-free";
      tier = "small";
      useFor = "provisional: disposable tool-free experiments and drafts with human checks; maker undisclosed";
    };
    "go-kimi-k2.7-code" = {
      avoidFor = "sole judging; forced tool choice; general writing or analysis without a task check";
      effort = "always thinks; no effort levels";
      match = "kimi-k2.7-code";
      tier = "mid";
      useFor = "repo repairs and terminal implementation with test feedback";
    };
    go-kimi-k3 = {
      avoidFor = "routine extraction; latency-sensitive work; final presentation polish; sole judge";
      effort = "always thinks; max only on Go";
      match = "kimi-k3";
      tier = "strong";
      useFor = "multi-turn coding repairs and implementation; analytical work with verifiable deliverables";
    };
    "go-kimi-k3.1-pro" = {
      avoidFor = "latency-sensitive routine work at max; sole finance or legal auditor; trusting full-window accuracy";
      effort = "max default and the tested hard-task setting; low for bounded latency-sensitive work";
      match = "kimi-k3.1-pro";
      tier = "strong";
      useFor = "difficult terminal coding and tool-driven implementation; source-grounded research with checks";
    };
    "go-longcat-2.0" = {
      avoidFor = "image input; sole judging; unattended long-horizon work";
      effort = "thinking on or off only; no effort levels";
      match = "longcat-2.0";
      tier = "mid";
      useFor = "provisional: bounded coding help with tests and review";
    };
    "go-mimo-v2.6-flash" = {
      avoidFor = "sole final judge; latency-critical work; long unattended tool runs (repetition untested)";
      effort = "thinks by default; on/off switch, no effort levels";
      match = "mimo-v2.6-flash";
      tier = "strong";
      useFor = "low-cost coding and automation with executable acceptance criteria";
    };
    "go-mimo-v2.6-pro" = {
      avoidFor = "latency-sensitive routine work; sole final judgment; trusting the full 1M context";
      effort = "thinks by default; on/off switch, no effort levels";
      match = "mimo-v2.6-pro";
      tier = "strong";
      useFor = "implementation and tool-driven investigation with concrete tests";
    };
    go-minimax-m3 = {
      avoidFor = "sole factual judge; hardest autonomous runs; trusting full 1M recall";
      effort = "thinking on or off only; on for reasoning, off for simple turns";
      match = "minimax-m3";
      tier = "mid";
      useFor = "provisional: bounded coding and tool-assisted implementation; visual code investigation with checks";
    };
    "go-minimax-m3.1-flash" = {
      avoidFor = "latency-sensitive interaction; unchecked numeric claims; hardest unattended runs; sole judging";
      effort = "always adaptive; max is the vendor default and evaluated setting";
      match = "minimax-m3.1-flash";
      tier = "mid";
      useFor = "bounded code writing and background analytics with executable checks";
    };
    # The research groups 1.2 and 1.3: same role, effort ladder and training terms.
    go-muse-spark-contributor = {
      avoidFor = "content that must stay out of training; sole judging; trusting full-window recall";
      effort = "minimal to xhigh, no max; xhigh has independent task evidence";
      match = "muse-spark-1.[23]-contributor";
      tier = "strong";
      useFor = "tool-driven coding and professional deliverables with checks, when training on inputs is acceptable";
    };
    "go-qwen3.7-plus" = {
      avoidFor = "sole diagnostic judgment; latency-sensitive work; million-token reasoning";
      effort = "thinking on for analysis, off for mechanical work; no effort levels";
      match = "qwen3.7-plus";
      tier = "mid";
      useFor = "provisional: bounded tool-assisted analysis";
    };
    "go-qwen3.8-flash" = {
      avoidFor = "sole judging; hard synthesis; final prose polish; long autonomous runs";
      effort = "medium; low or off for mechanical work; xhigh for named hard tasks";
      match = "qwen3.8-flash";
      tier = "mid";
      useFor = "provisional: bounded code, CLI, documentation and tool tasks";
    };
    "go-qwen3.8-max" = {
      avoidFor = "sole judge; unverified autonomous delivery; latency-sensitive tasks";
      effort = "low, medium or xhigh plus a thinking switch; medium for bounded tasks (untested)";
      match = "qwen3.8-max";
      tier = "mid";
      useFor = "provisional: bounded repair candidates with executable validation";
    };
    go-step-5-preview = {
      avoidFor = "hardest proof work; sole judging; long autonomous runs without tests";
      effort = "medium (vendor advice); high for complex code analysis, low for extraction";
      match = "step-5-preview";
      tier = "strong";
      useFor = "provisional: bounded coding and scientific programming; multimodal documents with checks";
    };
  };

  # Monthly limit: the list-price dollars that empty the account's monthly
  # pool, so a lower limit weighs more per dollar. Free models say unlimited.
  poolHint = plan: match: let
    limits = fact.monthlyLimits.${plan};
    ids = matches {inherit match;};
    show = id:
      if limits.${id} == "unlimited"
      then "unlimited"
      else "$" + toString limits.${id};
    shown = lib.unique (map show ids);
  in
    lib.optionalString (ids != []) (
      if shown == ["unlimited"]
      then "${plan}: unlimited"
      else "${plan}: ${
        if lib.length shown == 1
        then lib.head shown
        else lib.concatMapStringsSep ", " (id: "${show id} (${id})") ids
      } of list-price use empties the monthly pool"
    );

  # Catalog ids that a selected preset and any other family selected on the
  # same runtime both match: the skill would show two rows for one id.
  # Family names are unique across vendors, so the shipped names identify the
  # presets, and a custom opencode-go family counts as another family.
  overlaps = selected:
    lib.concatMap (id: let
      matching = lib.filter (family: matchesId family id) selected;
      owners = map (family: "${family.vendor}.${family.name}") matching;
    in
      lib.optional (lib.length owners > 1 && lib.any (family: families ? ${family.name}) matching)
      "${id} (${lib.concatStringsSep ", " owners})")
    catalog;

  # One line under the skill's tables whenever a Go family renders.
  note = "The ${vendor} families come from per-model research: their tiers and effort guidance are provisional, not measured on this workload.";

  # Catalog ids no preset matches, ids several presets match, and presets
  # matching no catalog id.
  drift = let
    owners = id: lib.attrNames (lib.filterAttrs (_: family: matchesId family id) families);
  in
    map (id: "catalog model `${id}` matches no preset") (lib.filter (id: owners id == []) catalog)
    ++ map (id: "catalog model `${id}` matches several presets: ${lib.concatStringsSep ", " (owners id)}") (lib.filter (id: lib.length (owners id) > 1) catalog)
    ++ lib.mapAttrsToList (name: _: "preset `${name}` matches no catalog model") (lib.filterAttrs (_: family: matches family == []) families);
in {
  inherit catalog drift families note overlaps poolHint vendor;
  plans = builtins.attrNames fact.monthlyLimits;
}
