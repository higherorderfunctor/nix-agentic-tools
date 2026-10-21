/**
 * @name Network request targets
 * @description Each constant URL (a string with a scheme) whose value
 *              influences the URL of a modeled client request, with the file
 *              of the request. Influence is taint flow: the constant may be
 *              the whole URL or any part of a concatenation or template,
 *              leading or not, through variables, properties, calls and
 *              returns. It is not proof that the constant's host is the
 *              request's destination.
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
