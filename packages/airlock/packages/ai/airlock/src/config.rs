//! The strict JSON file `airlock serve --config` reads: unknown or duplicate
//! fields are errors, never ignored.
use std::{
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
};

use serde::Deserialize;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub listen: SocketAddr,
    pub interception: Option<Interception>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Interception {
    pub ca_directory: Option<PathBuf>,
    pub destinations: Vec<String>,
    /// Extra PEM roots for private origins or a corporate TLS-inspecting proxy; widens upstream trust.
    pub upstream_roots: Option<PathBuf>,
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

        let mut config: Self = serde_json::from_str(&content)
            .map_err(|error| format!("invalid config {}: {error}", path.display()))?;
        if let Some(interception) = config.interception.as_mut() {
            interception.ca_directory = ca_directory.or(interception.ca_directory.take());
        } else if ca_directory.is_some() {
            return Err("--ca-directory requires interception configuration".to_owned());
        }
        Ok(config)
    }
}
