import type { Register } from "claude-code";

// Probe mod for the delegate map (claude:dmu_plugin_model). After the main
// turn completes it calls $.model.fork and $.model.complete once each; the
// mock sees PLUGIN_FORK_PROBE_5151 / PLUGIN_COMPLETE_PROBE_5252 and records
// each request's model, effort and tools. Results go to the debug log.
let done = false;
export const register: Register = (on) => {
  on("turn.complete", async ($, e, next) => {
    if (!done && e.agentId === undefined) {
      done = true;
      const f = await $.model.fork({
        prompt: "PLUGIN_FORK_PROBE_5151 one line",
      });
      $.ui.log(
        `DMU_FORK ${JSON.stringify({ ok: f.isAnswered, r: f.isAnswered ? f.text : f.reason })}`,
      );
      const c = await $.model.complete({
        model: "haiku",
        prompt: "PLUGIN_COMPLETE_PROBE_5252 one line",
        effort: "low",
        timeoutMs: 20000,
      });
      $.ui.log(
        `DMU_COMPLETE ${JSON.stringify({ ok: c.isAnswered, r: c.isAnswered ? c.text : c.reason })}`,
      );
    }
    return next(e);
  });
};
