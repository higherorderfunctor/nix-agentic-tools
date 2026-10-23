/** Module-system facts; missing positions/priorities are -1 and missing paths are empty. */
extensible predicate evalSource(string source, string status, string error, float wallSeconds,
  float peakMb, string rowCounts);
extensible predicate evalOption(string source, string path, string type, string typeDescription,
  int highestPrio, boolean isDefined, boolean internal, boolean readOnly, string visible,
  boolean hasDefault, boolean hasApply, boolean generated, string instance);
extensible predicate evalOptionDecl(string source, string path, string file, int line, int column);
extensible predicate evalDefinition(string source, string path, string file, int line, int column,
  string moduleFile, int priority, boolean active, int conditionCount, boolean wins,
  boolean aliasForward, string kind);
extensible predicate evalModule(string source, string file, string key, string importedBy,
  boolean disabled);
extensible predicate evalValue(string source, string path, string kind, string value);
