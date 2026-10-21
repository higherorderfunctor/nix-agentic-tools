/**
 * @name Request-forgery sinks
 * @description Every request-forgery sink, including those from data extensions.
 * @kind problem
 * @problem.severity recommendation
 * @id nix-agentic-tools/request-forgery-sinks
 */

import javascript
import semmle.javascript.security.dataflow.RequestForgeryCustomizations

from RequestForgery::Sink sink
select sink, "request-forgery sink"
