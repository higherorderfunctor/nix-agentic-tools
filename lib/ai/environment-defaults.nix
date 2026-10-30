# Launcher defaults preserve uppercase and lowercase ambient variables, even empty ones.
# makeWrapper's --set-default uses an empty-as-unset test instead.
{lib}: environment:
lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: ''
    if [ -z "''${${name}+x}" ] && [ -z "''${${lib.toLower name}+x}" ]; then
      export ${name}=${lib.escapeShellArg value}
    fi
  '')
  environment)
