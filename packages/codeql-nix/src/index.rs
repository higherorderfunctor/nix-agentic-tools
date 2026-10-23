//! Raw file-list hook for syntax inventory checks.
use std::{env, fs, io, path::Path};

fn main() -> io::Result<()> {
    let args: Vec<_> = env::args().collect();
    if args.len() != 2 {
        return Err(io::Error::other("usage: nixql-index-raw FILE_LIST"));
    }
    let trap = env::var("CODEQL_EXTRACTOR_NIX_TRAP_DIR").map_err(io::Error::other)?;
    let archive = env::var("CODEQL_EXTRACTOR_NIX_SOURCE_ARCHIVE_DIR").map_err(io::Error::other)?;
    fs::create_dir_all(&trap)?;
    for (index, name) in fs::read_to_string(&args[1])?.lines().enumerate() {
        let path = fs::canonicalize(name)?;
        let source = fs::read(&path)?;
        nixql_syntax::syntax(
            &source,
            &path,
            &Path::new(&trap).join(format!("syntax-{index}.trap")),
            tree_sitter_nix::NODE_TYPES,
        )?;
        let archived = Path::new(&archive).join(path.strip_prefix("/").map_err(io::Error::other)?);
        fs::create_dir_all(archived.parent().unwrap())?;
        fs::write(archived, source)?;
    }
    Ok(())
}
