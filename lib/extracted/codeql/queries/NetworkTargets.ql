/**
 * @name Network request targets
 * @description Each constant URL that reaches the URL of a modeled client
 *              request, with the file of the request. The URL may arrive
 *              whole or as the leading part of a concatenation or template,
 *              through variables, properties, calls and returns.
 * @kind table
 * @id nat/network-targets
 */

import javascript

module UrlConstantConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node node) {
    node.getStringValue().regexpMatch("(?i)[a-z][a-z0-9+.-]*://.+")
  }

  predicate isSink(DataFlow::Node node) { node = any(ClientRequest request).getUrl() }
}

module UrlConstantFlow = TaintTracking::Global<UrlConstantConfig>;

from ClientRequest request, DataFlow::Node constant, string url
where
  UrlConstantFlow::flow(constant, request.getUrl()) and
  url = constant.getStringValue()
select url, request.getFile().getRelativePath() as file
