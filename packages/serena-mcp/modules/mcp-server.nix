_: {
  meta = {
    modes = {
      stdio = "serena start-mcp-server";
    };
    scope = "local";
    tools = [
      "find_referencing_symbols"
      "find_symbol"
      "insert_after_symbol"
    ];
  };

  settingsOptions = {};
  settingsToEnv = _cfg: _mode: {};
  settingsToArgs = _cfg: _mode: [];
}
