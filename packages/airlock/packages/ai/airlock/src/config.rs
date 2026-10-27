use std::{
    collections::BTreeMap,
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
};

use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub listen: SocketAddr,
    pub clients: Option<BTreeMap<String, Client>>,
    pub interception: Option<Interception>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Client {
    pub token_file: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Interception {
    #[serde(default)]
    pub ca_directory: PathBuf,
    pub destinations: Vec<String>,
    pub upstream_roots: Option<PathBuf>,
}

impl Config {
    pub fn read(path: impl AsRef<Path>) -> Result<Self, String> {
        Self::read_with_ca_directory(path, None)
    }

    pub fn read_with_ca_directory(
        path: impl AsRef<Path>,
        ca_directory: Option<PathBuf>,
    ) -> Result<Self, String> {
        let path = path.as_ref();
        let content = fs::read_to_string(path)
            .map_err(|error| format!("could not read config {}: {error}", path.display()))?;
        if !content.trim_start().starts_with('{') {
            return Err(format!(
                "invalid config {}: the root must be a JSON object",
                path.display()
            ));
        }

        let mut config: Self = serde_json::from_str(&content)
            .map_err(|error| format!("invalid config {}: {error}", path.display()))?;
        if let Some(directory) = ca_directory {
            config
                .interception
                .as_mut()
                .ok_or("--ca-directory requires interception configuration")?
                .ca_directory = directory;
        }
        if config
            .interception
            .as_ref()
            .is_some_and(|interception| interception.ca_directory.as_os_str().is_empty())
        {
            return Err("interception requires ca_directory or --ca-directory".to_owned());
        }
        Ok(config)
    }
}
