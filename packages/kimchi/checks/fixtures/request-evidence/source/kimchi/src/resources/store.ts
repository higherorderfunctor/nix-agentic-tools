export function isResourceEnabled(id: string): boolean {
  return Boolean(process.env[id]);
}
