// Evaluate the pinned server's own direct-option map. The module imports its
// generated siblings, so this must run against the installed bundle, not a
// single source file copied out of it.
//
// Method (the repository ranks CodeQL > eval > AST > regex; see
// dev/fragments/extracted/extraction-method.md): eval. The question is the
// value of one exported object, not a code path, so CodeQL adds nothing. The
// object is assembled from imports, spreads, helper calls and computed
// defaults, so an AST or regex read would have to re-implement that evaluation.
const fail = (message) => {
  throw new Error(message);
};

const isPlainObject = (value) =>
  value !== null &&
  typeof value === "object" &&
  !Array.isArray(value) &&
  Object.getPrototypeOf(value) === Object.prototype;

// JSON values are copied; functions are the only non-JSON value yargs carries
// here and keep both a stable name and their source.
const encode = (value, path) => {
  if (
    value === null ||
    value === false ||
    value === true ||
    typeof value === "string"
  )
    return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) fail(`${path} is not a JSON number`);
    return value;
  }
  if (Array.isArray(value))
    return value.map((item, index) => encode(item, `${path}[${index}]`));
  if (typeof value === "function") {
    return {
      function: {
        name: value.name || "<anonymous>",
        source: String(value),
      },
    };
  }
  if (!isPlainObject(value))
    fail(`${path} has an unknown value shape ${typeof value}`);
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map((key) => [key, encode(value[key], `${path}.${key}`)]),
  );
};

const extract = async (source) => {
  const { mcpOptions } = await import(source);
  if (!isPlainObject(mcpOptions)) fail("mcpOptions is not an object");

  const options = {};
  for (const [name, option] of Object.entries(mcpOptions)) {
    if (!isPlainObject(option)) fail(`mcpOptions.${name} is not an object`);
    if (!("type" in option) || option.type === undefined)
      fail(`mcpOptions.${name} has no type`);
    if (Object.hasOwn(options, name))
      fail(`duplicate canonical option name ${name}`);
    options[name] = Object.fromEntries(
      Object.keys(option)
        .sort()
        .map((property) => [
          property,
          encode(option[property], `mcpOptions.${name}.${property}`),
        ]),
    );
  }

  return { cli: { options: { mcp: options } } };
};

const [source] = process.argv.slice(2);
if (!source) fail("usage: mcp-options.mjs <installed-mcp-options.js>");
try {
  console.log(JSON.stringify(await extract(source), null, 2));
} catch (error) {
  process.stderr.write(`chrome-devtools-mcp-extract: ${error.message}\n`);
  process.exitCode = 1;
}
