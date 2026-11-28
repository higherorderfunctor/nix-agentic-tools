# The same package file claims either an unrelated key or package A's key.
{
  fixtureClaims,
  fixturePackageBKey,
  ...
}: {
  config.ai = fixtureClaims fixturePackageBKey "package-b";
}
