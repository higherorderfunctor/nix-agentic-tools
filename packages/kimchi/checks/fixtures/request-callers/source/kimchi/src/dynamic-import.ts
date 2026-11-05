// Fails dropping destructured dynamic imports: the renamed binding makes an edge.
export async function dynamicImport() {
  const { helper: renamed } = await import("./callers.js");
  renamed();
}
