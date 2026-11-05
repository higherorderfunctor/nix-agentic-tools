/**
 * @name Region registry
 * @description Exported region fields and the default-region declaration.
 * @kind table
 * @id nix-agentic-tools/kimchi-region-registry
 */
import javascript
import DeclarationValues

private string registryValue(Expr value) {
  result = literalString(value)
  or
  not exists(literalString(value)) and result = "<unresolved>"
}

query predicate defaultRegion(string value, string file, int line) {
  exists(Expr init |
    init = exportedInitializer("src/regions.ts", "DEFAULT_REGION") and
    value = registryValue(init) and file = "src/regions.ts" and
    line = init.getLocation().getStartLine()
  )
}

from Property regionProp, Property fieldProp
where
  regionProp = exportedInitializer("src/regions.ts", "REGIONS").(ObjectExpr).getAProperty() and
  fieldProp = regionProp.getInit().(ObjectExpr).getAProperty()
select regionProp.getName() as region, fieldProp.getName() as field,
  registryValue(fieldProp.getInit()) as value, "src/regions.ts" as file,
  fieldProp.getLocation().getStartLine() as line
