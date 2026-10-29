//! The strict JSON file `airlock serve --config` reads: unknown or duplicate
//! fields are errors, never ignored.
use std::{
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
};

use serde::Deserialize;

pub struct Config {
    pub listen: SocketAddr,
    pub interception: Option<Interception>,
}

#[derive(Debug)]
pub struct Interception {
    pub ca_directory: PathBuf,
    pub destinations: Vec<String>,
    /// Extra PEM roots for private origins or a corporate TLS-inspecting proxy; widens upstream trust.
    pub upstream_roots: Option<PathBuf>,
}

// File input allows an omitted directory when --ca-directory supplies it;
// the runtime config carries the resolved directory instead of an Option.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    listen: SocketAddr,
    interception: Option<InterceptionFile>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InterceptionFile {
    ca_directory: Option<PathBuf>,
    destinations: Vec<String>,
    upstream_roots: Option<PathBuf>,
}

impl Config {
    /// Read the file at `path`; `ca_directory`, from `--ca-directory`,
    /// replaces the configured interception CA directory.
    pub fn read(path: impl AsRef<Path>, ca_directory: Option<PathBuf>) -> Result<Self, String> {
        let path = path.as_ref();
        let content = fs::read_to_string(path)
            .map_err(|error| format!("could not read config {}: {error}", path.display()))?;
        // serde accepts a JSON array for a struct; require an object.
        if !content.trim_start().starts_with('{') {
            return Err(format!(
                "invalid config {}: the root must be a JSON object",
                path.display()
            ));
        }

        let config: ConfigFile = serde_json::from_str(&content)
            .map_err(|error| format!("invalid config {}: {error}", path.display()))?;
        let interception = if let Some(interception) = config.interception {
            // An explicit empty path is invalid, including a CLI override of
            // an otherwise valid configured path.
            let ca_directory = ca_directory
                .or(interception.ca_directory)
                .filter(|path| !path.as_os_str().is_empty())
                .ok_or("interception requires ca_directory or --ca-directory")?;
            Some(Interception {
                ca_directory,
                destinations: interception.destinations,
                upstream_roots: interception.upstream_roots,
            })
        } else if ca_directory.is_some() {
            return Err("--ca-directory requires interception configuration".to_owned());
        } else {
            None
        };
        Ok(Self {
            listen: config.listen,
            interception,
        })
    }
}
