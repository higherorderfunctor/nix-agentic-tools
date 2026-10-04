# Exact source fragments for extensions supplied separately through settings.
# Keep one list: the package patch and its source contract consume these rows.
[
  {
    factoryLine = "\t\t\t\t{ id: \"extensions.workflows\", factory: piWorkflowsExtension },";
    id = "extensions.workflows";
    importLine = ''import piWorkflowsExtension from "@kimchi-dev/kimchi-workflows/extension"'';
    resourceDefinition = builtins.concatStringsSep "\n" [
      "\t{"
      "\t\tid: \"extensions.workflows\","
      "\t\tkind: \"extensions\","
      "\t\tlabel: \"Kimchi Workflows\","
      "\t\tdescription: \"Enable the /workflow command for authoring and running TypeScript workflows.\","
      "\t\tdefaultEnabled: false,"
      "\t\trestartRequired: true,"
      "\t},"
      ""
    ];
  }
]
