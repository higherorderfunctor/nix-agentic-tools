# Mutants for lib/git-tool-settings/mutate.py over the git-absorb source.
# Each makes one upstream-shaped change and names the outcome the extractor
# must produce: `fails` lists guard codes that must all fire; `adds` /
# `changes` / `deadKeysAdd` describe an output that must move with the
# source; a mutant with none must leave the output identical to the real one.
# What a person must write for a new name is lib/git-tool-settings/rules.nix's
# to demand; checks/git-tool-settings/rules.nix holds those cases.
#
# P* came with the prototype. K* are the independent review's blind spots,
# each of which the prototype passed silently; every one now fails closed
# or extracts the right value. N* are syntax the tree walk reads correctly
# where a text pattern would not, and prose the lead-in rewrite must survive.
let
  config = "src/config.rs";
  lib' = "src/lib.rs";
  adoc = "Documentation/git-absorb.adoc";
  append = file: text: {
    inherit file;
    append = text;
  };
  replace = file: from: to: {inherit file from to;};
  # A man-page subsection documenting `absorb.<key>`: the description P2 extracts.
  documented = key:
    replace adoc "GENERATE SQUASH COMMITS INSTEAD OF FIXUPS\n" ''
      PROBE ${key}
      ~~~~~~${builtins.concatStringsSep "" (builtins.genList (_: "~") (builtins.stringLength key))}

      Probe setting, set

      ....
      [absorb]
          ${key} = true
      ....

      GENERATE SQUASH COMMITS INSTEAD OF FIXUPS
    '';
  squashArm = "        squash: config.squash\n            || bool_value(";
in [
  {
    # The floor catches an empty owned-key set even when all reads have literal keys.
    name = "collapsed-owned-settings";
    edits = [
      (replace config ''"absorb.autoStageIfNothingStaged"'' ''"probe.autoStageIfNothingStaged"'')
      (replace config ''"absorb.createSquashCommits"'' ''"probe.createSquashCommits"'')
      (replace config ''"absorb.fixupTargetAlwaysSHA"'' ''"probe.fixupTargetAlwaysSHA"'')
      (replace config ''"absorb.forceAuthor"'' ''"probe.forceAuthor"'')
      (replace config ''"absorb.forceDetach"'' ''"probe.forceDetach"'')
      (replace config ''"absorb.maxStack"'' ''"probe.maxStack"'')
      (replace config ''"absorb.oneFixupPerCommit"'' ''"probe.oneFixupPerCommit"'')
    ];
    fails = ["F15"];
  }
  # ── Prototype mutants ─────────────────────────────────────────────────
  {
    # A new modeled setting must carry its default and man-page description.
    name = "P2-new-key-through-the-shape";
    edits = [
      (append config ''

        pub const NEW_CONFIG_NAME: &str = "absorb.newThing";
        pub fn new_thing(repo: &git2::Repository) -> bool {
            bool_value(repo, NEW_CONFIG_NAME, true)
        }
      '')
      (documented "newThing")
    ];
    adds = ["absorb.newThing"];
    changes."absorb.newThing" = {
      default = true;
      description = "Probe setting, set `absorb.newThing = true`";
    };
  }
  {
    # An unsupported getter inside the recognized shape must not be silently skipped.
    name = "P4-unknown-read-method";
    edits = [(replace config "config.get_i64(MAX_STACK_CONFIG_NAME)" "config.get_bytes(MAX_STACK_CONFIG_NAME)")];
    fails = ["F2"];
  }
  {
    # Narrowing a supported integer getter must not reject the read or change its kind.
    name = "P5-i64-to-i32-is-carried";
    edits = [(replace config "config.get_i64(MAX_STACK_CONFIG_NAME)" "config.get_i32(MAX_STACK_CONFIG_NAME)")];
    changes."absorb.maxStack".type = "int";
  }
  {
    # Changing the getter must update the type, not retain the old boolean type.
    name = "P6-bool-to-string-is-carried";
    edits = [(replace config "config.get_bool(setting_name)" "config.get_string(setting_name)")];
    changes."absorb.forceAuthor".type = "string";
  }
  {
    # Do not drop a read whose key expression cannot be reduced to a literal.
    name = "P7-computed-key";
    edits = [(replace config "bool_value(repo, FORCE_AUTHOR_CONFIG_NAME, FORCE_AUTHOR_DEFAULT)" ''bool_value(repo, &format!("absorb.{}", "forceAuthor"), FORCE_AUTHOR_DEFAULT)'')];
    fails = ["F1"];
  }
  {
    # An explicit error arm is not a catch-all fallback.
    name = "P8-error-arm-instead-of-default";
    edits = [(replace config "        _ => default_value," ''Err(e) => panic!("{e}"),'')];
    fails = ["F12"];
  }
  {
    # An inclusive bound must not be incremented like an exclusive one.
    name = "P9-guard-change-is-the-minimum";
    edits = [(replace config "if max_stack > 0 =>" "if max_stack >= 5 =>")];
    changes."absorb.maxStack".minimum = 5;
  }
  {
    # Changing the numeric fallback must not leave the old default in the census.
    name = "P10-default-change-is-carried";
    edits = [(replace config "pub const MAX_STACK: usize = 10;" "pub const MAX_STACK: usize = 20;")];
    changes."absorb.maxStack".default = 20;
  }
  {
    # A mixed test predicate must not be silently assumed to be test-only.
    name = "P15-unclassified-test-cfg";
    edits = [
      (append config ''

        #[cfg(all(test, unix))]
        fn t() {}
      '')
    ];
    fails = ["F11"];
  }
  {
    # Conflicting fallbacks for one key must not be reduced to the first or last value.
    name = "P16-one-key-two-defaults";
    edits = [
      (append config ''

        pub fn again(repo: &git2::Repository) -> bool {
            bool_value(repo, FORCE_AUTHOR_CONFIG_NAME, true)
        }
      '')
    ];
    fails = ["F13"];
  }
  {
    # An unbound key parameter must not make a read silently disappear.
    name = "P18-key-parameter-without-caller";
    edits = [
      (append config ''

        fn orphan(repo: &Repository, k: &str) -> bool {
            match repo.config().and_then(|config| config.get_bool(k)) {
                Ok(v) => v,
                _ => false,
            }
        }
      '')
    ];
    fails = ["F10"];
  }

  # ── Review blind spots ─────────────────────────────────────────────
  {
    # A literal key still needs the fallback bound by its caller.
    name = "K1-default-from-a-parameter";
    edits = [
      (append config ''

        fn k1(repo: &Repository, d: bool) -> bool {
            match repo.config().and_then(|c| c.get_bool("absorb.kOne")) {
                Ok(v) => v,
                _ => d,
            }
        }
        pub fn use_k1(repo: &Repository) -> bool { k1(repo, true) }
      '')
    ];
    adds = ["absorb.kOne"];
    changes."absorb.kOne".default = true;
  }
  {
    # A literal fallback must not make the caller-supplied key disappear.
    name = "K2-key-from-a-parameter";
    edits = [
      (append config ''

        fn k2(repo: &Repository, name: &str) -> bool {
            match repo.config().and_then(|c| c.get_bool(name)) {
                Ok(v) => v,
                _ => true,
            }
        }
        pub fn use_k2(repo: &Repository) -> bool { k2(repo, "absorb.kTwo") }
      '')
    ];
    adds = ["absorb.kTwo"];
    changes."absorb.kTwo".default = true;
  }
  {
    # Another file's constant must not shadow the local key.
    name = "K4-same-named-consts-elsewhere";
    edits = [
      (replace lib' "mod commute;\n" ''
        mod commute;
        const FORCE_AUTHOR_CONFIG_NAME: &str = "absorb.forceAuthorX";
      '')
    ];
    # The unread key const must be reported dead, not treated as a setting.
    deadKeysAdd = ["absorb.forceAuthorX"];
  }
  {
    # A modeled Git key must be reported as foreign, not lost or listed as an option.
    name = "K5-foreign-key-through-the-shape";
    edits = [
      (append config ''

        pub fn k5(repo: &Repository) -> bool { bool_value(repo, "rebase.autoSquash", false) }
      '')
    ];
    changes."rebase.autoSquash" = {
      default = false;
      type = "bool";
    };
  }
  {
    # A subprocess config read must fail even when global options come first.
    name = "K6-git-config-after-global-options";
    edits = [
      (append config ''

        pub fn k6(p: &str) { std::process::Command::new("git").args(["-C", p, "config", "--get", FORCE_AUTHOR_CONFIG_NAME]).status().unwrap(); }
      '')
    ];
    fails = ["F7"];
  }
  {
    # Chaining a config getter outside a match must not bypass the raw-read guards.
    name = "K7-unwrap-or-instead-of-match";
    edits = [
      (append config ''

        pub fn k7(repo: &Repository) -> bool {
            repo.config().and_then(|c| c.get_bool("absorb.kSeven")).unwrap_or(false)
        }
      '')
    ];
    fails = ["F6" "F9"];
  }
  {
    # The CLI link is no longer an OR: fail instead of dropping `cli`.
    name = "K8-and-instead-of-or";
    edits = [(replace config squashArm "        squash: config.squash\n            && bool_value(")];
    fails = ["F12"];
  }
  {
    # Inverting the success value must not be reported as a direct config read.
    name = "K11-negated-ok-arm";
    edits = [(replace config "        Ok(value) => value," "        Ok(value) => !value,")];
    fails = ["F12"];
  }
  {
    # An extra upper bound must not be discarded when extracting the minimum.
    name = "K12-compound-guard";
    edits = [(replace config "if max_stack > 0 =>" "if max_stack > 0 && max_stack < 100 =>")];
    fails = ["F12"];
  }

  # ── Syntax and prose a text pattern would misread ─────────────────────
  {
    # A multiline raw string must not hide an otherwise unaccounted-for key.
    name = "N1-key-in-multiline-raw-string";
    edits = [
      (append config ''

        pub fn describe() -> &'static str {
            r#"Set this:
            absorb.hiddenRaw = true"#
        }
      '')
    ];
    fails = ["F9"];
  }
  {
    # `git-absorb.x` is prose, not the key `absorb.x`.
    name = "N2-prose-that-contains-a-key-prefix";
    edits = [
      (append config ''

        pub fn about() -> &'static str { "see the git-absorb.hidden page" }
      '')
    ];
  }
  {
    # The lead-in sentence wraps at a different word: same description.
    name = "N4-lead-in-rewrapped";
    edits = [
      (replace adoc "absorb into the same commit, edit your local or global `.gitconfig` and add\nthe following section:" "absorb into the same commit, edit your local or\nglobal `.gitconfig` and add the following section:")
    ];
  }
  {
    # A default holding `)` and `,` is one literal; a text split breaks it.
    name = "N5-string-default-with-delimiters";
    edits = [
      (append config ''

        pub fn n5(repo: &Repository) -> String {
            match repo.config().and_then(|c| c.get_str("absorb.odd")) {
                Ok(v) => v,
                _ => "a), b(",
            }
        }
      '')
    ];
    adds = ["absorb.odd"];
    changes."absorb.odd" = {
      default = "a), b(";
      type = "string";
    };
  }
]
