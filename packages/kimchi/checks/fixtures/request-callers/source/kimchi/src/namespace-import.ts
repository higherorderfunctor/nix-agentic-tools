// Fails dropping namespace imports: the module member makes a caller edge.
import * as requests from "./callers.js";
export function namespaceImport() {
  requests.helper();
}
