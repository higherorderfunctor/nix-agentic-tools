# cspell:ignore behaviour fstring  (upstream spellings the anchors must match)
# Mutants for lib/git-tool-settings/mutate.py over the git-revise source.
# Each makes one upstream-shaped change and names the outcome the extractor
# must produce: `fails` lists guard codes that must all fire; `adds` /
# `changes` / `deadKeysAdd` describe an output that must move with the
# source; a mutant with none must leave the output identical to the real one.
# Type requirements belong to lib/git-tool-settings/rules.nix;
# checks/git-tool-settings/rules.nix holds those cases. Prose is optional.
#
# P* came with the prototype. K* are the independent review's blind spots
# (a global option before `config`, a helper named through getattr, an argv
# assigned in branches, a splatted argv, an unguarded `git var`), each of
# which the prototype passed silently and which now fail closed.
let
  tui = "gitrevise/tui.py";
  odb = "gitrevise/odb.py";
  utils = "gitrevise/utils.py";
  man = "docs/man.rst";
  append = file: text: {
    inherit file;
    append = text;
  };
  replace = file: from: to: {inherit file from to;};
  # Inserted at the top of get_commentchar, where `repo` and `text` exist.
  inCommentchar = line:
    replace utils "def get_commentchar(repo: Repository, text: bytes) -> bytes:\n" "def get_commentchar(repo: Repository, text: bytes) -> bytes:\n${line}";
in [
  {
    name = "P0-noop-comment";
    edits = [(replace tui "def enable_autosquash(" "# harmless comment\ndef enable_autosquash(")];
  }
  {
    name = "P1-new-owned-key-undocumented";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    return repo.bool_config(\"revise.newThing\", default=False)\n")];
    # No man page entry: the description stays null for a row to fill.
    adds = ["revise.newThing"];
    changes."revise.newThing".description = null;
  }
  {
    name = "P2-new-owned-key-documented";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    return repo.bool_config(\"revise.newThing\", default=True)\n") (replace man ".. gitconfig:: revise.gpgSign" ".. gitconfig:: revise.newThing\n\n   Do the new thing.\n\n.. gitconfig:: revise.gpgSign")];
    adds = ["revise.newThing"];
    changes = {
      "revise.newThing" = {
        default = true;
        description = "Do the new thing.";
        type = "bool";
      };
    };
  }
  {
    name = "P3-new-foreign-key";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    return repo.config(\"merge.renames\", default=b\"true\")\n")];
    changes = {
      "merge.renames" = {
        default = "true";
        type = "string";
      };
    };
  }
  {
    name = "P-key-from-constant";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    KEY = \"revise.x\"\n    return repo.bool_config(KEY, default=False)\n")];
    fails = ["R2"];
  }
  {
    name = "P-key-fstring";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    n = \"x\"\n    return repo.config(f\"revise.{n}\", default=None)\n")];
    fails = ["R2"];
  }
  {
    name = "P-get-regexp-shape";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    return repo.git(\"config\", \"--get-regexp\", \"revise\\\\..*\")\n")];
    fails = ["R1"];
  }
  {
    name = "P-raw-subprocess";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    from subprocess import run\n    return run([\"git\", \"config\", \"--get\", \"revise.foo\"])\n")];
    fails = ["R1"];
  }
  {
    name = "P-git-dash-c";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    return repo.git(\"-c\", \"core.editor=vi\", \"commit\")\n")];
    fails = ["R1"];
  }
  {
    name = "P-starred-unresolvable";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    return repo.git(*repo.extra_argv)\n")];
    fails = ["R1"];
  }
  {
    name = "P-helper-as-value";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    get = repo.bool_config\n    return get(\"revise.x\", default=False)\n")];
    fails = ["R6"];
  }
  {
    name = "P-helper-kwargs";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    kw = {\"default\": False}\n    return repo.bool_config(\"revise.autoSquash\", **kw)\n")];
    fails = ["R2"];
  }
  {
    name = "P-new-helper-unknown-type";
    edits = [(replace odb "    def int_config(" "    def color_config(self, config: str, default: T) -> Union[bytes, T]:\n        try:\n            return self.git(\"config\", \"--get\", \"--type=color\", config)\n        except CalledProcessError:\n            return default\n\n    def int_config(")];
    fails = ["R3"];
  }
  {
    name = "P-bool-helper-semantics";
    edits = [(replace odb "return self.git(\"config\", \"--get\", \"--bool\", config) == b\"true\"" "return self.git(\"config\", \"--get\", \"--bool\", config) in (b\"true\", b\"yes\")")];
    fails = ["R5"];
  }
  {
    name = "P-helper-raises-instead";
    edits = [(replace odb "            return int(self.git(\"config\", \"--get\", \"--int\", config))\n        except CalledProcessError:\n            return default" "            return int(self.git(\"config\", \"--get\", \"--int\", config))\n        except CalledProcessError:\n            raise")];
    fails = ["R5"];
  }
  {
    name = "P4-new-path-helper";
    edits = [(replace odb "    def int_config(" "    def path_config(self, config: str, default: T) -> Union[bytes, T]:\n        try:\n            return self.git(\"config\", \"--get\", \"--path\", config)\n        except CalledProcessError:\n            return default\n\n    def int_config(") (append tui "\n\ndef probe(repo: Repository) -> object:\n    return repo.path_config(\"core.hooksPath\", default=None)\n")];
    changes = {
      "core.hooksPath" = {
        type = "path";
      };
    };
  }
  {
    name = "P-default-changes";
    edits = [(replace tui "default=repo.bool_config(\"rebase.autoSquash\", default=False)" "default=repo.bool_config(\"rebase.autoSquash\", default=True)")];
    changes = {
      "rebase.autoSquash" = {
        default = true;
      };
      "revise.autoSquash" = {
        default = true;
      };
    };
  }
  {
    name = "P-fallback-removed";
    edits = [(replace tui "default=repo.bool_config(\"rebase.autoSquash\", default=False)" "default=False")];
    changes = {
      "revise.autoSquash" = {
        default = false;
        fallback = null;
      };
    };
  }
  {
    name = "P-cli-override-removed";
    edits = [(replace tui "    if args.no_autosquash:\n        return False\n" "")];
    changes = {
      "revise.autoSquash" = {
        overriddenBy = ["--autosquash"];
      };
    };
  }
  {
    name = "P-override-by-unknown-arg";
    edits = [(replace tui "    if args.no_autosquash:\n" "    if args.no_autosquash or args.bogus_flag:\n")];
    fails = ["R11"];
  }
  {
    name = "P-computed-owned-default";
    edits = [(replace odb "\"revise.gpgSign\", default=self.bool_config(\"commit.gpgSign\", default=False)" "\"revise.gpgSign\", default=self.gitdir.exists()")];
    changes."revise.gpgSign".defaultExpr = "self.gitdir.exists()";
  }
  {
    name = "P-key-literal-in-help";
    edits = [(replace tui "help=\"force disable revise.autoSquash behaviour\"" "help=\"force disable revise.autoSquash and revise.squashMode behaviour\"")];
    deadKeysAdd = ["revise.squashMode"];
  }
  {
    name = "P-env-config-injection";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    import os\n    os.environ[\"GIT_CONFIG_PARAMETERS\"] = \"x\"\n")];
    fails = ["R13"];
  }
  {
    name = "P-two-spellings";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    return repo.bool_config(\"revise.autosquash\", default=False)\n")];
    fails = ["R7"];
  }
  {
    name = "P-conflicting-defaults";
    edits = [(append tui "\n\ndef probe(repo: Repository) -> object:\n    return repo.bool_config(\"commit.verbose\", default=True)\n")];
    fails = ["R7"];
  }
  {
    name = "P-string-helper-type-flag-changed";
    edits = [(replace odb "return self.git(\"config\", \"--get\", setting)" "return self.git(\"config\", \"--get\", \"--type=bool-or-str\", setting)")];
    fails = ["R3"];
  }

  # ── Review blind spots (git-revise-critic §4) ─────────────────────────
  {
    name = "K1-global-option-before-config";
    edits = [(inCommentchar "    repo.git(\"-C\", str(repo.workdir), \"config\", \"--get\", \"core.newKey\")\n")];
    fails = ["R1"];
  }
  {
    name = "K2-helper-named-through-getattr";
    edits = [(inCommentchar "    getattr(repo, \"bool_config\")(\"core.newKey\", False)\n")];
    fails = ["R6"];
  }
  {
    name = "K3-argv-assigned-in-branches";
    edits = [(inCommentchar "    if text:\n        argv = [\"git\", \"log\"]\n    else:\n        argv = [\"git\", \"show\"]\n    run(argv)\n")];
    fails = ["R1"];
  }
  {
    # A splat before the subcommand: its list is followed, and a subcommand
    # the tree cannot read ("con" + "fig") is a failure, not a pass.
    name = "K4-splatted-argv";
    edits = [(inCommentchar "    base = [\"git\"]\n    run([*base, \"con\" + \"fig\", \"--get\", \"core.newKey\"])\n")];
    fails = ["R1"];
  }
  {
    name = "K5-unguarded-git-var";
    edits = [(inCommentchar "    repo.git(\"var\", \"GIT_PAGER\")\n")];
    fails = ["R14"];
  }
  {
    # The literal "config" anywhere outside the helpers fails, however the
    # argv around it is built.
    name = "K6-config-literal-in-a-variable";
    edits = [(inCommentchar "    sub = \"config\"\n")];
    fails = ["R1"];
  }

  # ── Prose the key net must not misread ────────────────────────────────
  {
    # `git-revise.newThing` names the program, not the key `revise.newThing`.
    name = "N1-prose-that-contains-a-key-prefix";
    edits = [(append tui "\n\ndef about() -> str:\n    return \"see git-revise.newThing in the docs\"\n")];
  }
]
