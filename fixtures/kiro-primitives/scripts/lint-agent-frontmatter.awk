# Front-matter checks for a single markdown agent profile.
#
# Driven by lint-probes.sh. Reads one .md profile and writes tab-separated
# records on stdout:
#
#   finding <code> <message>     one detected defect
#   meta    <field> <value>      a value the driver needs (name, dispatchKind)
#
# WHY AWK AND NOT A YAML PARSER: there is no YAML library on the path here, and
# the checks that matter are all lexical anyway. Front matter is parsed by the
# engine with js-yaml's CORE schema, so the hazards are "what does this text
# become", not "what does the document mean" — `yes` becoming the STRING "yes"
# rather than a boolean is precisely a lexical fact. A parser would also hide
# the two cases this must catch before parsing: a block with zero keys, and a
# block that never closes.
#
# Deliberately POSIX awk: no GNU-only builtins, no regular expression as the
# record separator.

function finding(code, msg) {
  printf "finding\t%s\t%s\n", code, msg
}

function meta(field, value) {
  printf "meta\t%s\t%s\n", field, value
}

# Strip an unquoted YAML trailing comment, then surrounding whitespace. YAML only
# starts a comment at ` #`, so a `#` with no leading space is data.
function clean_value(v) {
  sub(/[ \t]+#.*$/, "", v)
  sub(/^[ \t]+/, "", v)
  sub(/[ \t]+$/, "", v)
  return v
}

function is_quoted(v) {
  return (v ~ /^".*"$/ || v ~ /^'.*'$/)
}

# Count the leading whitespace without leaning on match() and its side-effect
# globals: copy, strip, subtract.
function indent_of(line, stripped) {
  stripped = line
  sub(/^[ \t]*/, "", stripped)
  return length(line) - length(stripped)
}

# The YAML 1.1 pseudo-booleans, enumerated rather than case-folded.
#
# Enumerating is not laziness avoidance, it is more accurate: YAML 1.1 accepted
# exactly these spellings, so `yEs` was never a boolean anywhere and folding case
# would report it as one. js-yaml's CORE schema accepts none of them — each
# silently becomes a string, and in a boolean-typed field that is a type error
# that drops the WHOLE profile.
function is_pseudo_boolean(v) {
  return (v ~ /^(y|Y|yes|Yes|YES|n|N|no|No|NO|on|On|ON|off|Off|OFF)$/)
}

BEGIN {
  state = "pre"
  keys = 0
  closed = 0
  awaiting_hooks_value = 0
}

{
  # Tolerate CRLF input rather than mis-reporting the `---` fence as absent.
  sub(/\r$/, "")
}

NR == 1 {
  if ($0 != "---") {
    finding("agent-frontmatter-missing", "line 1 is not a `---` fence; a .md profile with no front-matter block throws at load and the profile is DROPPED")
    exit
  }
  state = "fm"
  next
}

state == "fm" {
  if ($0 == "---") {
    if (awaiting_hooks_value) {
      finding("agent-hooks-not-array", "`hooks:` is the last key and has no value; v3 requires an ARRAY of hook documents")
      awaiting_hooks_value = 0
    }
    state = "body"
    closed = 1
    next
  }

  if ($0 == "...") {
    finding("agent-frontmatter-multi-document", "`...` ends a YAML document inside the front-matter block; exactly one document per block is supported")
    next
  }

  if ($0 ~ /^[ \t]*$/) {
    next
  }

  if ($0 ~ /^[ \t]*#/) {
    next
  }

  # A `key:` line. Indentation decides whether it is top level.
  if ($0 ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_.-]*[ \t]*:/) {
    keys++
    indent_len = indent_of($0)
    key = $0
    sub(/^[ \t]*/, "", key)
    sub(/[ \t]*:.*$/, "", key)
    value = $0
    sub(/^[ \t]*[A-Za-z_][A-Za-z0-9_.-]*[ \t]*:/, "", value)
    value = clean_value(value)

    # A mapping under `hooks:` resolves the pending question below.
    if (awaiting_hooks_value && indent_len > 0) {
      finding("agent-hooks-object-shaped", "`hooks:` is followed by a mapping key `" key "`: v2's hooks is an OBJECT and v3's is an ARRAY, so this fails validation and drops the WHOLE profile")
      awaiting_hooks_value = 0
    } else if (awaiting_hooks_value && indent_len == 0) {
      finding("agent-hooks-not-array", "`hooks:` has no value; v3 requires an ARRAY, and a null there fails the optional-array schema and drops the whole profile")
      awaiting_hooks_value = 0
    }

    if (!is_quoted(value) && is_pseudo_boolean(value)) {
      finding("agent-pseudo-boolean", "`" key ": " value "` is NOT a boolean under js-yaml's CORE schema, it is the string \"" value "\"; write true or false literally")
    }

    if (indent_len == 0) {
      if (key == "name") {
        meta("name", value)
      }
      if (key == "dispatchKind") {
        meta("dispatchKind", value)
      }
      if (key == "includeMcpJson" || key == "includePowers") {
        if (value != "true" && value != "false") {
          finding("agent-strict-boolean", "`" key "` is boolean-typed; `" value "` is not the literal true or false, so the profile fails validation and is dropped")
        }
      }
      if (key == "hooks") {
        if (substr(value, 1, 1) == "[") {
          # Flow sequence: the v3 shape.
        } else if (substr(value, 1, 1) == "{") {
          finding("agent-hooks-object-shaped", "`hooks: {...}` is the v2 OBJECT shape; v3 requires an ARRAY and a mapping here drops the WHOLE profile")
        } else if (value == "") {
          awaiting_hooks_value = 1
        } else {
          finding("agent-hooks-not-array", "`hooks: " value "` is a scalar; v3 requires an ARRAY of hook documents")
        }
      }
    }
    next
  }

  # A block-sequence entry.
  if ($0 ~ /^[ \t]*-([ \t]|$)/) {
    if (awaiting_hooks_value) {
      awaiting_hooks_value = 0
    }
    value = $0
    sub(/^[ \t]*-[ \t]*/, "", value)
    value = clean_value(value)
    if (value != "" && !is_quoted(value) && is_pseudo_boolean(value)) {
      finding("agent-pseudo-boolean", "the sequence entry `" value "` is NOT a boolean under js-yaml's CORE schema, it is the string \"" value "\"; write true or false literally")
    }
    next
  }
}

END {
  if (NR == 0) {
    finding("agent-frontmatter-missing", "the file is empty; a .md profile needs a front-matter block that parses to at least one key")
    exit
  }
  if (state == "fm" && !closed) {
    finding("agent-frontmatter-unterminated", "the front-matter block opened at line 1 is never closed by a `---` fence")
  }
  if (awaiting_hooks_value) {
    finding("agent-hooks-not-array", "`hooks:` has no value; v3 requires an ARRAY of hook documents")
  }
  if (closed && keys == 0) {
    finding("agent-frontmatter-empty", "the front-matter block parses to ZERO keys; that throws at load and the profile is DROPPED, including the comment-only and blank cases")
  }
}
