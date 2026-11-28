use std::{
    collections::BTreeMap,
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
};

use hyper::{Uri, header::HeaderValue};
use serde::Deserialize;
use zeroize::Zeroizing;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Plan {
    pub clients: BTreeMap<String, PathBuf>,
    pub intercept: Option<String>,
    pub ca_instance: Option<String>,
    pub management: Option<Management>,
    pub routes: Vec<Route>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Management {
    pub listen: SocketAddr,
    pub token_file: PathBuf,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Route {
    pub client: String,
    pub path: String,
    pub model: String,
    pub primary: Destination,
    pub fallback: Option<Destination>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Destination {
    pub uri: String,
    pub key_file: PathBuf,
    pub pool: String,
    pub model: Option<String>,
    #[serde(default)]
    pub auth: Authentication,
    pub unwrap: Option<String>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Authentication {
    #[default]
    ApiKey,
    Bearer,
}
impl Plan {
    pub fn read(path: &Path) -> Result<Self, String> {
        let input = fs::read(path).map_err(|error| format!("{}: {error}", path.display()))?;
        serde_json::from_slice(&input)
            .map_err(|error| format!("invalid route plan {}: {error}", path.display()))
    }
}

pub(super) fn secret(path: &Path) -> Result<HeaderValue, String> {
    if !path.is_absolute() {
        return Err(format!("secret path {} must be absolute", path.display()));
    }
    let input = Zeroizing::new(
        fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))?,
    );
    let value = input.trim_end_matches(['\n', '\r']);
    if value.is_empty() || value.bytes().any(|byte| !byte.is_ascii_graphic()) {
        return Err(format!(
            "{} must contain one nonempty ASCII secret",
            path.display()
        ));
    }
    let mut header = HeaderValue::from_str(value).map_err(|error| error.to_string())?;
    header.set_sensitive(true);
    Ok(header)
}

pub(super) fn destination_uri(value: &str) -> Result<Uri, String> {
    let invalid = || "upstream URI must be HTTPS or HTTP on a loopback IP".to_owned();
    let uri = value.parse::<Uri>().map_err(|_| invalid())?;
    let authority = uri.authority().ok_or_else(invalid)?;
    if authority.as_str().contains('@') || uri.query().is_some() {
        return Err(invalid());
    }
    match uri.scheme_str() {
        Some("https") => Ok(uri),
        Some("http")
            if authority
                .host()
                .trim_matches(['[', ']'])
                .parse::<std::net::IpAddr>()
                .is_ok_and(|ip| ip.is_loopback()) =>
        {
            Ok(uri)
        }
        _ => Err(invalid()),
    }
}
