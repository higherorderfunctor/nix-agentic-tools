// Prints every registered tool (with parameter keys, active flag) and slash command at the
// first `input` event (after every session_start handler has run), then swallows the input
// so no model turn happens. Any provider request throws.
export default function observe(pi: any) {
  const dump = () => {
    const active = new Set(pi.getActiveTools());
    const tools = pi.getAllTools().map((t: any) => ({
      name: t.name,
      active: active.has(t.name),
      params: Object.keys(t.parameters?.properties ?? {}),
      source: t.sourceInfo?.source ?? t.sourceInfo?.path ?? null,
    }));
    console.error("INV_TOOLS " + JSON.stringify(tools));
    console.error(
      "INV_COMMANDS " +
        JSON.stringify(
          pi.getCommands().map((c: any) => ({
            name: c.name,
            source: c.sourceInfo?.source ?? null,
          })),
        ),
    );
  };
  pi.on("input", () => {
    dump();
    return { action: "handled" };
  });
  pi.on("before_provider_request", () => {
    throw new Error("INV_NO_MODEL_CALLS");
  });
}
