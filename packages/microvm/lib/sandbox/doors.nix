# Guest-visible door endpoints, shared by the factory (mkSandbox) and the
# module-level inference adapter (./inference.nix) so the guest endpoint URL a
# lowered config carries and the netdev that actually serves it cannot drift.
{
  # slirp forwards guest connections to this address; restrict=on drops
  # anything no door names.
  address = "10.0.2.100";
  # Guest-side port of the inference door; the guest endpoint URL names it.
  inference = 8317;
}
