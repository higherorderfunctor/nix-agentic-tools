// Fails matching a helper by name without resolving its declaration's file.
function isResourceEnabled(id: string) {
  return id.length > 0;
}
export function shadowed() {
  if (isResourceEnabled("tools.fake")) fetch("https://shadowed.example");
}
