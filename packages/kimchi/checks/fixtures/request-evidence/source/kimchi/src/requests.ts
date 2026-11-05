import { loadConfig } from "./config.js";
import { SEARCH_ID } from "./resources/ids.js";
import { isResourceEnabled as enabledResource } from "./resources/store.js";

// Fails a callee-name match and a missed imported resource id.
export function positive() {
  const enabled = enabledResource(SEARCH_ID);
  if (enabled) {
    fetch("https://positive.example");
  }
}

// Fails reversed condition polarity: source truthy, condition false.
export function negatedReturn() {
  const enabled = enabledResource(SEARCH_ID);
  if (!enabled) return;
  fetch("https://negated.example");
}

// Fails assuming every return guard requires source truthy.
export function positiveReturn() {
  const enabled = enabledResource(SEARCH_ID);
  if (enabled) return;
  fetch("https://falsy.example");
}

// Fails missing the throw edge or a local environment alias.
export function environmentThrow() {
  const token = process.env.TOKEN;
  if (!token) throw new Error("no token");
  fetch("https://environment.example");
}

// Fails missing parsed-config aliases and a nested property path.
export function configGuard() {
  const config = loadConfig();
  const telemetry = config.telemetry;
  const enabled = telemetry.enabled;
  if (enabled) {
    fetch("https://config.example");
  }
}

// Fails treating an earlier sibling branch as a dominating condition.
export function sibling() {
  if (process.env.SIBLING) {
    console.log("a");
  } else {
    console.log("b");
  }
  fetch("https://sibling.example");
}

// Fails assigning one request's guard to every request in its function.
export function separateCalls() {
  if (process.env.ONLY_FIRST) {
    fetch("https://first.example");
  }
  fetch("https://second.example");
}

// Fails calling absence of evidence "always enabled" in the report.
export function unguarded() {
  fetch("https://unguarded.example");
}

// Fails inventing a name or polarity for unsupported tests.
export function unresolved(name: string) {
  if (process.env[name]) fetch("https://computed.example");
  if (process.env.COMPARE === "1") fetch("https://comparison.example");
}

// Fails allowing an outer condition to guard a callback's own function.
export function callback() {
  if (process.env.CALLBACK) {
    setTimeout(() => fetch("https://callback.example"), 0);
  }
}

// Fails treating a caught throw as excluding the subsequent request.
export function caughtThrow() {
  try {
    if (!process.env.CAUGHT) throw new Error("caught");
  } catch {}
  fetch("https://caught.example");
}

// Fails treating possible value flow through a phi as necessary evidence.
export function alternatives(other: boolean) {
  const enabled = other ? process.env.POSSIBLE : true;
  if (enabled) fetch("https://alternatives.example");
}

// Fails classifying arbitrary objects as parsed config.
export function unrelatedConfig() {
  const config = { enabled: true };
  if (config.enabled) fetch("https://unrelated.example");
}

// Fails accepting a property read whose receiver only possibly is config/env.
export function ambiguousReceivers(other: boolean) {
  const config = other ? loadConfig() : { enabled: true };
  if (config.enabled) fetch("https://config-alternative.example");
  const env = other ? process.env : { TOKEN: "yes" };
  if (env.TOKEN) fetch("https://env-alternative.example");
}

// Fails resolving a mutable resource id from its original initializer.
export function mutableId() {
  let id = SEARCH_ID;
  id = process.env.RESOURCE_ID || "tools.other";
  if (enabledResource(id)) fetch("https://mutable.example");
}

// Fails dropping typed const aliases because their declarations are local sources.
export function typedAlias() {
  const enabled: boolean = enabledResource(SEARCH_ID);
  if (enabled) {
    fetch("https://typed-alias.example");
  }
}

// Fails treating flow from the right operand of && as a strict alias.
export function logicalAnd(other: boolean) {
  const enabled = other && process.env.AND;
  if (enabled) fetch("https://logical-and.example");
}
