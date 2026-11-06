// Fails line keys: these are two request occurrences on the same line.
export function columns(flag: boolean) {
  return flag ? fetch("https://a") : fetch("https://b");
}
