/**
 * @name Named functions
 * @description Every named function.
 * @kind problem
 * @problem.severity recommendation
 * @id nix-agentic-tools/named-functions
 */

import javascript

from Function function
where exists(function.getName()) and exists(function.getFile().getRelativePath())
select function, "function " + function.getName()
