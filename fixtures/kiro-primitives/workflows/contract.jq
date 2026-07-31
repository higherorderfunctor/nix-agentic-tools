# contract.jq — the Kiro CLI v3 workflow-definition contract, as an executable
# checker.
#
# WHY THIS EXISTS. The engine ships a `validate_workflow` tool that would answer
# every question below authoritatively. It is unreachable: R-workflow-4 shows the
# whole workflow tool pool is registered only when `workflowsEnabled` resolves
# true, and R-workflow-2 shows the only way to make that happen is to pre-seed a
# persisted session and re-enter it. So the tool cannot vet the definition you
# need in order to have something worth seeding. This file breaks that circle by
# re-implementing the contract from the bundle read recorded in
# `../records/workflow-surface.md`.
#
# It is therefore a MODEL of the engine, not the engine. Two consequences worth
# stating out loud:
#
#   - It can be WRONG in the engine's favour (something it accepts that the
#     engine rejects). The mitigation is that every rule below is traceable to a
#     quoted schema or function in the record, not to inference.
#   - It is deliberately STRICTER than the engine in several places, because the
#     engine's leniency here is silent and expensive. Each such rule is tagged
#     POLICY with the failure it prevents. Rules tagged ENGINE mirror a check the
#     engine itself performs.
#
# CONTRACT SOURCE: KAS 2.15.1
# (2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc),
# read 2026-07-29. Re-derive against `records/workflow-surface.md` R-workflow-5
# and R-workflow-6 if the CLI has moved.
#
# INPUT:  one workflow definition (whatever `jq` parsed out of the file).
# OUTPUT: one JSON array of diagnostics, each
#           { severity: "error" | "warn", code, where, message }
#         sorted errors-first then by location. An empty array means the
#         definition satisfies every rule below.
#
# The driver (`validate-workflow.sh`) owns file handling, the exit code, and the
# two diagnostics this file cannot produce: `E-JSON-PARSE` (a file that does not
# parse never reaches jq's filter) and `E-FILE-MISSING` (a file that is not there
# never reaches the parse gate either). Both are declared in the basis table
# below so the corpus-completeness check still sees a single registry.

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

def err($code; $where; $message):
  {severity: "error", code: $code, where: $where, message: $message};

def wrn($code; $where; $message):
  {severity: "warn", code: $code, where: $where, message: $message};

# ---------------------------------------------------------------------------
# The contract, as data
#
# Enum members and field names are sorted alphabetically here. The engine
# declares them in a different order (`["step","sequence","repeat",...]`), and
# the difference is inert: every use below is a membership test.
# ---------------------------------------------------------------------------

def enum_completion_signal: ["error", "need_input", "success"];
def enum_join_policy: ["all", "allSettled", "any"];
def enum_node_type: ["parallel", "repeat", "sequence", "step", "watch"];
def enum_on_max_iterations: ["abort", "continue", "pause"];

# ENGINE. `MAX_REPEAT_ITERATIONS = 1e3` in the covenant package;
# `DEFAULT_MAX_NESTING_DEPTH = 8` and `DEFAULT_MAX_STEP_NODES = 20` in
# src/workflow/validate.ts.
def limit_max_nesting_depth: 8;
def limit_max_repeat_iterations: 1000;
def limit_max_step_nodes: 20;

# ENGINE. The 5-member discriminated union on `type`. `step`'s "at least one of
# prompt/input" rule is a refinement, not a required field, so it is checked
# separately and both keys appear as optional here.
def node_field_spec:
  {
    "parallel": {
      "required": ["branches", "id", "joinPolicy", "type"],
      "optional": []
    },
    "repeat": {
      "required": ["id", "maxIterations", "onMaxIterations", "steps", "type"],
      "optional": ["stopCondition", "stopWhen"]
    },
    "sequence": {
      "required": ["id", "steps", "type"],
      "optional": []
    },
    "step": {
      "required": ["agent", "id", "type"],
      "optional": [
        "artifacts",
        "captureOutput",
        "completion",
        "effortLevel",
        "input",
        "modelId",
        "prompt"
      ]
    },
    "watch": {
      "required": ["handler", "id", "type"],
      "optional": ["config", "idleTimeoutSec"]
    }
  };

# ENGINE. `planRevision` is listed optional so it is recognized rather than
# reported as an unknown key — but authoring it is refused by a POLICY rule
# below.
def workflow_field_spec:
  {
    "required": ["name", "steps"],
    "optional": [
      "description",
      "effortLevel",
      "inputs",
      "modelId",
      "planRevision"
    ]
  };

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def contains_any($needles):
  . as $s | any($needles[]; . as $n | $s | contains($n));

# POLICY on the empty case. The engine's `z.string()` accepts "", and an empty
# id, agent or name is accepted all the way to a run that then fails somewhere
# far from the cause.
def expect_string($where; $label):
  if type != "string"
  then [err("E-TYPE"; $where; $label + " must be a JSON string (got " + type + ")")]
  elif . == ""
  then [err("E-EMPTY-STRING"; $where; $label + " must not be the empty string")]
  else []
  end;

def expect_object($where; $label):
  if type != "object"
  then [err("E-TYPE"; $where; $label + " must be a JSON object (got " + type + ")")]
  else []
  end;

# ---------------------------------------------------------------------------
# TRAP 1 — `jsonPath` is not JSONPath
#
# ENGINE (from src/workflow/stop-condition.ts):
#
#   function walkJsonPath(root, jsonPath) {
#     const segments = jsonPath.split(".").filter((s) => s.length > 0);
#     let cursor = root;
#     for (const segment of segments) {
#       if (cursor === null || typeof cursor !== "object") return void 0;
#       cursor = cursor[segment];
#     }
#     return cursor;
#   }
#
# `split(".")` then repeated property access. There is no JSONPath engine
# anywhere near it. So "$.drained" asks for a property literally named "$",
# gets `undefined`, `deepEqual(undefined, true)` is false, and the repeat never
# stops — it spins to `maxIterations`. The failure is a silent non-termination,
# which is why this is a hard rejection rather than a warning.
# ---------------------------------------------------------------------------

def jsonpath_errors($where):
  if type != "string"
  then [err("E-TYPE"; $where; "jsonPath must be a JSON string (got " + type + ")")]
  elif . == ""
  then [err("E-JSONPATH-SYNTAX"; $where; "jsonPath is empty; name the property to read, e.g. \"drained\"")]
  else
    (if startswith("$")
     then [err("E-JSONPATH-SYNTAX"; $where;
               "jsonPath " + tojson + " starts with '$', but jsonPath is NOT JSONPath: "
               + "the engine splits on '.' and does repeated property access, so '$' is "
               + "read as a property literally named '$', resolves to undefined, and the "
               + "loop never terminates. Drop the '$.' prefix — write \"drained\", not \"$.drained\".")]
     else []
     end)
    + (if contains_any(["[", "]", "*"])
       then [err("E-JSONPATH-SYNTAX"; $where;
                 "jsonPath " + tojson + " contains a bracket or wildcard. Only '.'-separated "
                 + "property names are supported; there is no index, slice, filter or "
                 + "recursive-descent syntax. A filter expression would also need brackets, "
                 + "so this rule catches that class too.")]
       else []
       end)
    + (if (split(".") | any(. == ""))
       then [err("E-JSONPATH-SYNTAX"; $where;
                 "jsonPath " + tojson + " has an empty '.'-separated segment. The engine "
                 + "filters empty segments out, so a leading dot, a trailing dot and '..' "
                 + "are all silently ignored rather than meaning anything — the path you "
                 + "wrote is not the path that runs.")]
       else []
       end)
  end;

# ---------------------------------------------------------------------------
# TRAP 3 — `fileCheck.path` resolves against the WORKSPACE ROOT
#
# ENGINE (src/workflow/stop-condition.ts, evaluateFileCheck): the path is
# template-substituted, joined onto `context.workspacePath` when relative, and
# then containment-checked against the workspace roots — a path outside them
# THROWS `FileCheckPathOutsideWorkspaceError`. It is never resolved against the
# process cwd.
#
# The templated case is POLICY, and it is the subtle one. The load-time
# validator's containment loop (src/workflow/validate.ts,
# `containmentErrorsForPaths`) opens with:
#
#   const firstRef = effectivePath.indexOf("{{");
#   if (firstRef === 0) { continue; }
#
# A path that still begins with a template marker after input substitution
# SKIPS containment validation entirely. So a templated path is not "checked
# later" — it is unchecked at author time and only throws at evaluation time,
# mid-run, from inside a loop. The bundled `ralph` recipe does exactly this
# (`path: "{{prd_path}}"`), so this rule is stricter than the vendor's own
# recipes on purpose: a fixture must be verifiable before it is launched.
# ---------------------------------------------------------------------------

def file_check_path_errors($where):
  if type != "string"
  then [err("E-TYPE"; $where; "fileCheck.path must be a JSON string (got " + type + ")")]
  elif . == ""
  then [err("E-FILE-CHECK-PATH-EMPTY"; $where; "fileCheck.path is empty; it must be a plain relative path inside the workspace")]
  else
    (if (contains("{{") or contains("}}"))
     then [err("E-FILE-CHECK-PATH-TEMPLATE"; $where;
               "fileCheck.path " + tojson + " is templated. The load-time containment check "
               + "SKIPS any path still beginning with '{{' after input substitution, so a "
               + "templated path is never validated at author time and can only fail at "
               + "evaluation time, mid-loop. Write the literal relative path instead.")]
     else []
     end)
    + (if startswith("/")
       then [err("E-FILE-CHECK-PATH-ABSOLUTE"; $where;
                 "fileCheck.path " + tojson + " is absolute. It would have to sit inside a "
                 + "workspace root to pass containment; a plain relative path is resolved "
                 + "against the workspace root by construction and cannot drift.")]
       else []
       end)
    + (if startswith("~")
       then [err("E-FILE-CHECK-PATH-TILDE"; $where;
                 "fileCheck.path " + tojson + " starts with '~'. Nothing expands it: the "
                 + "engine hands the string to node's path.join, so this names a directory "
                 + "literally called '~' inside the workspace.")]
       else []
       end)
    + (if (split("/") | any(. == ".."))
       then [err("E-FILE-CHECK-PATH-ESCAPE"; $where;
                 "fileCheck.path " + tojson + " contains a '..' segment. Resolution is "
                 + "against the workspace root, and a path that escapes it throws "
                 + "FileCheckPathOutsideWorkspaceError when the condition is evaluated.")]
       else []
       end)
  end;

# ---------------------------------------------------------------------------
# TRAP 2 — an array-valued `fileCheck.value` means "any of these candidates"
#
# ENGINE (src/workflow/stop-condition.ts, evaluateFileCheck):
#
#   if (Array.isArray(fileCheck.value)) {
#     return fileCheck.value.some((candidate) => deepEqual(resolvedValue, candidate));
#   }
#   return deepEqual(resolvedValue, fileCheck.value);
#
# So `value: [true]` does NOT mean "the property equals the array [true]" — it
# means "the property equals true". An author who wanted to match a literal
# array gets a match on any single element instead, and an author who wrote a
# one-element array as a stylistic habit gets semantics they never chose.
# Rejected rather than warned, because both readings are plausible and the
# author's intent is unrecoverable from the definition.
#
# `value` is also required here as POLICY: the engine declares it
# `z.unknown()`, which in Zod accepts `undefined`, so omitting the key parses
# fine and the check becomes "stop when this property is ABSENT".
# ---------------------------------------------------------------------------

def file_check_field_note:
  {
    "jsonPath": "name the property to compare, '.'-separated (see E-JSONPATH-SYNTAX)",
    "path": "a plain relative path, resolved against the workspace root",
    "value": "the value to compare against — required by POLICY, because the engine's z.unknown() accepts undefined and an omitted key silently becomes \"stop when the property is absent\""
  };

def file_check_errors($where):
  if type != "object"
  then [err("E-TYPE"; $where; "fileCheck must be a JSON object (got " + type + ")")]
  else
    keys as $ks
    | ((["jsonPath", "path", "value"] - $ks)
       | map(err("E-FILE-CHECK-FIELD"; $where;
                 "fileCheck is missing required field '" + . + "': " + file_check_field_note[.])))
    + (($ks - ["jsonPath", "path", "value"])
       | map(err("E-FILE-CHECK-FIELD"; $where;
                 "fileCheck has unknown field '" + . + "'; the schema is exactly "
                 + "{path, jsonPath, value} and an unknown key is silently dropped, "
                 + "so a mis-cased one reads as a missing one")))
    + (if has("jsonPath") then (.jsonPath | jsonpath_errors($where + ".jsonPath")) else [] end)
    + (if has("path") then (.path | file_check_path_errors($where + ".path")) else [] end)
    + (if (has("value") and (.value | type) == "array")
       then [err("E-FILE-CHECK-VALUE-ARRAY"; $where + ".value";
                 "fileCheck.value is an array. The engine reads an array as "
                 + "\"any of these candidates\" (`value.some(c => deepEqual(resolved, c))`), "
                 + "NOT as \"the property equals this array\". Write the single value.")]
       else []
       end)
  end;

# ---------------------------------------------------------------------------
# The stop-condition object (R-workflow-6)
# ---------------------------------------------------------------------------

def stop_condition_errors($where):
  if type != "object"
  then [err("E-TYPE"; $where; "a stop condition must be a JSON object (got " + type + ")")]
  else
    keys as $ks
    | .completionSignal as $signal
    | (($ks - ["completionSignal", "containsText", "fileCheck"])
       | map(err("E-STOP-CONDITION-FIELD"; $where;
                 "stop condition has unknown field '" + . + "'; the schema is exactly "
                 + "{containsText?, fileCheck?, completionSignal?}")))
    + (if ((["completionSignal", "containsText", "fileCheck"] - $ks) | length) == 3
       then [err("E-STOP-CONDITION-EMPTY"; $where;
                 "stop condition defines none of containsText, fileCheck or "
                 + "completionSignal; the schema refinement requires at least one")]
       else []
       end)
    + (if has("completionSignal")
       then
         (if ($signal | IN(enum_completion_signal[]) | not)
          then [err("E-ENUM-COMPLETION-SIGNAL"; $where + ".completionSignal";
                    "completionSignal is " + ($signal | tojson) + "; allowed values are "
                    + (enum_completion_signal | join(", ")))]
          else []
          end)
       else []
       end)
    + (if has("containsText") then (.containsText | expect_string($where + ".containsText"; "containsText")) else [] end)
    + (if has("fileCheck") then (.fileCheck | file_check_errors($where + ".fileCheck")) else [] end)
    + (if (has("completionSignal") and (has("containsText") or has("fileCheck")))
       then [wrn("W-STOP-CONDITION-SIGNAL-FIRST"; $where;
                 "this stop condition sets completionSignal alongside another field. "
                 + "`evaluateStopCondition` tests completionSignal FIRST and returns on a "
                 + "match, so the file check or text match may never be read.")]
       else []
       end)
  end;

# ---------------------------------------------------------------------------
# `stopWhen` — a two-form mini-dialect, and it cannot express a file check
#
# ENGINE (src/workflow/stop-condition.ts, parseStopWhen). Exactly two forms:
#
#   "{{expr}} contains <literal>"   — template first, ' contains ' with a
#                                     single space each side, non-empty literal
#   "<watchId>.terminal"            — watchId non-empty, no dots, no whitespace
#
# There is no file-check form. That is why the drain uses `stopCondition`: a
# drain terminates on durable state in a file, and `stopWhen` cannot read one.
# ---------------------------------------------------------------------------

def stop_when_errors($where; $watch_ids):
  if type != "string"
  then [err("E-TYPE"; $where; "stopWhen must be a JSON string (got " + type + ")")]
  elif startswith("{{")
  then
    (if (contains("}}") | not)
     then [err("E-STOP-WHEN-SYNTAX"; $where; "the '{{' template is never closed with '}}'")]
     else
       (index("}}") + 2) as $close
       | .[$close:] as $rem
       | if ($rem | startswith(" contains ") | not)
         then [err("E-STOP-WHEN-SYNTAX"; $where;
                   "expected ' contains ' (a single space on each side) immediately after "
                   + "the '{{...}}' template")]
         elif ($rem | .[10:] | length) == 0
         then [err("E-STOP-WHEN-SYNTAX"; $where; "the text after ' contains ' is empty; provide the literal to match")]
         else []
         end
     end)
  elif contains(" contains ")
  then [err("E-STOP-WHEN-SYNTAX"; $where;
            "the left side of ' contains ' must be a '{{...}}' template, "
            + "e.g. '{{step1.output}} contains DONE'")]
  elif (contains("{{") or contains("}}"))
  then [err("E-STOP-WHEN-SYNTAX"; $where;
            "a '{{...}}' template is only allowed at the very start, in the "
            + "'{{expr}} contains <text>' form")]
  elif (endswith(".terminal") | not)
  then [err("E-STOP-WHEN-SYNTAX"; $where;
            "expected '<watchId>.terminal' or '{{expr}} contains <text>'. Note there is no "
            + "file-check form: use stopCondition.fileCheck to terminate on file state.")]
  else
    .[0:(length - 9)] as $wid
    | if ($wid == "" or ($wid | contains(".")) or ($wid | test("\\s")))
      then [err("E-STOP-WHEN-SYNTAX"; $where;
                "the watch id before '.terminal' must be a single non-empty identifier "
                + "without dots or whitespace (got " + ($wid | tojson) + ")")]
      elif ($watch_ids | index($wid)) == null
      then [err("E-STOP-WHEN-WATCH-ID"; $where;
                "stopWhen references watch id " + ($wid | tojson)
                + " but no watch node with that id exists in this workflow")]
      else []
      end
  end;

# ---------------------------------------------------------------------------
# Per-node-type checks
# ---------------------------------------------------------------------------

# POLICY on emptiness. An empty container is structurally valid and does
# nothing: an empty `repeat.steps` spins to maxIterations doing no work, and an
# empty `parallel.branches` joins immediately.
def container_errors($where; $key):
  if (has($key) | not)
  then []
  elif (.[$key] | type) != "array"
  then [err("E-TYPE"; $where + "." + $key; $key + " must be a JSON array (got " + (.[$key] | type) + ")")]
  elif (.[$key] | length) == 0
  then [err("E-CONTAINER-EMPTY"; $where + "." + $key; $key + " is empty; the node would run nothing")]
  else []
  end;

def step_node_errors($where):
  (if ((has("prompt") | not) and (has("input") | not))
   then [err("E-STEP-NO-PROMPT-OR-INPUT"; $where;
             "a 'step' node must define at least one of prompt or input "
             + "(schema refinement: \"StepNode requires at least one of prompt or input\")")]
   else []
   end)
  + (if has("agent") then (.agent | expect_string($where + ".agent"; "agent")) else [] end)
  + (if has("prompt") then (.prompt | expect_string($where + ".prompt"; "prompt")) else [] end)
  + (if has("input") then (.input | expect_string($where + ".input"; "input")) else [] end)
  + (if has("modelId") then (.modelId | expect_string($where + ".modelId"; "modelId")) else [] end)
  + (if has("effortLevel") then (.effortLevel | expect_string($where + ".effortLevel"; "effortLevel")) else [] end)
  + (if has("captureOutput")
     then
       (if (.captureOutput | type) != "boolean"
        then [err("E-TYPE"; $where + ".captureOutput"; "captureOutput must be a JSON boolean (got " + (.captureOutput | type) + ")")]
        else []
        end)
     else []
     end)
  + (if has("artifacts")
     then
       (.artifacts as $a
        | if ($a | type) != "object"
          then [err("E-TYPE"; $where + ".artifacts"; "artifacts must be a JSON object (got " + ($a | type) + ")")]
          else
            ($a | to_entries
             | map(select((.value | type) != "string")
                   | err("E-TYPE"; $where + ".artifacts[" + (.key | tojson) + "]";
                         "artifacts is record(string); this value is a " + (.value | type))))
          end)
     else []
     end)
  + (if has("completion") then (.completion | stop_condition_errors($where + ".completion")) else [] end);

def repeat_node_errors($where; $watch_ids):
  .maxIterations as $iters
  | .onMaxIterations as $on_max
  | has("stopCondition") as $has_cond
  | has("stopWhen") as $has_when
  | (if has("maxIterations")
     then
       (if ($iters | type) != "number"
        then [err("E-TYPE"; $where + ".maxIterations"; "maxIterations must be a JSON number (got " + ($iters | type) + ")")]
        elif $iters != ($iters | floor)
        then [err("E-MAX-ITERATIONS-RANGE"; $where + ".maxIterations"; "maxIterations must be an integer (got " + ($iters | tojson) + ")")]
        elif $iters < 1
        then [err("E-MAX-ITERATIONS-RANGE"; $where + ".maxIterations"; "maxIterations must be positive (got " + ($iters | tojson) + ")")]
        elif $iters > limit_max_repeat_iterations
        then [err("E-MAX-ITERATIONS-RANGE"; $where + ".maxIterations";
                  "maxIterations " + ($iters | tojson) + " exceeds MAX_REPEAT_ITERATIONS="
                  + (limit_max_repeat_iterations | tostring))]
        else []
        end)
     else []
     end)
  + (if has("onMaxIterations")
     then
       (if ($on_max | IN(enum_on_max_iterations[]) | not)
        then [err("E-ENUM-ON-MAX-ITERATIONS"; $where + ".onMaxIterations";
                  "onMaxIterations is " + ($on_max | tojson) + "; allowed values are "
                  + (enum_on_max_iterations | join(", ")))]
        elif $on_max == "continue"
        then [wrn("W-ON-MAX-ITERATIONS-CONTINUE"; $where + ".onMaxIterations";
                  "onMaxIterations \"continue\" marks the repeat COMPLETED on exhaustion, "
                  + "which is indistinguishable from a genuine drain — an unfinished shard "
                  + "would score as success. Prefer \"abort\".")]
        elif $on_max == "pause"
        then [wrn("W-ON-MAX-ITERATIONS-PAUSE"; $where + ".onMaxIterations";
                  "onMaxIterations \"pause\" is a state you cannot leave: resuming grants no "
                  + "further iterations (the loop re-derives its counter from the children "
                  + "already created, which already equals maxIterations) and a paused run "
                  + "cannot be retried. Prefer \"abort\".")]
        else []
        end)
     else []
     end)
  + (if ($has_cond and $has_when)
     then [err("E-STOP-FORM-BOTH"; $where;
               "a 'repeat' node must not define both stopCondition and stopWhen "
               + "(\"RepeatNode allows at most one of stopCondition or stopWhen\")")]
     elif (($has_cond or $has_when) | not)
     then [err("E-STOP-FORM-NEITHER"; $where;
               "a 'repeat' node defines NEITHER stopCondition nor stopWhen. POLICY: the "
               + "engine ACCEPTS this — its only stop-form message is \"must not define "
               + "both\", and there is no \"requires one of\" rule anywhere in the "
               + "validator — so the loop runs silently to maxIterations with nothing "
               + "reporting why it stopped. Declare a stop form.")]
     else []
     end)
  + (if has("stopCondition") then (.stopCondition | stop_condition_errors($where + ".stopCondition")) else [] end)
  + (if has("stopWhen") then (.stopWhen | stop_when_errors($where + ".stopWhen"; $watch_ids)) else [] end);

def parallel_node_errors($where):
  .joinPolicy as $join
  | (if has("joinPolicy")
     then
       (if ($join | IN(enum_join_policy[]) | not)
        then [err("E-ENUM-JOIN-POLICY"; $where + ".joinPolicy";
                  "joinPolicy is " + ($join | tojson) + "; allowed values are "
                  + (enum_join_policy | join(", ")))]
        elif $join == "all"
        then [wrn("W-JOIN-POLICY-ALL"; $where + ".joinPolicy";
                  "joinPolicy \"all\" aborts every sibling branch on the first branch "
                  + "FAILURE, not only on completion. For independent branches that is "
                  + "contagious: one poisoned item cancels the others. Prefer "
                  + "\"allSettled\", which contains a failure and still reports the run as "
                  + "failed.")]
        elif $join == "any"
        then [wrn("W-JOIN-POLICY-ANY"; $where + ".joinPolicy";
                  "joinPolicy \"any\" aborts every sibling the moment one branch completes "
                  + "(`joinAny` calls abort() on each other controller), destroying "
                  + "in-flight work. It cancels; it does not orphan.")]
        else []
        end)
     else []
     end)
  + container_errors($where; "branches");

def watch_node_errors($where):
  .idleTimeoutSec as $idle
  | (if has("handler") then (.handler | expect_string($where + ".handler"; "handler")) else [] end)
  + (if has("config") then (.config | expect_object($where + ".config"; "config")) else [] end)
  + (if has("idleTimeoutSec")
     then
       (if ($idle | type) != "number"
        then [err("E-TYPE"; $where + ".idleTimeoutSec"; "idleTimeoutSec must be a JSON number (got " + ($idle | type) + ")")]
        elif $idle <= 0
        then [err("E-IDLE-TIMEOUT-RANGE"; $where + ".idleTimeoutSec"; "idleTimeoutSec must be positive (got " + ($idle | tojson) + ")")]
        else []
        end)
     else []
     end);

# ---------------------------------------------------------------------------
# One flattened node record -> its diagnostics
#
# Depth matches the engine's own accounting: `walkNode` rejects when
# `lineage.length > limits.maxNestingDepth`, and a top-level node has a lineage
# of length 1. So depth here is 1-based and the ceiling is inclusive.
# ---------------------------------------------------------------------------

def node_errors($watch_ids):
  .where as $w
  | .node as $n
  | .depth as $d
  | (if $d > limit_max_nesting_depth
     then [err("E-NESTING-DEPTH"; $w;
               "node sits at nesting depth " + ($d | tostring) + ", exceeding the maximum of "
               + (limit_max_nesting_depth | tostring))]
     else []
     end)
  + (if ($n | type) != "object"
     then [err("E-NODE-TYPE"; $w; "a node must be a JSON object (got " + ($n | type) + ")")]
     else
       ($n | .type) as $t
       | if ($t | type) != "string"
         then [err("E-NODE-TYPE"; $w;
                   "node has no string 'type' discriminator; it is the field the union keys "
                   + "on, so without it nothing else can be checked")]
         elif ($t | IN(enum_node_type[]) | not)
         then [err("E-NODE-TYPE"; $w;
                   "unknown node type " + ($t | tojson) + "; the union has exactly "
                   + (enum_node_type | join(", ")))]
         else
           (node_field_spec | .[$t]) as $spec
           | ($n | keys) as $ks
           | (($spec | .required) - $ks
              | map(err("E-NODE-REQUIRED"; $w; "'" + $t + "' node is missing required field '" + . + "'")))
           + ($ks - ($spec | .required) - ($spec | .optional)
              | map(err("E-NODE-FIELD-UNKNOWN"; $w;
                        "'" + $t + "' node has unknown field '" + . + "'; the discriminated "
                        + "union ignores it, so a mis-cased or misplaced key reads as absent")))
           + (if ($n | has("id")) then ($n | .id | expect_string($w + ".id"; "id")) else [] end)
           + (if $t == "step" then ($n | step_node_errors($w))
              elif $t == "sequence" then ($n | container_errors($w; "steps"))
              elif $t == "repeat" then ($n | (repeat_node_errors($w; $watch_ids) + container_errors($w; "steps")))
              elif $t == "parallel" then ($n | parallel_node_errors($w))
              else ($n | watch_node_errors($w))
              end)
         end
     end);

# ---------------------------------------------------------------------------
# Tree flattening
#
# One pass produces {node, where, depth} for every node, after which every
# per-node rule is a plain map and every whole-workflow rule (duplicate ids,
# step-node count, watch-id resolution) is a plain fold. Descent stops at a
# node whose `type` is missing or unknown, which is correct: its children's
# container key is unknowable, and the node itself is already reported.
# ---------------------------------------------------------------------------

def flatten_nodes($where; $depth):
  [{node: ., where: $where, depth: $depth}]
  + (if type != "object"
     then []
     else
       (if (.type == "repeat" or .type == "sequence") then "steps"
        elif .type == "parallel" then "branches"
        else null
        end) as $k
       | if $k == null
         then []
         else
           .[$k] as $kids
           | if ($kids | type) != "array"
             then []
             else
               ($kids | to_entries
                | map(.key as $i
                      | .value
                      | flatten_nodes($where + "." + $k + "[" + ($i | tostring) + "]"; $depth + 1))
                | add // [])
             end
         end
     end);

# ---------------------------------------------------------------------------
# Enclosing schema
# ---------------------------------------------------------------------------

def workflow_errors:
  if type != "object"
  then [err("E-WORKFLOW-TYPE"; "workflow"; "the workflow definition must be a JSON object (got " + type + ")")]
  else
    (workflow_field_spec) as $spec
    | keys as $ks
    | .inputs as $inputs
    | (($spec | .required) - $ks
       | map(err("E-WORKFLOW-REQUIRED"; "workflow"; "the workflow is missing required field '" + . + "'")))
    + ($ks - ($spec | .required) - ($spec | .optional)
       | map(err("E-WORKFLOW-FIELD-UNKNOWN"; "workflow";
                 "unknown top-level field '" + . + "'; the schema is "
                 + (($spec | .required) + ($spec | .optional) | sort | join(", ")))))
    + (if has("name") then (.name | expect_string("workflow.name"; "name")) else [] end)
    + (if has("description") then (.description | expect_string("workflow.description"; "description")) else [] end)
    + (if has("effortLevel") then (.effortLevel | expect_string("workflow.effortLevel"; "effortLevel")) else [] end)
    + (if has("modelId") then (.modelId | expect_string("workflow.modelId"; "modelId")) else [] end)
    + (if has("planRevision")
       then [err("E-WORKFLOW-PLAN-REVISION"; "workflow.planRevision";
                 "planRevision must not be authored. POLICY: the engine stamps it 0 at "
                 + "creation and increments it on each applied replace_remaining update, "
                 + "writing state and definition as a pair carrying the same revision. The "
                 + "resume path compares the two and refuses to resume on a mismatch, so a "
                 + "hand-written value can make a healthy run unresumable.")]
       else []
       end)
    + (if has("inputs")
       then
         (if ($inputs | type) != "object"
          then [err("E-TYPE"; "workflow.inputs"; "inputs must be a JSON object (got " + ($inputs | type) + ")")]
          else
            ($inputs | to_entries
             | map(select((.value | type) != "string")
                   | err("E-INPUTS-NOT-STRING"; "workflow.inputs[" + (.key | tojson) + "]";
                         "input '" + .key + "' has a " + (.value | type) + " value "
                         + (.value | tojson) + "; `inputs` is record(string), so EVERY value "
                         + "must be a JSON string — a numeric cap is \"5\", not 5")))
          end)
       else []
       end)
    + (if has("steps")
       then
         (if (.steps | type) != "array"
          then [err("E-TYPE"; "workflow.steps"; "steps must be a JSON array (got " + (.steps | type) + ")")]
          elif (.steps | length) == 0
          then [err("E-CONTAINER-EMPTY"; "workflow.steps"; "steps is empty; the workflow would run nothing")]
          else []
          end)
       else []
       end)
  end;

# ---------------------------------------------------------------------------
# Whole-workflow rules
#
# `maxStepNodes` counts `step` nodes STRUCTURALLY — once per authored node,
# independent of how many iterations a repeat performs or how many branches run
# at once. The engine increments `state.stepNodeCount` once per `walkStep`, and
# `walkStep` is reached once per node in a single tree walk.
# ---------------------------------------------------------------------------

def global_errors($flat):
  [$flat[] | select((.node | type) == "object") | .node] as $nodes
  | [$nodes[] | .id | select(type == "string")] as $ids
  | ([$nodes[] | select(.type == "step")] | length) as $step_count
  | ($ids | group_by(.) | map(select(length > 1) | .[0]) | sort
     | map(err("E-NODE-DUPLICATE-ID"; "workflow";
               "duplicate node id '" + . + "'; ids must be unique across the whole workflow")))
  + (if $step_count > limit_max_step_nodes
     then [err("E-STEP-NODES-MAX"; "workflow";
               "the workflow declares " + ($step_count | tostring) + " step nodes, exceeding "
               + "maxStepNodes=" + (limit_max_step_nodes | tostring)
               + ". The count is structural: one per authored step node, regardless of "
               + "iterations or branch runtime.")]
     else []
     end);

# ---------------------------------------------------------------------------
# Rule basis
#
# Every diagnostic carries WHOSE rule it is, because the answer changes what an
# author should do about it:
#
#   engine      the engine performs an equivalent check. Violating it is
#               rejected at load, or throws at evaluation time, whatever this
#               validator says.
#   policy      the engine ACCEPTS this. The rule exists because the engine's
#               acceptance is SILENT and the consequence is expensive — a loop
#               that never terminates, a stop condition that can never fire, a
#               key that reads as absent. Every one of the four documented
#               authoring traps lands here, which is exactly why they are traps:
#               nothing rejects them.
#   mechanical  the file could not be read as a workflow at all.
#
# Anything absent from this table surfaces as "unclassified", which
# self-test-validate.sh treats as a failure — so a new rule cannot be added
# without saying whose it is.
# ---------------------------------------------------------------------------

def code_basis:
  {
    "E-CONTAINER-EMPTY": "policy",
    "E-EMPTY-STRING": "policy",
    "E-ENUM-COMPLETION-SIGNAL": "engine",
    "E-ENUM-JOIN-POLICY": "engine",
    "E-ENUM-ON-MAX-ITERATIONS": "engine",
    "E-FILE-CHECK-FIELD": "policy",
    "E-FILE-CHECK-PATH-ABSOLUTE": "policy",
    "E-FILE-CHECK-PATH-EMPTY": "policy",
    "E-FILE-CHECK-PATH-ESCAPE": "engine",
    "E-FILE-CHECK-PATH-TEMPLATE": "policy",
    "E-FILE-CHECK-PATH-TILDE": "policy",
    "E-FILE-CHECK-VALUE-ARRAY": "policy",
    "E-FILE-MISSING": "mechanical",
    "E-IDLE-TIMEOUT-RANGE": "engine",
    "E-INPUTS-NOT-STRING": "engine",
    "E-JSON-PARSE": "mechanical",
    "E-JSONPATH-SYNTAX": "policy",
    "E-MAX-ITERATIONS-RANGE": "engine",
    "E-NESTING-DEPTH": "engine",
    "E-NODE-DUPLICATE-ID": "engine",
    "E-NODE-FIELD-UNKNOWN": "policy",
    "E-NODE-REQUIRED": "engine",
    "E-NODE-TYPE": "engine",
    "E-STEP-NO-PROMPT-OR-INPUT": "engine",
    "E-STEP-NODES-MAX": "engine",
    "E-STOP-CONDITION-EMPTY": "engine",
    "E-STOP-CONDITION-FIELD": "policy",
    "E-STOP-FORM-BOTH": "engine",
    "E-STOP-FORM-NEITHER": "policy",
    "E-STOP-WHEN-SYNTAX": "engine",
    "E-STOP-WHEN-WATCH-ID": "engine",
    "E-TYPE": "engine",
    "E-WORKFLOW-FIELD-UNKNOWN": "policy",
    "E-WORKFLOW-PLAN-REVISION": "policy",
    "E-WORKFLOW-REQUIRED": "engine",
    "E-WORKFLOW-TYPE": "engine",
    "W-JOIN-POLICY-ALL": "policy",
    "W-JOIN-POLICY-ANY": "policy",
    "W-ON-MAX-ITERATIONS-CONTINUE": "policy",
    "W-ON-MAX-ITERATIONS-PAUSE": "policy",
    "W-STOP-CONDITION-SIGNAL-FIRST": "policy"
  };

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

. as $wf
| (if (($wf | type) == "object" and (($wf | .steps | type) == "array"))
   then
     [$wf | .steps | to_entries[]
      | .key as $i
      | .value
      | flatten_nodes("workflow.steps[" + ($i | tostring) + "]"; 1)]
     | add // []
   else []
   end) as $flat
| [$flat[] | select((.node | type) == "object") | select(.node.type == "watch") | .node.id | select(type == "string")] as $watch_ids
| (code_basis) as $basis
| ($wf | workflow_errors)
+ ($flat | map(node_errors($watch_ids)) | add // [])
+ global_errors($flat)
| map(. + {basis: ($basis[.code] // "unclassified")})
| sort_by(.severity, .where, .code, .message)
