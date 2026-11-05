// Fails name matching: renamed imports and const aliases retain binding identity.
import { helper as renamed } from "./callers.js";

const alias = renamed;
export function imported() {
  alias();
}
