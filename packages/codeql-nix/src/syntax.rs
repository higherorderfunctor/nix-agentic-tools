use codeql_extractor::{diagnostics, extractor, file_paths, node_types, trap};
use std::{fs, io, path::Path};

pub const LIMIT: usize = 1_048_576;
pub fn exact(text: &str) -> io::Result<()> {
    exact_length(text.len())
}

fn exact_length(length: usize) -> io::Result<()> {
    if length > LIMIT {
        Err(io::Error::other("text-field-too-large"))
    } else {
        Ok(())
    }
}

pub fn file_path(path: &Path) -> io::Result<()> {
    for component in path.ancestors() {
        exact(&file_paths::normalize_and_transform_path(component, None))?;
    }
    Ok(())
}

// Pinned extractor/mod.rs:664-900: every plaintext template and every variable
// argument. Grammar kind/field names and schema Debug/storage names are finite;
// no diagnostic argument contains source text. Re-audit when either pin changes.
fn diagnostic_bound(language: &tree_sitter::Language, schema: &node_types::NodeTypeMap) -> usize {
    let mut kind = 0;
    let mut type_name = 0;
    for id in 0..language.node_kind_count() as u16 {
        let name = language.node_kind_for_id(id).unwrap_or("");
        kind = kind.max(name.len());
        type_name = type_name.max(
            format!(
                "{:?}",
                node_types::TypeName {
                    kind: name.into(),
                    named: language.node_kind_is_named(id),
                }
            )
            .len(),
        );
    }
    let field = (1..=language.field_count() as u16)
        .filter_map(|id| language.field_name_for_id(id))
        .map(str::len)
        .chain(["child".len()])
        .max()
        .unwrap();
    let mut type_info = 0;
    let mut storage = 0;
    for entry in schema.values() {
        if let node_types::EntryKind::Table { fields, .. } = &entry.kind {
            for field in fields {
                type_info = type_info.max(format!("{:?}", field.type_info).len());
                let name = match &field.storage {
                    node_types::Storage::Column { name } => name,
                    node_types::Storage::Table { name, .. } => name,
                };
                storage = storage.max(name.len());
            }
        }
    }
    let template = |text: &str, arguments: usize| text.replace("{}", "").len() + arguments;
    [
        template("A parse error occurred (expected {} symbol). Check the syntax of the file. If the file is invalid, correct the error or {} the file from analysis.", kind + "exclude".len()),
        template("A parse error occurred. Check the syntax of the file. If the file is invalid, correct the error or {} the file from analysis.", "exclude".len()),
        template("Unknown table type: {}", kind),
        template("Type mismatch for field {}::{} with type {} != {}", kind + field + type_name + type_info),
        template("Value for unknown field: {}::{} and type {}", kind + field + type_name),
        template("Missing value for field: {}::{}", kind + storage),
        template("Too many values for field: {}::{}", kind + storage),
    ].into_iter().max().unwrap()
}

fn diagnostic_path(path: &Path) -> String {
    // Exactly the kit's canonicalized-cwd-or-None semantics.
    let root = std::env::current_dir()
        .ok()
        .and_then(|d| d.canonicalize().ok());
    file_paths::relativize_for_diagnostic(path, root.as_deref())
}

// Consume TRAP entries, respecting multiline strings and doubled quotes. Only
// diagnostics have variable strings beyond the checked tokens/file paths.
fn check_diagnostics(text: &str, dry_path: &str, actual_path: &str) -> io::Result<()> {
    let mut chars = text.chars().peekable();
    let mut entry = String::new();
    let mut quoted = false;
    while let Some(c) = chars.next() {
        entry.push(c);
        if c == '"' {
            if quoted && chars.peek() == Some(&'"') {
                entry.push(chars.next().unwrap());
            } else {
                quoted = !quoted;
            }
        }
        if c == '\n' && !quoted {
            if entry.starts_with("diagnostics(") {
                let mut parts = entry.chars().peekable();
                let mut strings = Vec::new();
                while let Some(c) = parts.next() {
                    if c != '"' {
                        continue;
                    }
                    let mut value = String::new();
                    loop {
                        let c = parts
                            .next()
                            .ok_or_else(|| io::Error::other("invalid dry TRAP"))?;
                        if c == '"' {
                            if parts.peek() == Some(&'"') {
                                parts.next();
                            } else {
                                break;
                            }
                        }
                        value.push(c);
                    }
                    strings.push(value);
                }
                if strings.len() != 3 || strings[0] != "parse_error" {
                    return Err(io::Error::other("unexpected diagnostic tuple"));
                }
                exact(&strings[1])?;
                let suffix = strings[2]
                    .strip_prefix(dry_path)
                    .filter(|suffix| suffix.starts_with(':'))
                    .ok_or_else(|| io::Error::other("unexpected diagnostic path"))?;
                exact(&format!("{actual_path}{suffix}"))?;
            }
            entry.clear();
        }
    }
    if quoted || !entry.is_empty() {
        return Err(io::Error::other("invalid dry TRAP"));
    }
    Ok(())
}

pub fn syntax(source: &[u8], path: &Path, output: &Path, node_types_json: &str) -> io::Result<()> {
    file_path(path)?;
    let schema = node_types::read_node_types_str("nix", node_types_json)?;
    let language = tree_sitter_nix::LANGUAGE.into();
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&language).map_err(io::Error::other)?;
    let tree = parser
        .parse(source, None)
        .ok_or_else(|| io::Error::other("parse failed"))?;
    let mut cursor = tree.walk();
    let mut root = true;
    loop {
        let node = cursor.node();
        let visited = !node.is_error() && !node.is_missing();
        if visited {
            if let Some(entry) = schema.get(&node_types::TypeName {
                kind: node.kind().to_owned(),
                named: node.is_named(),
            }) {
                if matches!(entry.kind, node_types::EntryKind::Token { .. }) {
                    exact(&String::from_utf8_lossy(&source[node.byte_range()]))?;
                }
            }
        }
        // The kit prunes error/missing subtrees (except its initial root).
        let descend = root || visited;
        root = false;
        if descend && cursor.goto_first_child() {
            continue;
        }
        loop {
            if cursor.goto_next_sibling() {
                break;
            }
            if !cursor.goto_parent() {
                return extract_checked(source, path, output, &language, &schema);
            }
        }
    }
}

fn extract_checked(
    source: &[u8],
    path: &Path,
    output: &Path,
    language: &tree_sitter::Language,
    schema: &node_types::NodeTypeMap,
) -> io::Result<()> {
    let actual_path = diagnostic_path(path);
    // diagnostics.rs:226-240: path + ':' + usize decimal line + ': ' + body.
    let overhead = usize::MAX.to_string().len() + ":".len() + ": ".len();
    let body = diagnostic_bound(language, schema);
    if actual_path.len() + overhead + body > LIMIT {
        let dry = Path::new("/nixql-preflight.nix");
        file_path(dry)?;
        let dry_path = diagnostic_path(dry);
        exact_length(dry_path.len() + overhead + body)?;
        // A separate, disabled sink keeps speculative diagnostics private. Do
        // not mutate process environment or share the real logger's output.
        if std::env::var_os("CODEQL_EXTRACTOR_NIXQL_PREFLIGHT_DIAGNOSTIC_DIR").is_some() {
            return Err(io::Error::other("preflight diagnostic sink must be unset"));
        }
        let mut logger = diagnostics::DiagnosticLoggers::new("nixql_preflight").logger();
        let mut writer = trap::Writer::new();
        extractor::extract(
            language,
            "nix",
            schema,
            &mut logger,
            &mut writer,
            None,
            dry,
            source,
            &[],
        );
        // The binary processes files serially. create_dir refuses stale/shared
        // scratch rather than overwriting it; all exit paths clean it up.
        let private = std::env::temp_dir().join(format!("nixql-preflight-{}", std::process::id()));
        fs::create_dir(&private)?;
        let result = (|| {
            let trap = private.join("dry");
            writer.write_to_file(&trap, trap::Compression::None)?;
            check_diagnostics(&fs::read_to_string(trap)?, &dry_path, &actual_path)
        })();
        fs::remove_dir_all(private)?;
        result?;
    }
    let mut writer = trap::Writer::new();
    let mut logger = diagnostics::DiagnosticLoggers::new("nix").logger();
    extractor::extract(
        language,
        "nix",
        schema,
        &mut logger,
        &mut writer,
        None,
        path,
        source,
        &[],
    );
    extractor::populate_empty_location(&mut writer);
    let temporary = output.with_extension("pending");
    writer.write_to_file(&temporary, trap::Compression::None)?;
    fs::rename(temporary, output)
}
