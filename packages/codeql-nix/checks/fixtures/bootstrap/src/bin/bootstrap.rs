use codeql_extractor::{extractor, generator, trap};
use std::{
    env, fs,
    io::{self, Write},
    path::Path,
};
fn main() -> io::Result<()> {
    let args: Vec<_> = env::args().collect();
    match args[1].as_str() {
        "generate" => {
            generator::generate(
                vec![generator::language::Language {
                    name: "Nix".into(),
                    node_types: tree_sitter_nix::NODE_TYPES,
                    desugar: None,
                }],
                (&args[2]).into(),
                (&args[3]).into(),
                false,
                "bootstrap generate",
            )?;
            writeln!(
                fs::OpenOptions::new().append(true).open(&args[2])?,
                "nx_bootstrap_targets(unique int id: @nx_bootstrap_target, int file: @file ref, string target: string ref, string text: string ref);"
            )?;
        }
        "syntax" => {
            let trap = env::var("CODEQL_EXTRACTOR_NIX_TRAP_DIR").unwrap();
            let archive = env::var("CODEQL_EXTRACTOR_NIX_SOURCE_ARCHIVE_DIR").unwrap();
            fs::create_dir_all(&trap)?;
            for (index, name) in fs::read_to_string(&args[2])?.lines().enumerate() {
                let path = fs::canonicalize(name)?;
                let source = fs::read(&path)?;
                nixql_bootstrap::syntax(
                    &source,
                    &path,
                    &Path::new(&trap).join(format!("syntax-{index}.trap")),
                    tree_sitter_nix::NODE_TYPES,
                )?;
                let archived = Path::new(&archive).join(path.strip_prefix("/").unwrap());
                fs::create_dir_all(archived.parent().unwrap())?;
                fs::write(archived, source)?;
            }
        }
        "evaluation" => {
            let mut writer = trap::Writer::new();
            for line in fs::read_to_string("targets.tsv")?.lines() {
                let fields: Vec<_> = line.split('\t').collect();
                assert_eq!(fields.len(), 3);
                for field in &fields {
                    nixql_bootstrap::exact(field)?;
                }
                let path = env::current_dir()?.join(fields[1]);
                nixql_bootstrap::file_path(&path)?;
                let file = extractor::populate_file(&mut writer, &path, None);
                let (target, _) =
                    writer.global_id(&format!("nixql-bootstrap/target/{}", fields[0]));
                writer.add_tuple(
                    "nx_bootstrap_targets",
                    vec![
                        trap::Arg::Label(target),
                        trap::Arg::Label(file),
                        trap::Arg::String(fields[0].into()),
                        trap::Arg::String(fields[2].into()),
                    ],
                );
            }
            let output = Path::new(&env::var("CODEQL_EXTRACTOR_NIX_TRAP_DIR").unwrap())
                .join("evaluation.trap");
            let temporary = output.with_extension("pending");
            writer.write_to_file(&temporary, trap::Compression::None)?;
            fs::rename(temporary, output)?;
        }
        _ => return Err(io::Error::other("unknown bootstrap mode")),
    }
    Ok(())
}
