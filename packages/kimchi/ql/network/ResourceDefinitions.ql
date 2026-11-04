/**
 * @name Resource definitions
 * @description Static resource ids, defaults and restart declarations.
 * @kind table
 * @id nix-agentic-tools/kimchi-resource-definitions
 */
import javascript
import DeclarationValues

private string booleanField(ObjectExpr definition, string name) {
  result = definition.getPropertyByName(name).getInit().(BooleanLiteral).getBoolValue().toString()
  or
  not exists(definition.getPropertyByName(name)) and result = "absent"
  or
  exists(definition.getPropertyByName(name)) and
  not definition.getPropertyByName(name).getInit() instanceof BooleanLiteral and result = "unresolved"
}

from ObjectExpr definition, string id
where
  definition = exportedInitializer("src/resources/definitions.ts", "STATIC_RESOURCE_DEFINITIONS").(ArrayExpr).getAnElement() and
  (id = literalString(definition.getPropertyByName("id").getInit()) or
   not exists(literalString(definition.getPropertyByName("id").getInit())) and id = "<unresolved>")
select id, booleanField(definition, "defaultEnabled") as defaultEnabled,
  booleanField(definition, "restartRequired") as restartRequired,
  "src/resources/definitions.ts" as file, definition.getLocation().getStartLine() as line
