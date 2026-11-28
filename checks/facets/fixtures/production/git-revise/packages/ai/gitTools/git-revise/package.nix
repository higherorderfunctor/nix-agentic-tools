{
  inputs,
  writeText,
}:
(writeText "facet-git-revise" "").overrideAttrs (_: {
  # The owner overlay reads this value from the generated package in prev.
  passthru.fixtureSentinel = inputs.fixture.sentinel;
})
