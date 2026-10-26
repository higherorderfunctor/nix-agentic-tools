import { Alert, Stack } from "@mantine/core";
import { useMemo, useState } from "react";
import { demoAsOfUnix, demoView } from "./demo.ts";
import { initialExplorerState } from "./explorer.ts";
import { UsageExplorerView } from "./UsageExplorerView.tsx";

export function DemoUsageExplorer() {
  const [state, setState] = useState(initialExplorerState);
  const result = useMemo(() => demoView(state.selection), [state.selection]);
  return (
    <Stack>
      <Alert color="blue" title="Synthetic demo data">
        Deterministic activity through{" "}
        {new Date(demoAsOfUnix * 1000).toLocaleString()}. Costs are illustrative
        fixture assignments, not provider pricing or live spend.
      </Alert>
      <UsageExplorerView state={state} onChange={setState} {...result} />
    </Stack>
  );
}
