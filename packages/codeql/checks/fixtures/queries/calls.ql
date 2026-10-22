/**
 * @name Named calls
 * @description Every call with a named callee.
 * @kind problem
 * @problem.severity recommendation
 * @id nix-agentic-tools/named-calls
 */

import Calls

from NamedCall call
select call, "call to " + call.getCalleeName()
