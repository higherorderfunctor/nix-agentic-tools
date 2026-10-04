export default function observe(pi: any) {
  const counts = { agent_start: 0, input: 0, model_requests: 0 };
  pi.on("session_start", (_event: any, ctx: any) => {
    const workflow = pi
      .getCommands()
      .filter((command: any) => command.name === "workflow");
    console.error("E2E_COMMANDS " + JSON.stringify(workflow));
    const notify = ctx.ui.notify.bind(ctx.ui);
    ctx.ui.notify = (message: string, level: string) => {
      console.error("E2E_NOTIFY " + JSON.stringify({ message, level }));
      return notify(message, level);
    };
  });
  pi.on("input", () => {
    counts.input++;
    return { action: "handled" };
  });
  pi.on("agent_start", () => {
    counts.agent_start++;
  });
  pi.on("before_provider_request", () => {
    counts.model_requests++;
    throw new Error("E2E_NO_MODEL_CALLS");
  });
  pi.on("session_shutdown", () =>
    console.error("E2E_COUNTS " + JSON.stringify(counts)),
  );
}
