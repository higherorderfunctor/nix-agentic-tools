use std::{env, fs, path::Path};
fn main() {
    let args: Vec<_> = env::args().collect();
    assert!(
        (4..=5).contains(&args.len()),
        "SOURCE LOGICAL_PATH_FILE TRAP_OUTPUT [NODE_TYPES_JSON]"
    );
    let result = fs::read(&args[1]).and_then(|source| {
        let logical = fs::read_to_string(&args[2])?;
        let schema = args.get(4).map(fs::read_to_string).transpose()?;
        nixql_bootstrap::syntax(
            &source,
            Path::new(&logical),
            Path::new(&args[3]),
            schema.as_deref().unwrap_or(tree_sitter_nix::NODE_TYPES),
        )
    });
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(if error.to_string() == "text-field-too-large" {
            2
        } else {
            1
        });
    }
}
