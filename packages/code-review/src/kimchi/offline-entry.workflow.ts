import { createReviewWorkflow, type Profile, roles } from "./workflow.ts";
// Fixture identifiers only: never load this entry in a live harness.
export const fixtureProfile: Profile = {
  roles: Object.fromEntries(
    roles.map((role) => [
      role,
      { model_id: `fixture/${role}`, effort: "high" },
    ]),
  ) as Profile["roles"],
  limits: { concurrency: 6, max_waves: 3 },
};
export default createReviewWorkflow(fixtureProfile);
