import type { Register } from "claude-code";

// Probe mod for the delegate map. prompt.compose: appends one session section
// (COMPOSE-4242) after what the engine composed. prompt.section: appends a
// SECTION-4343 marker naming each section the engine resolves.
export const register: Register = (on) => {
  on("prompt.compose", async ($, e, next) => {
    const result = await next(e);
    return {
      sections: [
        ...result.sections,
        {
          id: "prompt-mw:tail",
          text: `Compose sentinel: COMPOSE-4242 traits=${e.traits.join(",")}.`,
          scope: "session",
        },
      ],
    };
  });
  on("prompt.section", async ($, e, next) => {
    const result = await next(e);
    if (result.text === null) return result;
    return { text: `${result.text}\n[SECTION-4343 ${e.name}]` };
  });
};
