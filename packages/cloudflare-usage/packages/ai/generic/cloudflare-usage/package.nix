{pkgs, ...}:
(pkgs.delegate-routing-content.mkUsageScript "cloudflare-usage"
  [pkgs.curl pkgs.jq pkgs.python3]
  [../../../../src/cloudflare-usage.sh]).overrideAttrs (old: {
  meta =
    (old.meta or {})
    // {
      description = "Read daily Cloudflare Workers AI neurons through CPA";
      mainProgram = "cloudflare-usage";
    };
})
