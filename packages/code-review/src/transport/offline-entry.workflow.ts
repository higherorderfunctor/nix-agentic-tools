import { createTransportWorkflow } from "./kimchi.ts";
// Offline identifier only: never load this entry in a live harness.
export default createTransportWorkflow("pull", {
  roles: { lens: { model_id: "fixture/transport", effort: "high" } },
});
