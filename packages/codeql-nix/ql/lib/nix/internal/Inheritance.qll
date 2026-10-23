/** Attribute copying contributes declarations; only bare inheritance also uses a name. */
private import nix.internal.RawBridge
private import nix.internal.StaticScopes

module Inheritance {
  predicate declaration(RawBridge::Node frame, RawBridge::Node token) {
    exists(RawBridge::Node clause |
      token = RawBridge::inheritedToken(clause) and
      exists(RawBridge::binderName(token)) and
      StaticScopes::declarationFrame(RawBridge::container(clause), frame))
  }
  predicate occurrence(RawBridge::Node token) {
    exists(RawBridge::Node clause | clause.getKind() = "Inherit" and
      token = RawBridge::inheritedToken(clause))
  }
  predicate excludesFrame(RawBridge::Node token, RawBridge::Node frame) {
    occurrence(token) and declaration(frame, token)
  }
}
