# Passing control: another package may claim different keys in every pool.
{fixtureClaims, ...}: {
  config.ai = fixtureClaims "distinct" "package-distinct";
}
