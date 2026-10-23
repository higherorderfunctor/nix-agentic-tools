//! Companion index over the exact snapshot bytes passed to the audited kit.
use std::{
    env, fs,
    io::{self, Write},
    path::Path,
};

fn path(indices: &[usize]) -> String {
    format!(
        "[{}]",
        indices
            .iter()
            .map(usize::to_string)
            .collect::<Vec<_>>()
            .join(",")
    )
}

fn main() -> io::Result<()> {
    let args: Vec<_> = env::args().collect();
    if args.len() != 5 {
        return Err(io::Error::other(
            "usage: nixql-anchors SNAPSHOT SOURCE_PATH TRAP INDEX",
        ));
    }
    let bytes = fs::read(&args[1])?;
    std::str::from_utf8(&bytes).map_err(io::Error::other)?;
    let mut parser = tree_sitter::Parser::new();
    parser
        .set_language(&tree_sitter_nix::LANGUAGE.into())
        .map_err(io::Error::other)?;
    let tree = parser
        .parse(&bytes, None)
        .ok_or_else(|| io::Error::other("parse failed"))?;
    let mut rows = Vec::new();
    let mut errors = 0;
    let mut stack = vec![(tree.root_node(), Vec::new(), Vec::new(), true)];
    while let Some((node, structural, raw_structural, admitted)) = stack.pop() {
        let valid = admitted && !node.is_error() && !node.is_missing();
        if node.is_error() || node.is_missing() {
            errors += 1;
        }
        rows.push(format!(
            "{}\t{}\t{}\t{}\t{}\t{}\n",
            node.start_byte(),
            node.end_byte(),
            node.kind(),
            path(&structural),
            path(&raw_structural),
            usize::from(valid)
        ));
        let mut children = Vec::new();
        let mut raw_index = 0;
        for i in 0..node.child_count() {
            let child = node.child(i as u32).unwrap();
            let mut child_path = structural.clone();
            child_path.push(i);
            let child_raw = if child.is_extra() {
                Vec::new()
            } else {
                let mut p = raw_structural.clone();
                p.push(raw_index);
                if !child.is_error() && !child.is_missing() {
                    raw_index += 1;
                }
                p
            };
            children.push((child, child_path, child_raw, valid));
        }
        stack.extend(children.into_iter().rev());
    }
    nixql_syntax::syntax(
        &bytes,
        Path::new(&args[2]),
        Path::new(&args[3]),
        tree_sitter_nix::NODE_TYPES,
    )?;
    let mut output = fs::File::create(&args[4])?;
    writeln!(
        output,
        "{}\t{}",
        if tree.root_node().has_error() {
            "recovered"
        } else {
            "complete"
        },
        errors
    )?;
    for row in rows {
        output.write_all(row.as_bytes())?;
    }
    Ok(())
}
