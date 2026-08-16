{
  inputs,
  lib,
  runCommandLocal,
}: let
  sentinel = inputs.fixture.sentinel;
in
  runCommandLocal "facet-git-revise" {
    passthru.fixtureSentinel = sentinel;
  } ''
    mkdir -p "$out"
    printf '%s\n' ${lib.escapeShellArg sentinel} > "$out/marker"
  ''
