# Mutants for lib/git-tool-settings/mutate.py. Each makes one upstream-shaped change to
# the patched source and names the outcome the extractor must produce:
# `fails` lists guard codes that must all fire; `adds` / `changes` /
# `deadKeysAdd` / `revsetFunctionsAdd` describe an output that must move with
# the source; a mutant with none must leave the output identical to the real
# one. What a person must write for a new name (a type, a dead key's reason)
# is lib/git-tool-settings/rules.nix's to demand; checks/git-tool-settings/
# rules.nix holds those cases.
#
# M* came with the prototype. C* are the shapes an independent review found
# the prototype silently mishandled; each one now fails closed or is
# extracted. G* exercise the guards added with them. N* are syntax the tree
# walk reads correctly where a text pattern over the source would not: a
# fake call in a comment, a raw multi-line string, nested generics, an
# argument holding `>`, `)` or `,`, and a key built across lines.
let
  config = "git-branchless-lib/src/core/config.rs";
  api = "git-branchless-lib/src/git/config.rs";
  eval = "git-branchless-revset/src/eval.rs";
  builtins' = "git-branchless-revset/src/builtins.rs";
  appendConfig = text: {
    file = config;
    append = text;
  };
  configEdits = text: [(appendConfig text)];
  replace = file: from: to: {inherit file from to;};
  withBuiltin = entry: let
    anchor = ''("tests.fixable", &fn_tests_fixable),'';
  in [(replace builtins' anchor "${anchor} ${entry},")];
  testShowVerboseArm = ''Hint::TestShowVerbose => "branchless.hint.testShowVerbose",'';
in [
  # ── Prototype mutants ─────────────────────────────────────────────────
  {
    # An if-let binding must stay untyped for reconciliation rather than
    # guessing a type from a use of the bound value.
    name = "M2-untyped-if-let";
    edits = configEdits ''

      pub fn get_u(repo: &Repo) -> eyre::Result<()> {
          let config = repo.get_readonly_config()?;
          if let Some(x) = config.get("branchless.new.untyped")? { let _: String = x; }
          Ok(())
      }
    '';
    adds = ["branchless.new.untyped"];
    changes."branchless.new.untyped".type = null;
  }
  {
    # Calling through the trait path cannot silently escape receiver classification.
    name = "M4-qualified-call";
    edits = configEdits ''

      pub fn get_qualified(repo: &Repo) -> eyre::Result<Option<bool>> {
          let c = repo.get_readonly_config()?;
          ConfigRead::get(&c, "branchless.qualified.flag")
      }
    '';
    fails = ["F1"];
  }
  {
    # Storing a config handle in a struct field trips F10 without obtaining a handle.
    name = "M5-struct-field";
    edits = configEdits ''

      pub struct Holder { cfg: Config }
    '';
    fails = ["F10"];
  }
  {
    # A new method on the config trait makes the known accessor list unsafe.
    name = "M6-new-api-method";
    edits = [
      (replace api "    /// Same as `get`, but uses a default value" ''
        /// New.
        fn get_or_default<V: GetConfigValue<V> + Default, S: AsRef<str>>(&self, key: S) -> eyre::Result<V> { Ok(self.get(key)?.unwrap_or_default()) }

        /// Same as `get`, but uses a default value'')
    ];
    fails = ["F5"];
  }
  {
    # A git config argument array with a key parameter must not be skipped.
    name = "M7-argv-variable-key";
    edits = configEdits ''

      pub fn get_sub(git_run_info: &GitRunInfo, repo: &Repo, key: &str) -> eyre::Result<()> {
          git_run_info.run_silent(repo, None, &["config", key], GitRunOpts::default())?;
          Ok(())
      }
    '';
    fails = ["F7"];
  }
  {
    # Following a local handle alias must retain the repository chain.
    name = "M8-alias-chain";
    edits = configEdits ''

      pub fn get_chain(repo: &Repo) -> eyre::Result<bool> {
          let c = repo.get_readonly_config()?;
          let d = c;
          d.get_or("branchless.chain.flag", false)
      }
    '';
    adds = ["branchless.chain.flag"];
    changes."branchless.chain.flag".reads."${config}#get_chain" = ["repository"];
  }
  {
    # A new hint arm contributes a key; drift checks the variant descriptions.
    name = "M9-new-hint-variant";
    edits = [
      (replace config testShowVerboseArm ''
        ${testShowVerboseArm}
                    Hint::NewThing => "branchless.hint.newThing",'')
      (replace config "    TestShowVerbose,\n}" "    TestShowVerbose,\n\n    /// A brand new hint.\n    NewThing,\n}")
    ];
    adds = ["branchless.hint.newThing"];
  }

  # ── Review mutants: shapes the prototype lost without failing ─────────
  {
    # A valid read in the same function must not hide an unresolved closure read.
    name = "C1-closure-receiver-in-keyed-fn";
    edits = configEdits ''

      pub fn get_c1(repo: &Repo) -> eyre::Result<bool> {
          let a = repo.get_readonly_config()?.get_or("branchless.smartlog.reverse", false)?;
          let b: bool = repo.get_readonly_config().map(|c| c.get_or("branchless.hidden.closure", true))??;
          Ok(a && b)
      }
    '';
    fails = ["F9"];
  }
  {
    # A producer in a closure-only function must also trip the keyless-handle guard.
    name = "C1b-closure-receiver-alone";
    edits = configEdits ''

      pub fn get_c1b(repo: &Repo) -> eyre::Result<bool> {
          let b: bool = repo.get_readonly_config().map(|c| c.get_or("branchless.hidden.closure2", true))??;
          Ok(b)
      }
    '';
    fails = ["F10"];
  }
  {
    # The key net must see string tokens in a formatting macro, not just call nodes.
    name = "C2-read-inside-macro";
    edits = configEdits ''

      pub fn get_c2(effects: &Effects, repo: &Repo) -> eyre::Result<()> {
          let config = repo.get_readonly_config()?;
          let _v: bool = config.get_or("branchless.smartlog.reverse", false)?;
          writeln!(effects.get_output_stream(), "{}", config.get_or("branchless.hidden.macro", true)?)?;
          Ok(())
      }
    '';
    fails = ["F9"];
  }
  {
    # The match-arm guard must reject an identifier even when it names a known key.
    name = "C3-hint-arm-const";
    edits = [
      (replace config testShowVerboseArm "            Hint::TestShowVerbose => TEST_SHOW_VERBOSE_KEY,")
      (appendConfig ''

        pub const TEST_SHOW_VERBOSE_KEY: &str = "branchless.hint.testShowVerbose";
      '')
    ];
    fails = ["F2"];
  }
  {
    # A handoff to an inline generic bound must not count as a recognized config callee.
    name = "C4-generic-bound";
    edits = configEdits ''

      fn read_it<C: ConfigRead>(c: &C) -> eyre::Result<bool> { c.get_or("branchless.hidden.generic", true) }
      pub fn get_c4(repo: &Repo) -> eyre::Result<bool> { let config = repo.get_readonly_config()?; read_it(&config) }
    '';
    fails = ["F9" "F10"];
  }
  {
    # A key parameter must not be guessed from the literal at one caller.
    name = "C5-key-via-param";
    edits = configEdits ''

      fn flag(repo: &Repo, key: &str, d: bool) -> eyre::Result<bool> { repo.get_readonly_config()?.get_or(key, d) }
      pub fn get_c5(repo: &Repo) -> eyre::Result<bool> { flag(repo, "branchless.hidden.param", true) }
    '';
    fails = ["F2"];
  }
  {
    # The literal net still sees a key in chained Command builder calls.
    name = "C6-command-builder";
    edits = configEdits ''

      pub fn get_c6() -> eyre::Result<()> {
          std::process::Command::new("git").arg("config").arg("branchless.hidden.cmd").output()?;
          Ok(())
      }
    '';
    fails = ["F9"];
  }
  {
    # Following a local key binding into a branch must not silently choose one arm.
    name = "C7-if-key";
    edits = configEdits ''

      pub fn get_c7(repo: &Repo, x: bool) -> eyre::Result<bool> {
          let key = if x { "branchless.hidden.ifA" } else { "branchless.hidden.ifB" };
          repo.get_readonly_config()?.get_or(key, true)
      }
    '';
    fails = ["F2"];
  }
  {
    # A static identifier is not a supported literal const key.
    name = "C8-static-key";
    edits = configEdits ''

      static HIDDEN_KEY: &str = "branchless.hidden.static";
      pub fn get_c8(repo: &Repo) -> eyre::Result<bool> { repo.get_readonly_config()?.get_or(HIDDEN_KEY, true) }
    '';
    fails = ["F2"];
  }
  {
    # A const default is resolved rather than rejected.
    name = "C9-default-const";
    edits = configEdits ''

      const DEF: bool = true;
      pub fn get_c9(repo: &Repo) -> eyre::Result<bool> { repo.get_readonly_config()?.get_or("branchless.hidden.constDefault", DEF) }
    '';
    adds = ["branchless.hidden.constDefault"];
    changes."branchless.hidden.constDefault" = {
      default = true;
      type = "bool";
    };
  }
  {
    # Test code is whatever `#[cfg(test)]` marks, whatever the module is called.
    name = "C10-cfg-test-module-not-named-tests";
    edits = configEdits ''

      #[cfg(test)]
      mod helpers {
          use super::*;
          pub fn get_c10(repo: &Repo) -> eyre::Result<bool> { repo.get_readonly_config()?.get_or("branchless.testOnly.flag", true) }
      }
    '';
  }
  {
    # A literal string const provides a default through an owned-string conversion.
    name = "C11-default-through-const";
    edits = [
      (replace config ''"((draft() | branches() | @) % main()) | branches() | @".to_string()'' "DEFAULT_REVSET.to_string()")
      (appendConfig ''

        const DEFAULT_REVSET: &str = "draft()";
      '')
    ];
    changes."branchless.smartlog.defaultRevset".default = "draft()";
  }
  {
    # A git2 repository opened directly must not bypass the raw config allowlist.
    name = "C12-git2-direct";
    edits = configEdits ''

      pub fn get_c12(repo: &Repo) -> eyre::Result<bool> {
          let r = git2::Repository::open(repo.get_path())?;
          Ok(r.config()?.get_bool("branchless.hidden.git2")?)
      }
    '';
    fails = ["F6"];
  }

  # ── Guards added with the review fixes ────────────────────────────────
  {
    # An exact key-shaped const with no reader belongs in the dead-key census.
    name = "G1-unread-key-const";
    edits = configEdits ''

      pub const OTHER_KEY: &str = "branchless.dead.other";
    '';
    deadKeysAdd = ["branchless.dead.other"];
  }
  {
    # A compound test cfg is not safe to classify as the simple test marker.
    name = "G4-unclassified-test-cfg";
    edits = configEdits ''

      #[cfg(all(test, unix))]
      mod platform_helpers {}
    '';
    fails = ["F11"];
  }
  {
    # A closure that calls a default helper must not silently omit its computed default.
    name = "G5-computed-default";
    edits = configEdits ''

      pub fn get_g5(repo: &Repo) -> eyre::Result<String> {
          repo.get_readonly_config()?.get_or_else("branchless.computed.default", || default_revset())
      }
    '';
    fails = ["F12"];
  }
  {
    # Two literal defaults for the same key must not be resolved by first-wins.
    name = "G6-conflicting-defaults";
    edits = configEdits ''

      pub fn get_g6(repo: &Repo) -> eyre::Result<bool> {
          repo.get_readonly_config()?.get_or("branchless.smartlog.reverse", true)
      }
    '';
    fails = ["F13"];
  }
  {
    # A new builtin entry must appear in the name list used for alias validation.
    name = "G7-new-builtin-revset";
    edits = withBuiltin ''("newFunction", &fn_all)'';
    revsetFunctionsAdd = ["newFunction"];
  }
  {
    # An entry with a computed function must not be skipped from the builtin table.
    name = "G8-builtin-of-another-shape";
    edits = withBuiltin ''("odd", make_fn())'';
    fails = ["F14"];
  }
  {
    # The guard notices when a resolver no longer proves the builtin comes first.
    name = "G9-builtin-lookup-order-unproven";
    edits = [(replace eval "if let Some(function) = FUNCTIONS.get(name) {" "if let Some(function) = lookup_builtin(name) {")];
    fails = ["F14"];
  }

  # ── Syntax a text pattern would misread ───────────────────────────────
  {
    # A multi-line raw string still feeds the literal net.
    name = "N1-key-in-multiline-raw-string";
    edits = configEdits ''

      pub fn describe_hidden() -> &'static str {
          r#"Set this in your configuration:
          branchless.hidden.raw = true"#
      }
    '';
    fails = ["F9"];
  }
  {
    # A call written inside a comment is not a call.
    name = "N3-fake-call-in-a-comment";
    edits = configEdits ''

      // repo.get_readonly_config()?.get_or("branchless.hidden.comment", true)
    '';
  }
  {
    # A format! argument holding `>` and `,` is one argument.
    name = "N4-format-argument-with-operators";
    edits = configEdits ''

      pub fn get_n4(repo: &Repo, level: Option<u8>) -> eyre::Result<Option<bool>> {
          let v: Option<bool> = repo
              .get_readonly_config()?
              .get(format!("branchless.hidden.{}", level.map(|v| v > 1).unwrap_or(max(1, 2) > 0)))?;
          Ok(v)
      }
    '';
    adds = ["branchless.hidden.<name>"];
    changes."branchless.hidden.<name>".type = "bool";
  }
  {
    # Nested generics: the whole `Option<..>` argument is the type.
    name = "N5-nested-generic-type";
    edits = configEdits ''

      pub fn get_n5(repo: &Repo) -> eyre::Result<Option<Vec<Option<String>>>> {
          let v: Option<Vec<Option<String>>> = repo.get_readonly_config()?.get("branchless.hidden.nested")?;
          Ok(v)
      }
    '';
    adds = ["branchless.hidden.nested"];
    changes."branchless.hidden.nested".type = "Vec<Option<String>>";
  }
  {
    # A key assembled across lines resolves to nothing: fail, never guess.
    name = "N6-key-built-across-lines";
    edits = configEdits ''

      pub fn get_n6(repo: &Repo) -> eyre::Result<bool> {
          repo.get_readonly_config()?.get_or(concat!(
              "branchless.",
              "hidden.split"
          ), true)
      }
    '';
    fails = ["F2"];
  }
  {
    # A default string holding `)` and `,` is one literal.
    name = "N7-default-string-with-delimiters";
    edits = configEdits ''

      pub fn get_n7(repo: &Repo) -> eyre::Result<String> {
          repo.get_readonly_config()?.get_or_else("branchless.hidden.odd", || { "a), b(".to_string() })
      }
    '';
    adds = ["branchless.hidden.odd"];
    changes."branchless.hidden.odd" = {
      default = "a), b(";
      type = "string";
    };
  }
  {
    # "(deprecated) branchless.smartlog.reverseOrder" does not deprecate
    # branchless.smartlog.reverse.
    name = "N8-deprecated-marker-on-a-longer-key";
    edits = [
      (replace config "/// Whether to reverse the smartlog direction by default\n" ''
        /// Whether to reverse the smartlog direction by default
        /// (deprecated) branchless.smartlog.reverseOrder is no longer read.
      '')
    ];
    changes."branchless.smartlog.reverse" = {
      description = "Whether to reverse the smartlog direction by default (deprecated) branchless.smartlog.reverseOrder is no longer read.";
      status = "current";
    };
  }
  {
    # A const holding a sentence that names a key is not a key const.
    name = "N9-const-sentence-naming-a-key";
    edits = configEdits ''

      pub const MAIN_BRANCH_HINT: &str = "branchless.core.mainBranch is required";
    '';
  }
]
