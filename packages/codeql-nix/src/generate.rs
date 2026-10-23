//! Invoke the pinned kit without F0's disposable handwritten relation.
use codeql_extractor::generator;
use std::{env, io};

fn main() -> io::Result<()> {
    let args: Vec<_> = env::args_os().collect();
    if args.len() != 3 {
        return Err(io::Error::other("usage: nixql-generate-raw SCHEMA AST"));
    }
    generator::generate(
        vec![generator::language::Language {
            name: "Nix".into(),
            node_types: tree_sitter_nix::NODE_TYPES,
            desugar: None,
        }],
        (&args[1]).into(),
        (&args[2]).into(),
        false,
        "nixql-generate",
    )
}
