# cspell:ignore behaviour commentchar
# Upstream-shaped mutations for lib/git-tool-settings/mutate.py. The pinned
# source is the valid control: it must extract before any mutant can run.
# Keep source recognition here; checks/git-tool-settings/rules.nix covers
# reconciliation with the declared types and optional hand-written prose.
let
  man = "docs/man.rst";
  odb = "gitrevise/odb.py";
  tui = "gitrevise/tui.py";
  utils = "gitrevise/utils.py";

  append = file: text: {
    inherit file;
    append = text;
  };
  replace = file: from: to: {inherit file from to;};
  addConfigHelper = name: flag:
    replace odb "    def int_config(" "    def ${name}(self, config: str, default: T) -> Union[bytes, T]:\n        try:\n            return self.git(\"config\", \"--get\", \"${flag}\", config)\n        except CalledProcessError:\n            return default\n\n    def int_config(";
  # Inserted at the top of get_commentchar, where `repo` and `text` exist.
  inCommentchar = line:
    replace utils "def get_commentchar(repo: Repository, text: bytes) -> bytes:\n" "def get_commentchar(repo: Repository, text: bytes) -> bytes:\n${line}";
  probe = body: append tui "\n\ndef probe(repo: Repository) -> object:\n    ${body}\n";
  splattedRunner = subcommand:
    inCommentchar "    base = [\"git\"]\n    run([*base, ${subcommand}])\n";
in [
  # Extracted facts
  {
    # Comment text is not a config read or a dead-key mention.
    name = "P0-noop-comment";
    edits = [(replace tui "def enable_autosquash(" "# repo.git(\"config\", \"--get\", \"revise.newThing\")\ndef enable_autosquash(")];
  }
  {
    # Join the new man page directive to the live read, not just hard-coded baseline keys.
    name = "P2-new-owned-key-documented";
    edits = [
      (probe "return repo.bool_config(\"revise.newThing\", default=True)")
      (replace man ".. gitconfig:: revise.gpgSign" ".. gitconfig:: revise.newThing\n\n   Do the new thing.\n\n.. gitconfig:: revise.gpgSign")
    ];
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
    # Record a new foreign read without advertising it as an owned setting.
    name = "P3-new-foreign-key";
    edits = [(probe "return repo.config(\"merge.renames\", default=b\"true\")")];
    changes = {
      "merge.renames" = {
        default = "true";
        type = "string";
      };
    };
  }
  {
    # Discover a new, valid helper from its body and infer its path type.
    name = "P4-new-path-helper";
    edits = [(addConfigHelper "path_config" "--path") (probe "return repo.path_config(\"core.hooksPath\", default=None)")];
    changes = {
      "core.hooksPath" = {
        type = "path";
      };
    };
  }
  {
    # Drop only the removed CLI override; keep the positive flag.
    name = "P-cli-override-removed";
    edits = [(replace tui "    if args.no_autosquash:\n        return False\n" "")];
    changes = {
      "revise.autoSquash" = {
        overriddenBy = ["--autosquash"];
      };
    };
  }
  {
    # Propagate a changed terminal default through the fallback to the owned key.
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
    # Do not keep the old fallback when the literal default happens to match it.
    name = "P-fallback-removed";
    edits = [(replace tui "default=repo.bool_config(\"rebase.autoSquash\", default=False)" "default=False")];
    changes = {
      "revise.autoSquash" = {
        default = false;
        fallback = null;
      };
    };
  }

  # Untracked reads and conflicting facts
  {
    # Reflective lookup bypasses even the method-reference guard.
    name = "K2-helper-named-through-getattr";
    edits = [(inCommentchar "    getattr(repo, \"bool_config\")(\"core.newKey\", False)\n")];
    fails = ["R6"];
  }
  {
    # Do not pick one branch when a runner's argv has multiple assignments.
    name = "K3-argv-assigned-in-branches";
    edits = [(inCommentchar "    if text:\n        argv = [\"git\", \"log\"]\n    else:\n        argv = [\"git\", \"show\"]\n    run(argv)\n")];
    fails = ["R1"];
  }
  {
    # Read a local list splat instead of rejecting all splatted runner calls.
    name = "K4-readable-splatted-argv";
    edits = [(splattedRunner "\"log\"")];
  }
  {
    # A splat before the subcommand: its list is followed, and a subcommand
    # the tree cannot read ("con" + "fig") is a failure, not a pass.
    name = "K4-splatted-argv";
    edits = [(splattedRunner "\"con\" + \"fig\", \"--get\", \"core.newKey\"")];
    fails = ["R1"];
  }
  {
    # A config-backed variable outside the allowlist must not go unreported.
    name = "K5-unguarded-git-var";
    edits = [(inCommentchar "    repo.git(\"var\", \"GIT_PAGER\")\n")];
    fails = ["R14"];
  }
  {
    # The literal scan must catch "config" in real git argv outside a helper,
    # even when there is no injection flag or unreadable argument.
    name = "K6-config-literal-in-git-argv";
    edits = [(probe "return repo.git(\"config\", \"--get\", \"core.newKey\")")];
    fails = ["R1"];
  }
  {
    # The flag alone does not prove that the helper accepts only Git's canonical true.
    name = "P-bool-helper-semantics";
    edits = [(replace odb "return self.git(\"config\", \"--get\", \"--bool\", config) == b\"true\"" "return self.git(\"config\", \"--get\", \"--bool\", config) in (b\"true\", b\"yes\")")];
    fails = ["R5"];
  }
  {
    # Reject disagreement between reads of the same spelling, not just case conflicts.
    name = "P-conflicting-defaults";
    edits = [(probe "return repo.bool_config(\"commit.verbose\", default=True)")];
    fails = ["R7"];
  }
  {
    # Recognize a config input that has no config helper or git argv at all.
    name = "P-env-config-injection";
    edits = [(probe "import os\n    os.environ[\"GIT_CONFIG_PARAMETERS\"] = \"x\"")];
    fails = ["R13"];
  }
  {
    # Even a non-config subcommand can supply config through `-c`.
    name = "P-git-dash-c";
    edits = [(probe "return repo.git(\"-c\", \"core.editor=vi\", \"commit\")")];
    fails = ["R1"];
  }
  {
    # Taking a method reference bypasses direct helper-call recognition.
    name = "P-helper-as-value";
    edits = [(probe "get = repo.bool_config\n    return get(\"revise.x\", default=False)")];
    fails = ["R6"];
  }
  {
    # A literal key does not make an opaque keyword splat safe.
    name = "P-helper-kwargs";
    edits = [(probe "kw = {\"default\": False}\n    return repo.bool_config(\"revise.autoSquash\", **kw)")];
    fails = ["R2"];
  }
  {
    # A missing value no longer returns the declared default if the handler raises.
    name = "P-helper-raises-instead";
    edits = [(replace odb "            return int(self.git(\"config\", \"--get\", \"--int\", config))\n        except CalledProcessError:\n            return default" "            return int(self.git(\"config\", \"--get\", \"--int\", config))\n        except CalledProcessError:\n            raise")];
    fails = ["R5"];
  }
  {
    # Do not silently resolve or skip a helper key supplied as a variable.
    name = "P-key-from-constant";
    edits = [(probe "KEY = \"revise.x\"\n    return repo.bool_config(KEY, default=False)")];
    fails = ["R2"];
  }
  {
    # An otherwise valid new helper cannot use an unknown type flag.
    name = "P-new-helper-unknown-type";
    edits = [(addConfigHelper "color_config" "--type=color")];
    fails = ["R3"];
  }
  {
    # An override must resolve to an argument in the real CLI parser.
    name = "P-override-by-unknown-arg";
    edits = [(replace tui "    if args.no_autosquash:\n" "    if args.no_autosquash or args.bogus_flag:\n")];
    fails = ["R11"];
  }
  {
    # Do not ignore a method call whose argv is an unreadable attribute splat.
    name = "P-starred-unresolvable";
    edits = [(probe "return repo.git(*repo.extra_argv)")];
    fails = ["R1"];
  }
  {
    # Reject case variants of a Git key rather than emitting two entries.
    name = "P-two-spellings";
    edits = [(probe "return repo.bool_config(\"revise.autosquash\", default=False)")];
    fails = ["R7"];
  }

  # Key mentions
  {
    # Report an unread key mention even though it appears only in CLI help.
    name = "P-key-literal-in-help";
    edits = [(replace tui "help=\"force disable revise.autoSquash behaviour\"" "help=\"force disable revise.autoSquash and revise.squashMode behaviour\"")];
    deadKeysAdd = ["revise.squashMode"];
  }
]
