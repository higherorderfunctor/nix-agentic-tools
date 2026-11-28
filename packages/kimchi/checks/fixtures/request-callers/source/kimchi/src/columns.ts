// Rejects line-only keys and dropping unreferenced exports: both requests need their own enclosing and boundary rows.
export function columns(flag: boolean) {
  return flag ? fetch("https://a") : fetch("https://b");
}
