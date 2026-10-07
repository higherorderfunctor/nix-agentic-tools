import { appendFileSync } from "node:fs";
import * as pca from "@earendil-works/pi-coding-agent";

// Prompt-map probe extension (user scope, auto-discovered from <harness>/extensions/).
// Logs one line per load to $HOME/spx-load.jsonl (which process loaded it, from which executable,
// whether the wrapper's env reached it, and whether the virtual module exposes system-prompt blocks),
// appends SP_EXT_BAS in before_agent_start and SP_EXT_BPR to the wire system message in
// before_provider_request.
export default function (pi: any) {
  try {
    const keys = Object.keys(pca).filter((k) => /block|systemprompt/i.test(k));
    const row = {
      pid: process.pid,
      argv: process.argv.slice(1, 4),
      execPath: process.execPath,
      wrapperEnv: process.env.SP_WRAPPER_ENV ?? null,
      createSystemPromptBlocks: typeof (pca as any).createSystemPromptBlocks,
      keys,
    };
    appendFileSync(
      `${process.env.HOME}/spx-load.jsonl`,
      `${JSON.stringify(row)}\n`,
    );
  } catch {}
  pi.on("before_agent_start", (event: any) => ({
    systemPrompt: `${event.systemPrompt}\n\nSP_EXT_BAS`,
  }));
  pi.on("before_provider_request", (event: any) => {
    const p = event.payload;
    const m = p?.messages?.find(
      (x: any) => x.role === "system" || x.role === "developer",
    );
    if (!m) return undefined;
    if (typeof m.content === "string") m.content += "\n\nSP_EXT_BPR";
    else if (Array.isArray(m.content))
      m.content.push({ type: "text", text: "\n\nSP_EXT_BPR" });
    return p;
  });
}
