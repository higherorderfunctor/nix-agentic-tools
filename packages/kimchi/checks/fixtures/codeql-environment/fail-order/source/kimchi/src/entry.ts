function installPasteInterceptor() {
  process.env.IN_FUNCTION = "1";
}
async function main() {
  await Promise.resolve();
}
installPasteInterceptor();
void main(); // A call can suspend in its body even without an explicit await here.
process.env.LATE_WRITE = "1";
process.env.AWAITED = await Promise.resolve("1"); // A suspended right-hand side is still a write.
