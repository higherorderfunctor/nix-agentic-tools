# Positive-control package B deliberately claims package A's keys.
{fixtureClaims, ...}: {
  config.ai = fixtureClaims "shared" "package-b";
}
