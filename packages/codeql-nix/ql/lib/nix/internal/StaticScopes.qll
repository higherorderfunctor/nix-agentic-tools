/** Static attribute composition and its source-order-selected recursive frames. */
private import nix.internal.RawBridge

module StaticScopes {
  bindingset[prefix, name]
  private string append(string prefix, string name) {
    result = prefix + name.length().toString() + ":" + name + ";"
  }
  private string path(RawBridge::Node binding, int index) {
    index = 0 and result = append("", RawBridge::binderName(RawBridge::pathToken(binding, 0)))
    or index > 0 and result = append(path(binding, index - 1),
      RawBridge::binderName(RawBridge::pathToken(binding, index)))
  }
  private int last(RawBridge::Node binding) {
    exists(RawBridge::pathToken(binding, result)) and
    not exists(RawBridge::pathToken(binding, result + 1))
  }
  private predicate mergedInto(RawBridge::Node node, RawBridge::Node binding) {
    RawBridge::setExpression(node) and node = RawBridge::bindingValue(binding) and
    exists(path(binding, last(binding)))
  }
  private predicate placement(RawBridge::Node node, RawBridge::Node root, string prefix) {
    exists(RawBridge::Node binding, string parentPrefix |
      mergedInto(node, binding) and placement(RawBridge::container(binding), root, parentPrefix) and
      prefix = parentPrefix + path(binding, last(binding)))
    or
    (RawBridge::setExpression(node) or node.getKind() = "LetExpression") and
    not mergedInto(node, _) and root = node and prefix = ""
  }
  /** Each static path component contributes a set prefix or a terminal value. */
  private predicate entry(RawBridge::Node root, string key, RawBridge::Node token,
    RawBridge::Node binding, int index) {
    exists(string prefix |
      placement(RawBridge::container(binding), root, prefix) and
      key = prefix + path(binding, index) and token = RawBridge::pathToken(binding, index))
  }
  private predicate first(RawBridge::Node root, string key, RawBridge::Node token,
    RawBridge::Node binding, int index) {
    entry(root, key, token, binding, index) and
    not exists(RawBridge::Node earlier | entry(root, key, earlier, _, _) and RawBridge::precedes(earlier, token))
  }
  private predicate terminal(RawBridge::Node binding, int index) {
    index = last(binding) and not RawBridge::setExpression(RawBridge::bindingValue(binding))
  }
  private predicate conflict(RawBridge::Node root, string key) {
    exists(RawBridge::Node a, RawBridge::Node b, RawBridge::Node ta, RawBridge::Node tb, int i, int j |
      entry(root, key, ta, a, i) and entry(root, key, tb, b, j) and ta != tb and
      (terminal(a, i) or terminal(b, j)))
  }
  /** A merged set takes its recursion flag from its first creation, even an implicit prefix. */
  predicate frame(RawBridge::Node frame, RawBridge::Node root, string prefix) {
    frame.getKind() in ["FunctionExpression", "LetExpression"] and root = frame and prefix = ""
    or placement(frame, root, prefix) and frame.getKind() = "RecAttrsetExpression" and
      (frame = root or exists(RawBridge::Node token, RawBridge::Node binding, int i |
        first(root, prefix, token, binding, i) and i = last(binding) and
        frame = RawBridge::bindingValue(binding)))
  }
  private predicate below(RawBridge::Node node, RawBridge::Node use) {
    node = RawBridge::parent*(use)
  }
  private predicate inValue(RawBridge::Node binding, RawBridge::Node use) {
    below(RawBridge::bindingValue(binding), use)
  }
  private predicate afterSegment(RawBridge::Node binding, int index, RawBridge::Node use) {
    exists(RawBridge::pathToken(binding, index)) and
    (inValue(binding, use) or exists(int later |
      later > index and below(RawBridge::pathToken(binding, later), use)))
  }
  /** Structural scope prefixes do not require the rest of a path to name a declaration. */
  private predicate context(RawBridge::Node use, RawBridge::Node root, string prefix) {
    exists(RawBridge::Node container |
      container = RawBridge::parent+(use) and placement(container, root, prefix))
    or exists(RawBridge::Node binding, int i |
      entry(root, prefix, _, binding, i) and exists(RawBridge::pathToken(binding, i + 1)) and
      afterSegment(binding, i, use))
  }
  predicate contains(RawBridge::Node frame, RawBridge::Node use) {
    frame.getKind() = "FunctionExpression" and frame = RawBridge::parent+(use)
    or exists(RawBridge::Node root, string prefix, string enclosing |
      StaticScopes::frame(frame, root, prefix) and context(use, root, enclosing) and
      enclosing.indexOf(prefix) = 0)
  }
  private predicate unknown(RawBridge::Node binding, int index) {
    exists(RawBridge::pathToken(binding, index)) and
    not exists(RawBridge::binderName(RawBridge::pathToken(binding, index)))
  }
  private predicate computedPrefix(RawBridge::Node binding, RawBridge::Node root, string prefix) {
    exists(int i, string enclosing |
      unknown(binding, i) and not exists(int j | j < i and unknown(binding, j)) and
      placement(RawBridge::container(binding), root, enclosing) and
      (i = 0 and prefix = enclosing or i > 0 and prefix = enclosing + path(binding, i - 1)))
  }
  private predicate computedSet(RawBridge::Node binding) {
    exists(int i | unknown(binding, i) |
      i < last(binding) or RawBridge::setExpression(RawBridge::bindingValue(binding)))
  }
  /** Semantic frame nesting survives merged contributions at different syntax depths. */
  private int nodeDepth(RawBridge::Node node) {
    exists(int enclosing |
      enclosing = count(RawBridge::Node frame | contains(frame, node)) and
      (StaticScopes::frame(node, _, _) and result = 2 * enclosing
       or not StaticScopes::frame(node, _, _) and result = 2 * enclosing - 1))
  }
  private predicate bindsName(RawBridge::Node frame, RawBridge::Node use) {
    exists(RawBridge::Node token |
      binder(frame, token) and RawBridge::binderName(token) = RawBridge::binderName(use))
  }
  /** Unknown membership may insert or change frames within this composition root. */
  int uncertaintyDepth(RawBridge::Node use) {
    exists(RawBridge::Node binding, RawBridge::Node root, string prefix |
      computedPrefix(binding, root, prefix) and
      (exists(int i | unknown(binding, i) and i < last(binding) and afterSegment(binding, i, use))
       or RawBridge::setExpression(RawBridge::bindingValue(binding)) and inValue(binding, use)) and
      (RawBridge::setExpression(RawBridge::bindingValue(binding)) and inValue(binding, use) and
        result = nodeDepth(RawBridge::bindingValue(binding))
       or not (RawBridge::setExpression(RawBridge::bindingValue(binding)) and inValue(binding, use)) and
        (result = nodeDepth(root) or exists(RawBridge::Node frame |
          StaticScopes::frame(frame, root, _) and contains(frame, use) and result = depth(frame)))))
    or exists(RawBridge::Node binding, RawBridge::Node root, string prefix, string enclosing |
      computedPrefix(binding, root, prefix) and context(use, root, enclosing) and
      (computedSet(binding) and enclosing != prefix and enclosing.indexOf(prefix) = 0 and
        (result = nodeDepth(root) or exists(RawBridge::Node frame |
          StaticScopes::frame(frame, root, enclosing) and not bindsName(frame, use) and result = depth(frame)))
       or enclosing = prefix and exists(RawBridge::Node frame |
         placement(frame, root, prefix) and
         frame.getKind() in ["LetExpression", "RecAttrsetExpression"] and
         (StaticScopes::frame(frame, root, prefix) or below(frame, use) and
           exists(RawBridge::Node token, int i | first(root, prefix, token, binding, i))) and
         // A direct computed key is evaluated outside its own recursive set.
         not (frame = RawBridge::container(binding) and
           exists(int i | below(RawBridge::pathToken(binding, i), use))) and
         not bindsName(frame, use) and result = nodeDepth(frame))))
  }

  predicate binder(RawBridge::Node frame, RawBridge::Node token) {
    RawBridge::functionBinder(frame, token)
    or exists(RawBridge::Node root, string prefix, string key |
      StaticScopes::frame(frame, root, prefix) and
      key = append(prefix, RawBridge::binderName(token)) and entry(root, key, token, _, _))
  }
  bindingset[frame, name]
  predicate collides(RawBridge::Node frame, string name) {
    frame.getKind() = "FunctionExpression" and
    count(RawBridge::Node token | RawBridge::functionBinder(frame, token) and
      RawBridge::binderName(token) = name) > 1
    or exists(RawBridge::Node root, string prefix, string key |
      StaticScopes::frame(frame, root, prefix) and conflict(root, key) and
      key.indexOf(append(prefix, name)) = 0)
  }
  int depth(RawBridge::Node frame) {
    StaticScopes::frame(frame, _, _) and result = nodeDepth(frame)
  }
  int pathDepth(RawBridge::Node frame) {
    exists(RawBridge::Node root, string prefix | StaticScopes::frame(frame, root, prefix) |
      result = prefix.length())
  }
}
