# Parsed as source, never evaluated: intentionally noncompliant builders.
{
  external,
  externalFlag,
  externalHeader,
  pkgs,
}: let
  flags = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
  header = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
in {
  applicationDefaultFlags = pkgs.writeShellApplication {
    name = "application-default-flags";
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :
      echo bad
    '';
  };
  applicationGood = pkgs.writeShellApplication {
    bashOptions = flags;
    name = "application-good";
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :
      echo good
    '';
  };
  applicationInherited = pkgs.writeShellApplication {
    inherit (external) bashOptions;
    name = "application-inherited";
    text = "echo unknown";
  };
  applicationMissingFlag = pkgs.writeShellApplication {
    bashOptions = ["errexit" "nounset" "pipefail"];
    name = "application-missing-flag";
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :
      echo bad
    '';
  };
  applicationMissingShopt = pkgs.writeShellApplication {
    bashOptions = flags;
    name = "application-missing-shopt";
    text = "echo bad";
  };
  applicationPartialFlags = pkgs.writeShellApplication {
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" externalFlag];
    name = "application-partial-flags";
    text = "shopt -s inherit_errexit 2>/dev/null || :";
  };
  applicationRecursiveGood = pkgs.writeShellApplication rec {
    bashOptions = flags;
    name = "application-recursive-good";
    text = "shopt -s inherit_errexit 2>/dev/null || :";
  };
  applicationRecursiveInherited = pkgs.writeShellApplication rec {
    inherit (external) bashOptions;
    name = "application-recursive-inherited";
    text = "shopt -s inherit_errexit 2>/dev/null || :";
  };
  applicationRecursiveMissing = pkgs.writeShellApplication rec {
    bashOptions = flags;
    name = "application-recursive-missing";
    text = "echo bad";
  };
  applicationUnknown = pkgs.writeShellApplication {
    bashOptions = external;
    name = "application-unknown";
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :
      echo unknown
    '';
  };
  good = pkgs.writeShellScript "good" ''
    ${header}
    echo good
  '';
  goodBin = pkgs.writeShellScriptBin "good-bin" (header + "echo good");
  goodWithOpaqueBody = pkgs.writeShellScript "good-with-opaque-body" ''
    ${header}
    ${external}
  '';
  missing = pkgs.writeShellScript "missing" "echo bad";
  missingShopt = pkgs.writeShellScriptBin "missing-shopt" ''
    set -euETo pipefail
    echo bad
  '';
  partialHeader = pkgs.writeShellScript "partial-header" ''
    ${externalHeader}
    echo unknown
  '';
  unknown = pkgs.writeShellScript "unknown" (external "script");
}
