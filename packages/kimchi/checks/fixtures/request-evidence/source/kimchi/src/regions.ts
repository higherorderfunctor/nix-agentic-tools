// Omitted fields, empty strings and a hard-coded default fail the exact diff.
export const REGIONS = {
  eu: { id: "eu", label: "Europe", webAppUrl: "https://eu.example" },
  local: { id: "local", label: "Local", webAppUrl: "" },
} as const satisfies Record<string, object>;
export const DEFAULT_REGION = "local";
