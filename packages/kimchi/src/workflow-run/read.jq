# cspell:words gsub ltrimstr
# Mirrors workflows 0.0.9 run-status.ts, step-state.ts and node-path.ts.
# Loop indices collapse; foreach indices remain distinct under concurrency.
def key:
  if type != "string" or (test("^[^/#@]+([#@][0-9]+)?(/[^/#@]+([#@][0-9]+)?)*$") | not)
  then error("invalid step path") else gsub("#[0-9]+"; "") end;
def set_state($event; $state):
  ($event.path | key) as $key | .steps[$key] = {event: $event, state: $state};
def close_open($state):
  .steps |= map_values(if .state == "in_progress" or .state == "blocked" then .state = $state else . end);

if length == 0 or any(.[]; type != "object" or (.type | type) != "string")
then error("empty or malformed event log") else . end
| . as $events
| ([$events[].runId] | unique) as $ids
| if ($ids | length) != 1 or ($ids[0] | type) != "string" then error("missing or mixed run IDs") else . end
| reduce $events[] as $e ({arms: {}, started: false, steps: {}, terminal: null};
    if $e.type == "run-started" then .started = true
    elif (["step-started", "step-retry", "agent-steer", "answers-provided", "interaction-provided"] | index($e.type)) != null then set_state($e; "in_progress")
    elif $e.type == "step-completed" then set_state($e; "completed")
    elif $e.type == "step-failed" then set_state($e; "crashed")
    elif (["questionnaire-asked", "interaction-requested"] | index($e.type)) != null then set_state($e; "blocked")
    elif $e.type == "branch-arm" then
      if $e.taken then .arms[($e.path | key)] = true | set_state($e; "in_progress") else set_state($e; "skipped") end
    elif $e.type == "node-completed" then
      if .arms[($e.path | key)] then set_state($e; "completed") else . end
    elif $e.type == "step-cancelled" then set_state($e; "cancelled")
    elif $e.type == "run-crashed" or $e.type == "run-cancelled" then
      ($e.type | ltrimstr("run-")) as $state
      | (if $e.path then set_state($e; $state) else . end) | close_open($state) | .terminal = $e
    elif $e.type == "run-completed" then .terminal = $e
    else . end)
| . as $derived
| (if .started == false then "failed"
   elif any(.steps[]; .state == "in_progress") then "in_progress"
   elif any(.steps[]; .state == "blocked") then "blocked"
   elif .terminal != null then (.terminal.type | ltrimstr("run-"))
   elif any(.steps[]; .state == "crashed") then "crashed"
   else "in_progress" end) as $status
| {eventsFile: $eventsFile, runId: $ids[0], sessionDir: $sessionDir, status: $status}
  + (if $status == "completed" then {output: $derived.terminal.output}
     elif $status == "blocked" then
       {error: {message: "waiting for human input", requests: [$derived.steps[] | select(.state == "blocked") | .event | del(.conversation)]}}
     elif $status == "in_progress" then {error: "child exited with unfinished work (failed/abandoned)"}
     elif $status == "failed" then {error: "record has no run-started event"}
     elif $status == "cancelled" then {error: $derived.terminal}
     else {error: ($derived.terminal.error // $derived.terminal.reason // "workflow stopped without an error payload")} end)
