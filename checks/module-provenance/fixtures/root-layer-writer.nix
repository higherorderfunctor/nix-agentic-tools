# POSITIVE CONTROL for the layer-1 forwarding exemption in ../helpers.nix.
#
# A repo file other than the forwarding helper writes every forwarded root
# option directly. The exemption names the helper's file, so each write must
# still be reported.
{
  config.ai = {
    activation.direct.command = "true";
    claims.path."direct.txt" = ["direct"];
    files."direct.txt".content.text = "direct";
    legacyLedgers = [
      {
        codec = "dir";
        ledger = "materialize/direct.manifest";
        path = ".";
      }
    ];
    services.direct.command = ["/bin/direct"];
  };
}
