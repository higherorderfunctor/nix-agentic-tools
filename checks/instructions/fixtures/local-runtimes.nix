# instructions-drift exercises the operator's local opt-ins independently of HM.
{
  ai = {
    claude.enable = true;
    codex.enable = true;
    kimchi.enable = true;
    kiro.cli.enable = true;
    programs = {
      peer-communication.enable = true;
      semble.enable = true;
    };
  };
}
