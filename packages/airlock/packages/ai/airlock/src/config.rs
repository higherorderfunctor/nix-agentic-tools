//! The strict JSON file `airlock serve --config` reads: unknown or duplicate
//! fields are errors, never ignored.
use std::{fs, net::SocketAddr, path::Path};

use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub listen: SocketAddr,
}

impl Config {
    pub fn read(path: impl AsRef<Path>) -> Result<Self, String> {
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

        serde_json::from_str(&content)
            .map_err(|error| format!("invalid config {}: {error}", path.display()))
    }
}
