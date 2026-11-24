# CPA and delegate routing consume the same chat offers from the complete Go inventory.
{lib}: let
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  fact = facts.get (facts.load {dir = ../extracted;}).aggregate "opencodeGo";
  selectChat = lib.filterAttrs (_: model: model.type == "chat");
in {
  inherit (fact) monthlyLimits;
  inherit selectChat;
  models = selectChat fact.models;
}
