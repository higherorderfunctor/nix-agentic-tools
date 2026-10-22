function installPasteInterceptor() {
  process.env.IN_FUNCTION = "1";
}
async function main() {
  await Promise.resolve();
}
installPasteInterceptor();
void main();
process.env.LATE_WRITE = "1";
process.env.AWAITED = await Promise.resolve("1");
