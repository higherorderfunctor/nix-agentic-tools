# Mutants for lib/git-tool-settings/mutate.py. Each makes one upstream-shaped change to
# the patched source (or to the annotations) and names the outcome the
# extractor must produce: `fails` lists guard codes that must all fire;
# `adds` / `changes` describe an output that must move with the source; a
# mutant with neither must leave the output identical to the real one.
#
# M* came with the prototype. C* are the shapes an independent review found
# the prototype silently mishandled; each one now fails closed or is
# extracted. G* exercise the guards added with them. N* are syntax the tree
# walk reads correctly where a text pattern over the source would not: a
# fake call in a comment, a raw multi-line string, nested generics, an
# argument holding `>`, `)` or `,`, a key built across lines, and prose
# that only looks like a key to a naive pattern.
let
  config = "git-branchless-lib/src/core/config.rs";
  api = "git-branchless-lib/src/git/config.rs";
  eval = "git-branchless-revset/src/eval.rs";
  builtins' = "git-branchless-revset/src/builtins.rs";
  append = file: text: {
    inherit file;
    append = text;
  };
  replace = file: from: to: {inherit file from to;};
  testShowVerboseArm = ''Hint::TestShowVerbose => "branchless.hint.testShowVerbose",'';
in [
  # ── Prototype mutants ─────────────────────────────────────────────────
  {
    name = "M1-new-accessor";
    edits = [
      (append config ''

        pub fn get_new(repo: &Repo) -> eyre::Result<bool> {
            repo.get_readonly_config()?.get_or("branchless.new.flag", true)
        }
      '')
    ];
    adds = ["branchless.new.flag"];
  }
  {
    name = "M2-untyped-if-let";
    edits = [
      (append config ''

        pub fn get_u(repo: &Repo) -> eyre::Result<()> {
            let config = repo.get_readonly_config()?;
            if let Some(x) = config.get("branchless.new.untyped")? { let _: String = x; }
            Ok(())
        }
      '')
    ];
    fails = ["F3"];
  }
  {
    name = "M3-key-from-helper";
    edits = [
      (append config ''

        fn key_for(s: &str) -> String { s.to_owned() }
        pub fn get_h(repo: &Repo) -> eyre::Result<Option<String>> {
            let v: Option<String> = repo.get_readonly_config()?.get(key_for("x"))?;
            Ok(v)
        }
      '')
    ];
    fails = ["F2"];
  }
  {
    name = "M4-qualified-call";
    edits = [
      (append config ''

        pub fn get_qualified(repo: &Repo) -> eyre::Result<Option<bool>> {
            let c = repo.get_readonly_config()?;
            ConfigRead::get(&c, "branchless.qualified.flag")
        }
      '')
    ];
    fails = ["F1"];
  }
  {
    name = "M5-struct-field";
    edits = [
      (append config ''

        pub struct Holder { cfg: Config }
        pub fn make(repo: &Repo) -> eyre::Result<Holder> {
            Ok(Holder { cfg: repo.get_readonly_config()?.into_config() })
        }
      '')
    ];
    fails = ["F10"];
  }
  {
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
    name = "M7-argv-variable-key";
    edits = [
      (append config ''

        pub fn get_sub(git_run_info: &GitRunInfo, repo: &Repo, key: &str) -> eyre::Result<()> {
            git_run_info.run_silent(repo, None, &["config", key], GitRunOpts::default())?;
            Ok(())
        }
      '')
    ];
    fails = ["F7"];
  }
  {
    name = "M8-alias-chain";
    edits = [
      (append config ''

        pub fn get_chain(repo: &Repo) -> eyre::Result<bool> {
            let c = repo.get_readonly_config()?;
            let d = c;
            d.get_or("branchless.chain.flag", false)
        }
      '')
    ];
    adds = ["branchless.chain.flag"];
  }
  {
    name = "M9-new-hint-variant";
    edits = [
      (replace config testShowVerboseArm ''
        ${testShowVerboseArm}
                    Hint::NewThing => "branchless.hint.newThing",'')
      (replace config "    TestShowVerbose,\n}" "    TestShowVerbose,\n\n    /// A brand new hint.\n    NewThing,\n}")
    ];
    adds = ["branchless.hint.newThing"];
    changes."branchless.hint.newThing".description = "A brand new hint.";
  }
  {
    name = "M10-stale-annotation";
    annotations.settings."branchless.gone.key".type = "bool";
    fails = ["F4"];
  }

  # ── Review mutants: shapes the prototype lost without failing ─────────
  {
    name = "C1-closure-receiver-in-keyed-fn";
    edits = [
      (append config ''

        pub fn get_c1(repo: &Repo) -> eyre::Result<bool> {
            let a = repo.get_readonly_config()?.get_or("branchless.smartlog.reverse", false)?;
            let b: bool = repo.get_readonly_config().map(|c| c.get_or("branchless.hidden.closure", true))??;
            Ok(a && b)
        }
      '')
    ];
    fails = ["F9"];
  }
  {
    name = "C1b-closure-receiver-alone";
    edits = [
      (append config ''

        pub fn get_c1b(repo: &Repo) -> eyre::Result<bool> {
            let b: bool = repo.get_readonly_config().map(|c| c.get_or("branchless.hidden.closure2", true))??;
            Ok(b)
        }
      '')
    ];
    fails = ["F9" "F10"];
  }
  {
    name = "C2-read-inside-macro";
    edits = [
      (append config ''

        pub fn get_c2(effects: &Effects, repo: &Repo) -> eyre::Result<()> {
            let config = repo.get_readonly_config()?;
            let _v: bool = config.get_or("branchless.smartlog.reverse", false)?;
            writeln!(effects.get_output_stream(), "{}", config.get_or("branchless.hidden.macro", true)?)?;
            Ok(())
        }
      '')
    ];
    fails = ["F9"];
  }
  {
    name = "C3-hint-arm-const";
    edits = [
      (replace config testShowVerboseArm "            Hint::TestShowVerbose => TEST_SHOW_VERBOSE_KEY,")
      (append config ''

        pub const TEST_SHOW_VERBOSE_KEY: &str = "branchless.hint.testShowVerbose";
      '')
    ];
    fails = ["F2" "F8"];
  }
  {
    name = "C3b-hint-arm-format";
    edits = [
      (replace config testShowVerboseArm ''
        ${testShowVerboseArm}
                    Hint::Dyn(n) => leak(format!("branchless.hint.{n}")),'')
    ];
    fails = ["F2"];
  }
  {
    name = "C4-generic-bound";
    edits = [
      (append config ''

        fn read_it<C: ConfigRead>(c: &C) -> eyre::Result<bool> { c.get_or("branchless.hidden.generic", true) }
        pub fn get_c4(repo: &Repo) -> eyre::Result<bool> { let config = repo.get_readonly_config()?; read_it(&config) }
      '')
    ];
    fails = ["F9" "F10"];
  }
  {
    name = "C4b-generic-in-keyed-fn";
    edits = [
      (append config ''

        fn read_it2<C>(c: &C) -> eyre::Result<bool> where C: ConfigRead { c.get_or("branchless.hidden.generic2", true) }
        pub fn get_c4b(repo: &Repo) -> eyre::Result<bool> { let config = repo.get_readonly_config()?; let _x: bool = config.get_or("branchless.smartlog.reverse", false)?; read_it2(&config) }
      '')
    ];
    fails = ["F9"];
  }
  {
    name = "C5-key-via-param";
    edits = [
      (append config ''

        fn flag(repo: &Repo, key: &str, d: bool) -> eyre::Result<bool> { repo.get_readonly_config()?.get_or(key, d) }
        pub fn get_c5(repo: &Repo) -> eyre::Result<bool> { flag(repo, "branchless.hidden.param", true) }
      '')
    ];
    fails = ["F2"];
  }
  {
    name = "C6-command-builder";
    edits = [
      (append config ''

        pub fn get_c6() -> eyre::Result<()> {
            std::process::Command::new("git").arg("config").arg("branchless.hidden.cmd").output()?;
            Ok(())
        }
      '')
    ];
    fails = ["F9"];
  }
  {
    name = "C6b-vec-macro-argv";
    edits = [
      (append config ''

        pub fn get_c6b(git_run_info: &GitRunInfo, repo: &Repo) -> eyre::Result<()> {
            let args = vec!["config", "branchless.hidden.vec"];
            git_run_info.run_silent(repo, None, &args, GitRunOpts::default())?;
            Ok(())
        }
      '')
    ];
    fails = ["F9"];
  }
  {
    name = "C7-if-key";
    edits = [
      (append config ''

        pub fn get_c7(repo: &Repo, x: bool) -> eyre::Result<bool> {
            let key = if x { "branchless.hidden.ifA" } else { "branchless.hidden.ifB" };
            repo.get_readonly_config()?.get_or(key, true)
        }
      '')
    ];
    fails = ["F2"];
  }
  {
    name = "C8-static-key";
    edits = [
      (append config ''

        static HIDDEN_KEY: &str = "branchless.hidden.static";
        pub fn get_c8(repo: &Repo) -> eyre::Result<bool> { repo.get_readonly_config()?.get_or(HIDDEN_KEY, true) }
      '')
    ];
    fails = ["F2"];
  }
  {
    # A const default is resolved rather than rejected.
    name = "C9-default-const";
    edits = [
      (append config ''

        const DEF: bool = true;
        pub fn get_c9(repo: &Repo) -> eyre::Result<bool> { repo.get_readonly_config()?.get_or("branchless.hidden.constDefault", DEF) }
      '')
    ];
    adds = ["branchless.hidden.constDefault"];
    changes."branchless.hidden.constDefault" = {
      default = true;
      type = "bool";
    };
  }
  {
    # Test code is whatever `#[cfg(test)]` marks, whatever the module is called.
    name = "C10-cfg-test-module-not-named-tests";
    edits = [
      (append config ''

        #[cfg(test)]
        mod helpers {
            use super::*;
            pub fn get_c10(repo: &Repo) -> eyre::Result<bool> { repo.get_readonly_config()?.get_or("branchless.testOnly.flag", true) }
        }
      '')
    ];
  }
  {
    name = "C11-default-through-const";
    edits = [
      (replace config ''"((draft() | branches() | @) % main()) | branches() | @".to_string()'' "DEFAULT_REVSET.to_string()")
      (append config ''

        const DEFAULT_REVSET: &str = "draft()";
      '')
    ];
    changes."branchless.smartlog.defaultRevset".default = "draft()";
  }
  {
    name = "C12-git2-direct";
    edits = [
      (append config ''

        pub fn get_c12(repo: &Repo) -> eyre::Result<bool> {
            let r = git2::Repository::open(repo.get_path())?;
            Ok(r.config()?.get_bool("branchless.hidden.git2")?)
        }
      '')
    ];
    fails = ["F6"];
  }

  # ── Guards added with the review fixes ────────────────────────────────
  {
    name = "G1-unread-key-const";
    edits = [
      (append config ''

        pub const OTHER_KEY: &str = "branchless.dead.other";
      '')
    ];
    fails = ["F8"];
  }
  {
    name = "G2-stale-dead-key";
    annotations.deadKeys."branchless.gone.dead" = "no longer declared";
    fails = ["F4"];
  }
  {
    name = "G3-shadowing-annotation";
    annotations.settings."branchless.smartlog.reverse".default = true;
    fails = ["F4"];
  }
  {
    name = "G4-unclassified-test-cfg";
    edits = [
      (append config ''

        #[cfg(all(test, unix))]
        mod platform_helpers {}
      '')
    ];
    fails = ["F11"];
  }
  {
    name = "G5-computed-default";
    edits = [
      (append config ''

        pub fn get_g5(repo: &Repo) -> eyre::Result<String> {
            repo.get_readonly_config()?.get_or_else("branchless.computed.default", || default_revset())
        }
      '')
    ];
    fails = ["F12"];
  }
  {
    name = "G6-conflicting-defaults";
    edits = [
      (append config ''

        pub fn get_g6(repo: &Repo) -> eyre::Result<bool> {
            repo.get_readonly_config()?.get_or("branchless.smartlog.reverse", true)
        }
      '')
    ];
    fails = ["F13"];
  }
  {
    name = "G7-new-builtin-revset";
    edits = [(replace builtins' ''("tests.fixable", &fn_tests_fixable),'' ''("tests.fixable", &fn_tests_fixable), ("newFunction", &fn_all),'')];
    revsetFunctionsAdd = ["newFunction"];
  }
  {
    name = "G8-builtin-of-another-shape";
    edits = [(replace builtins' ''("tests.fixable", &fn_tests_fixable),'' ''("tests.fixable", &fn_tests_fixable), ("odd", make_fn()),'')];
    fails = ["F14"];
  }
  {
    name = "G9-builtins-no-longer-first";
    edits = [(replace eval "if let Some(function) = FUNCTIONS.get(name) {" "if let Some(function) = lookup_builtin(name) {")];
    fails = ["F14"];
  }

  # ── Syntax a text pattern would misread ───────────────────────────────
  {
    # A multi-line raw string still feeds the literal net.
    name = "N1-key-in-multiline-raw-string";
    edits = [
      (append config ''

        pub fn describe_hidden() -> &'static str {
            r#"Set this in your configuration:
            branchless.hidden.raw = true"#
        }
      '')
    ];
    fails = ["F9"];
  }
  {
    # `git-branchless.x` is prose, not the key `branchless.x`.
    name = "N2-prose-that-contains-a-key-prefix";
    edits = [
      (append config ''

        pub fn about() -> &'static str { "see the git-branchless.hidden.prose page" }
      '')
    ];
  }
  {
    # A call written inside a comment is not a call.
    name = "N3-fake-call-in-a-comment";
    edits = [
      (append config ''

        // repo.get_readonly_config()?.get_or("branchless.hidden.comment", true)
      '')
    ];
  }
  {
    # A format! argument holding `>` and `,` is one argument.
    name = "N4-format-argument-with-operators";
    edits = [
      (append config ''

        pub fn get_n4(repo: &Repo, level: Option<u8>) -> eyre::Result<Option<bool>> {
            let v: Option<bool> = repo
                .get_readonly_config()?
                .get(format!("branchless.hidden.{}", level.map(|v| v > 1).unwrap_or(max(1, 2) > 0)))?;
            Ok(v)
        }
      '')
    ];
    adds = ["branchless.hidden.<name>"];
    changes."branchless.hidden.<name>".type = "bool";
  }
  {
    # Nested generics: the whole `Option<..>` argument is the type.
    name = "N5-nested-generic-type";
    edits = [
      (append config ''

        pub fn get_n5(repo: &Repo) -> eyre::Result<Option<Vec<Option<String>>>> {
            let v: Option<Vec<Option<String>>> = repo.get_readonly_config()?.get("branchless.hidden.nested")?;
            Ok(v)
        }
      '')
    ];
    adds = ["branchless.hidden.nested"];
    changes."branchless.hidden.nested".type = "Vec<Option<String>>";
  }
  {
    # A key assembled across lines resolves to nothing: fail, never guess.
    name = "N6-key-built-across-lines";
    edits = [
      (append config ''

        pub fn get_n6(repo: &Repo) -> eyre::Result<bool> {
            repo.get_readonly_config()?.get_or(concat!(
                "branchless.",
                "hidden.split"
            ), true)
        }
      '')
    ];
    fails = ["F2"];
  }
  {
    # A default string holding `)` and `,` is one literal.
    name = "N7-default-string-with-delimiters";
    edits = [
      (append config ''

        pub fn get_n7(repo: &Repo) -> eyre::Result<String> {
            repo.get_readonly_config()?.get_or_else("branchless.hidden.odd", || { "a), b(".to_string() })
        }
      '')
    ];
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
    edits = [
      (append config ''

        pub const MAIN_BRANCH_HINT: &str = "branchless.core.mainBranch is required";
      '')
    ];
  }
]
