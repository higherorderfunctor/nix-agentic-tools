import { SEARCH_ID } from "./ids.js";

// A hard-coded default or an unresolved import changes these expected rows.
export const STATIC_RESOURCE_DEFINITIONS = [
  { id: SEARCH_ID, defaultEnabled: false, restartRequired: true },
  { id: "hooks.local", defaultEnabled: true },
];
