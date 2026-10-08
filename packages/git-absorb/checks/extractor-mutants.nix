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
  {name = "P1-control";}
  {
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
      type = "bool";
    };
  }
  {
    name = "P3-raw-handle-outside-the-shape";
    edits = [
      (append config ''

        pub fn sneaky(repo: &git2::Repository) -> String {
            let c = repo.config().unwrap();
            c.get_string("absorb.sneaky").unwrap()
        }
      '')
    ];
    fails = ["F6" "F9"];
  }
  {
    name = "P4-unknown-read-method";
    edits = [(replace config "config.get_i64(MAX_STACK_CONFIG_NAME)" "config.get_bytes(MAX_STACK_CONFIG_NAME)")];
    fails = ["F2"];
  }
  {
    name = "P5-i64-to-i32-is-carried";
    edits = [(replace config "config.get_i64(MAX_STACK_CONFIG_NAME)" "config.get_i32(MAX_STACK_CONFIG_NAME)")];
    changes."absorb.maxStack".type = "int";
  }
  {
    name = "P6-bool-to-string-is-carried";
    edits = [(replace config "config.get_bool(setting_name)" "config.get_string(setting_name)")];
    changes."absorb.forceAuthor".type = "string";
  }
  {
    name = "P7-computed-key";
    edits = [(replace config "bool_value(repo, FORCE_AUTHOR_CONFIG_NAME, FORCE_AUTHOR_DEFAULT)" ''bool_value(repo, &format!("absorb.{}", "forceAuthor"), FORCE_AUTHOR_DEFAULT)'')];
    fails = ["F1"];
  }
  {
    name = "P8-error-arm-instead-of-default";
    edits = [(replace config "        _ => default_value," ''Err(e) => panic!("{e}"),'')];
    fails = ["F12"];
  }
  {
    name = "P9-guard-change-is-the-minimum";
    edits = [(replace config "if max_stack > 0 =>" "if max_stack >= 5 =>")];
    changes."absorb.maxStack".minimum = 5;
  }
  {
    name = "P10-default-change-is-carried";
    edits = [(replace config "pub const MAX_STACK: usize = 10;" "pub const MAX_STACK: usize = 20;")];
    changes."absorb.maxStack".default = 20;
  }
  {
    name = "P11-declared-key-never-read";
    edits = [
      (append config ''

        pub const UNUSED_CONFIG_NAME: &str = "absorb.unused";
      '')
    ];
    deadKeysAdd = ["absorb.unused"];
  }
  {
    name = "P12-subprocess-git-config";
    edits = [
      (append config ''

        pub fn sub() { std::process::Command::new("git").args(["config", "--get", "absorb.sub"]).status().unwrap(); }
      '')
    ];
    fails = ["F7" "F9"];
  }
  {
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
  {
    name = "P19-test-only-write";
    edits = [
      (append config ''

        #[cfg(test)]
        fn t() { let mut c = git2::Config::new().unwrap(); c.set_str("absorb.testOnly", "x").unwrap(); }
      '')
    ];
  }

  # ── Review blind spots ─────────────────────────────────────────────
  {
    # Literal key, default through a parameter: paired per call path.
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
    # Key through a parameter, literal default.
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
    # A same-named const in another file does not replace this file's.
    name = "K3-same-named-const-elsewhere";
    edits = [(replace lib' "mod commute;\n" "mod commute;\nconst MAX_STACK: usize = 99;\n")];
  }
  {
    name = "K4-same-named-key-const-elsewhere";
    edits = [(replace lib' "mod commute;\n" "mod commute;\nconst FORCE_AUTHOR_CONFIG_NAME: &str = \"absorb.forceAuthorX\";\n")];
    # The read still resolves to this file's const; the other is dead.
    deadKeysAdd = ["absorb.forceAuthorX"];
  }
  {
    # A key outside `absorb.` read through the shape is git's own key.
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
    # "config" anywhere in an argv, after global options.
    name = "K6-git-config-after-global-options";
    edits = [
      (append config ''

        pub fn k6(p: &str) { std::process::Command::new("git").args(["-C", p, "config", "--get", FORCE_AUTHOR_CONFIG_NAME]).status().unwrap(); }
      '')
    ];
    fails = ["F7"];
  }
  {
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
    name = "K11-negated-ok-arm";
    edits = [(replace config "        Ok(value) => value," "        Ok(value) => !value,")];
    fails = ["F12"];
  }
  {
    name = "K12-compound-guard";
    edits = [(replace config "if max_stack > 0 =>" "if max_stack > 0 && max_stack < 100 =>")];
    fails = ["F12"];
  }

  # ── Syntax and prose a text pattern would misread ─────────────────────
  {
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
    name = "N3-fake-read-in-a-comment";
    edits = [
      (append config ''

        // match repo.config().and_then(|c| c.get_bool("absorb.comment")) { Ok(v) => v, _ => false }
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
