{world, ...}: {
  charlie-zero-registration-extension =
    world.facetLib.charlie.marker
    == "extension-discovered"
    && world.registry.facetMock.entries.charlie.payload == "charlie";
}
