/** Literal with membership and conditional fallback; no value evaluation. */
private import nix.internal.RawBridge

module ImplicitScopes {
  private predicate contains(RawBridge::Node frame, RawBridge::Node use) {
    RawBridge::withBody(frame) = RawBridge::parent*(use)
  }
  private predicate member(RawBridge::Node environment, RawBridge::Node token) {
    exists(RawBridge::Node binding |
      RawBridge::container(binding) = environment and token = RawBridge::pathToken(binding, 0))
    or exists(RawBridge::Node clause |
      RawBridge::container(clause) = environment and token = RawBridge::inheritedToken(clause))
  }
  private predicate known(RawBridge::Node frame, string name, RawBridge::Node token) {
    RawBridge::setExpression(RawBridge::withEnvironment(frame)) and
    member(RawBridge::withEnvironment(frame), token) and RawBridge::binderName(token) = name and
    not exists(RawBridge::Node earlier |
      member(RawBridge::withEnvironment(frame), earlier) and RawBridge::binderName(earlier) = name and
      RawBridge::precedes(earlier, token))
  }
  bindingset[frame]
  private predicate unknown(RawBridge::Node frame) {
    not RawBridge::setExpression(RawBridge::withEnvironment(frame))
    or exists(RawBridge::Node token |
      member(RawBridge::withEnvironment(frame), token) and not exists(RawBridge::binderName(token)))
  }
  /** A stable, source-qualified provider identity, also used for located declarations. */
  string identity(RawBridge::Node token) {
    member(_, token) and result = "with:" + token.getLocation().getFile().getAbsolutePath() + ":" +
      token.getLocation().getStartLine().toString() + ":" + token.getLocation().getStartColumn().toString()
  }
  predicate resolve(RawBridge::Node use, string name, RawBridge::Node token, string certainty) {
    exists(RawBridge::Node frame |
      contains(frame, use) and known(frame, name, token) and
      not exists(RawBridge::Node inner |
        contains(inner, use) and frame = RawBridge::parent+(inner) and known(inner, name, _)) and
      (exists(RawBridge::Node inner |
         contains(inner, use) and frame = RawBridge::parent+(inner) and unknown(inner)) and certainty = "may"
       or not exists(RawBridge::Node inner |
         contains(inner, use) and frame = RawBridge::parent+(inner) and unknown(inner)) and certainty = "must"))
  }
}
