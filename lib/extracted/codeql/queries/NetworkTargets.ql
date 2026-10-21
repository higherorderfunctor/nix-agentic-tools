/**
 * @name Network request targets
 * @description Each constant URL a modeled client request reaches, with the
 *              file of the request.
 * @kind table
 * @id nat/network-targets
 */

import javascript

from ClientRequest request, string url
where url = request.getUrl().getALocalSource().getStringValue()
select url, request.getFile().getRelativePath() as file
