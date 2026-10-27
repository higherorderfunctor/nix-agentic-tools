//! The strict JSON file `airlock serve --config` reads: unknown or duplicate
//! fields are errors, never ignored.
use std::{
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
};

use serde::Deserialize;

use crate::ca::{Instance, RuntimeBase};

pub struct Config {
    pub listen: SocketAddr,
    pub interception: Option<Interception>,
}

pub struct Interception {
    /// Where the CA that signs intercepted leaves lives.
    pub base: RuntimeBase,
    pub instance: Instance,
    pub destinations: Vec<String>,
    /// Extra PEM roots for private origins or a corporate TLS-inspecting proxy; widens upstream trust.
    pub upstream_roots: Option<PathBuf>,
}

// The file names no CA directory: the instance and the environment choose it.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    listen: SocketAddr,
    interception: Option<InterceptionFile>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InterceptionFile {
    destinations: Vec<String>,
    upstream_roots: Option<PathBuf>,
}

impl Config {
    /// Read the file at `path`; interception loads `instance`'s CA, or the
    /// default instance's, from the runtime base the environment selects.
    pub fn read(path: impl AsRef<Path>, instance: Option<Instance>) -> Result<Self, String> {
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
        // Plain serving reads no CA, so it needs no runtime base.
        let interception = match (config.interception, instance) {
            (Some(file), instance) => Some(Interception {
                base: RuntimeBase::from_environment()?,
                instance: instance.unwrap_or_default(),
                destinations: file.destinations,
                upstream_roots: file.upstream_roots,
            }),
            // Plain serving would ignore the instance and intercept nothing.
            (None, Some(_)) => {
                return Err("--instance requires interception configuration".to_owned());
            }
            (None, None) => None,
        };
        Ok(Self {
            listen: config.listen,
            interception,
        })
    }
}
