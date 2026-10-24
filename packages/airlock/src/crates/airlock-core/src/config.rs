#[cfg(test)]
use std::path::Path;
use std::{collections::BTreeMap, net::SocketAddr, path::PathBuf};

use serde::Deserialize;

use crate::{
    error::{ConfigError, ConfigErrors, NameError},
    ids::{ClientId, CredentialId, HostName, UpstreamId},
    policy::Grant,
    secret::SecretFile,
};

#[allow(dead_code)]
pub struct Config {
    clients: BTreeMap<ClientId, ClientConfig>,
    credentials: BTreeMap<CredentialId, CredentialConfig>,
    listen: SocketAddr,
    state_dir: PathBuf,
    unknown_hosts: UnknownHosts,
    upstreams: BTreeMap<UpstreamId, UpstreamConfig>,
}

#[allow(dead_code)]
pub struct ClientConfig {
    grants: Vec<Grant>,
    token_file: SecretFile,
}

#[allow(dead_code)]
pub struct CredentialConfig {
    auth: Auth,
    upstream: UpstreamId,
}

pub enum Auth {
    ApiKey { file: SecretFile },
    OauthBearer { file: SecretFile },
}

#[allow(dead_code)]
pub struct UpstreamConfig {
    hosts: Vec<HostName>,
    provider: Provider,
}

pub enum Provider {
    Anthropic,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnknownHosts {
    Deny,
    Tunnel,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawConfig {
    pub clients: BTreeMap<String, RawClient>,
    pub credentials: BTreeMap<String, RawCredential>,
    pub listen: String,
    pub state_dir: PathBuf,
    #[serde(default)]
    pub unknown_hosts: Option<String>,
    pub upstreams: BTreeMap<String, RawUpstream>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawClient {
    pub grants: Vec<RawGrant>,
    pub token_file: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawCredential {
    pub auth: RawAuth,
    pub upstream: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, tag = "type", rename_all = "snake_case")]
pub enum RawAuth {
    ApiKey { file: PathBuf },
    OauthBearer { file: PathBuf },
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawUpstream {
    pub intercept: Vec<String>,
    pub provider: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawGrant {
    pub credentials: Vec<String>,
    pub upstream: String,
}

impl Config {
    pub(crate) fn client_grants(&self) -> impl Iterator<Item = (&ClientId, &[Grant])> {
        self.clients
            .iter()
            .map(|(client, config)| (client, config.grants.as_slice()))
    }

    pub(crate) fn intercepted_hosts(&self) -> impl Iterator<Item = (&HostName, &UpstreamId)> {
        self.upstreams.iter().flat_map(|(upstream_id, upstream)| {
            upstream.hosts.iter().map(move |host| (host, upstream_id))
        })
    }

    pub(crate) fn unknown_hosts(&self) -> UnknownHosts {
        self.unknown_hosts
    }
}

impl TryFrom<RawConfig> for Config {
    type Error = ConfigErrors;

    fn try_from(raw: RawConfig) -> Result<Self, Self::Error> {
        let mut errors = Vec::new();
        let listen = match raw.listen.parse::<SocketAddr>() {
            Ok(address) if address.ip().is_loopback() => Some(address),
            Ok(address) => {
                errors.push(ConfigError::NonLoopbackListen { address });
                None
            }
            Err(_) => {
                errors.push(ConfigError::InvalidListen {
                    value: raw.listen.clone(),
                });
                None
            }
        };
        let state_dir = match absolute_path(&raw.state_dir) {
            Ok(path) => Some(path),
            Err(path) => {
                errors.push(ConfigError::RelativeStateDir { path });
                None
            }
        };
        let unknown_hosts = match raw.unknown_hosts.as_deref().unwrap_or("tunnel") {
            "deny" => Some(UnknownHosts::Deny),
            "tunnel" => Some(UnknownHosts::Tunnel),
            value => {
                errors.push(ConfigError::InvalidUnknownHostPolicy {
                    value: value.to_owned(),
                });
                None
            }
        };

        let (clients, client_errors) = parse_clients(&raw);
        let (credentials, credential_errors) = parse_credentials(&raw);
        let (upstreams, upstream_errors) = parse_upstreams(&raw);
        errors.extend(client_errors);
        errors.extend(credential_errors);
        errors.extend(upstream_errors);
        validate_references(&raw, &mut errors);

        match (listen, state_dir, unknown_hosts) {
            (Some(listen), Some(state_dir), Some(unknown_hosts)) if errors.is_empty() => Ok(Self {
                clients,
                credentials,
                listen,
                state_dir,
                unknown_hosts,
                upstreams,
            }),
            _ => Err(ConfigErrors(errors)),
        }
    }
}

fn invalid_name(field: &'static str, error: NameError) -> ConfigError {
    ConfigError::InvalidName {
        field,
        value: error.into_name(),
    }
}

fn parse_clients(raw: &RawConfig) -> (BTreeMap<ClientId, ClientConfig>, Vec<ConfigError>) {
    let mut clients = BTreeMap::new();
    let mut errors = Vec::new();

    for (raw_client_id, raw_client) in &raw.clients {
        let client = match ClientId::try_from(raw_client_id.as_str()) {
            Ok(client) => Some(client),
            Err(error) => {
                errors.push(invalid_name("client", error));
                None
            }
        };
        let token_file = match SecretFile::try_from(raw_client.token_file.clone()) {
            Ok(file) => Ok(file),
            Err(error) => {
                let path = match error {
                    crate::error::SecretFileError::RelativePath { path } => path,
                };
                errors.push(ConfigError::RelativeTokenFile {
                    client: raw_client_id.clone(),
                    path,
                });
                Err(())
            }
        };

        if raw_client.grants.is_empty() {
            errors.push(ConfigError::EmptyGrants {
                client: raw_client_id.clone(),
            });
        }

        let mut grants = Vec::new();
        for raw_grant in &raw_client.grants {
            let upstream = match UpstreamId::try_from(raw_grant.upstream.as_str()) {
                Ok(upstream) => Some(upstream),
                Err(error) => {
                    errors.push(invalid_name("upstream", error));
                    None
                }
            };
            if raw_grant.credentials.is_empty() {
                errors.push(ConfigError::EmptyGrantCredentials {
                    client: raw_client_id.clone(),
                });
            }

            let mut credentials = Vec::new();
            for raw_credential in &raw_grant.credentials {
                match CredentialId::try_from(raw_credential.as_str()) {
                    Ok(credential) => credentials.push(credential),
                    Err(error) => errors.push(invalid_name("credential", error)),
                }
            }

            if let Some(upstream) = upstream
                && credentials.len() == raw_grant.credentials.len()
            {
                match NonEmpty::try_from(credentials) {
                    Ok(credentials) => grants.push(Grant::Upstream {
                        credentials,
                        upstream,
                    }),
                    // The empty case was recorded before upstream parsing so both errors stay independent.
                    Err(NonEmptyError::Empty) => {}
                }
            }
        }

        if let (Some(client), Ok(token_file)) = (client, token_file)
            && (raw_client.grants.is_empty() || !grants.is_empty())
        {
            clients.insert(client, ClientConfig { grants, token_file });
        }
    }

    (clients, errors)
}

fn parse_credentials(
    raw: &RawConfig,
) -> (BTreeMap<CredentialId, CredentialConfig>, Vec<ConfigError>) {
    let mut credentials = BTreeMap::new();
    let mut errors = Vec::new();

    for (raw_credential_id, raw_credential) in &raw.credentials {
        let credential = match CredentialId::try_from(raw_credential_id.as_str()) {
            Ok(credential) => Some(credential),
            Err(error) => {
                errors.push(invalid_name("credential", error));
                None
            }
        };
        let upstream = match UpstreamId::try_from(raw_credential.upstream.as_str()) {
            Ok(upstream) => Some(upstream),
            Err(error) => {
                errors.push(invalid_name("upstream", error));
                None
            }
        };
        let auth = parse_auth(&raw_credential.auth, raw_credential_id);

        match (credential, upstream, auth) {
            (Some(credential), Some(upstream), Ok(auth)) => {
                credentials.insert(credential, CredentialConfig { auth, upstream });
            }
            (_, _, Err(error)) => errors.push(error),
            (_, _, Ok(_)) => {}
        }
    }

    (credentials, errors)
}

fn parse_auth(raw_auth: &RawAuth, raw_credential_id: &str) -> Result<Auth, ConfigError> {
    let file = SecretFile::try_from(match raw_auth {
        RawAuth::ApiKey { file } | RawAuth::OauthBearer { file } => file.clone(),
    })
    .map_err(|error| {
        let path = match error {
            crate::error::SecretFileError::RelativePath { path } => path,
        };
        ConfigError::RelativeAuthFile {
            credential: raw_credential_id.to_owned(),
            path,
        }
    })?;

    Ok(match raw_auth {
        RawAuth::ApiKey { .. } => Auth::ApiKey { file },
        RawAuth::OauthBearer { .. } => Auth::OauthBearer { file },
    })
}

fn parse_upstreams(raw: &RawConfig) -> (BTreeMap<UpstreamId, UpstreamConfig>, Vec<ConfigError>) {
    let mut upstreams = BTreeMap::new();
    let mut intercepted_hosts: BTreeMap<HostName, String> = BTreeMap::new();
    let mut errors = Vec::new();

    for (raw_upstream_id, raw_upstream) in &raw.upstreams {
        let upstream = match UpstreamId::try_from(raw_upstream_id.as_str()) {
            Ok(upstream) => Some(upstream),
            Err(error) => {
                errors.push(invalid_name("upstream", error));
                None
            }
        };
        let provider = match raw_upstream.provider.as_str() {
            "anthropic" => Some(Provider::Anthropic),
            provider => {
                errors.push(ConfigError::UnsupportedProvider {
                    upstream: raw_upstream_id.clone(),
                    provider: provider.to_owned(),
                });
                None
            }
        };

        let mut hosts = Vec::new();
        for raw_host in &raw_upstream.intercept {
            let host = match HostName::try_from(raw_host.as_str()) {
                Ok(host) => Some(host),
                Err(error) => {
                    let host = match error {
                        crate::error::HostNameError::InvalidHostName { value }
                        | crate::error::HostNameError::IpAddress { value } => value,
                    };
                    errors.push(ConfigError::InvalidHost {
                        upstream: raw_upstream_id.clone(),
                        host,
                    });
                    None
                }
            };

            if let Some(host) = host {
                if let Some(first) = intercepted_hosts.get(&host) {
                    errors.push(ConfigError::DuplicateInterceptHost {
                        host: raw_host.clone(),
                        first: first.clone(),
                        second: raw_upstream_id.clone(),
                    });
                } else {
                    intercepted_hosts.insert(host.clone(), raw_upstream_id.clone());
                }
                hosts.push(host);
            }
        }

        if let (Some(upstream), Some(provider)) = (upstream, provider) {
            upstreams.insert(upstream, UpstreamConfig { hosts, provider });
        }
    }

    (upstreams, errors)
}

fn validate_references(raw: &RawConfig, errors: &mut Vec<ConfigError>) {
    for (raw_credential_id, raw_credential) in &raw.credentials {
        if !raw.upstreams.contains_key(&raw_credential.upstream) {
            errors.push(ConfigError::UnknownCredentialUpstream {
                credential: raw_credential_id.clone(),
                upstream: raw_credential.upstream.clone(),
            });
        }
    }

    for (raw_client_id, raw_client) in &raw.clients {
        for raw_grant in &raw_client.grants {
            if !raw.upstreams.contains_key(&raw_grant.upstream) {
                errors.push(ConfigError::UnknownGrantUpstream {
                    client: raw_client_id.clone(),
                    upstream: raw_grant.upstream.clone(),
                });
            }

            for raw_credential in &raw_grant.credentials {
                let Some(actual) = raw.credentials.get(raw_credential) else {
                    errors.push(ConfigError::UnknownGrantCredential {
                        client: raw_client_id.clone(),
                        credential: raw_credential.clone(),
                    });
                    continue;
                };

                if actual.upstream != raw_grant.upstream {
                    errors.push(ConfigError::CredentialUpstreamMismatch {
                        client: raw_client_id.clone(),
                        credential: raw_credential.clone(),
                        granted: raw_grant.upstream.clone(),
                        actual: actual.upstream.clone(),
                    });
                }
            }
        }
    }
}

fn absolute_path(path: &std::path::Path) -> Result<PathBuf, PathBuf> {
    if path.is_absolute() {
        Ok(path.to_owned())
    } else {
        Err(path.to_owned())
    }
}

#[derive(Clone, Debug)]
pub struct NonEmpty<T>(Vec<T>);

#[derive(Debug, thiserror::Error)]
#[error("non-empty list must contain at least one value")]
pub enum NonEmptyError {
    Empty,
}

impl<T> NonEmpty<T> {
    #[must_use]
    pub fn as_slice(&self) -> &[T] {
        &self.0
    }
}

impl<T> TryFrom<Vec<T>> for NonEmpty<T> {
    type Error = NonEmptyError;

    fn try_from(value: Vec<T>) -> Result<Self, Self::Error> {
        if value.is_empty() {
            Err(NonEmptyError::Empty)
        } else {
            Ok(Self(value))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn valid_raw() -> Value {
        json!({
            "clients": {
                "harness": {
                    "grants": [{
                        "credentials": ["claude"],
                        "upstream": "anthropic"
                    }],
                    "token_file": "/run/airlock/harness-token"
                }
            },
            "credentials": {
                "claude": {
                    "auth": {
                        "file": "/run/airlock/claude-token",
                        "type": "oauth_bearer"
                    },
                    "upstream": "anthropic"
                }
            },
            "listen": "127.0.0.1:8080",
            "state_dir": "/var/lib/airlock",
            "upstreams": {
                "anthropic": {
                    "intercept": ["api.anthropic.com"],
                    "provider": "anthropic"
                }
            }
        })
    }

    fn converted(value: Value) -> Result<Config, ConfigErrors> {
        Config::try_from(serde_json::from_value::<RawConfig>(value).expect("valid raw JSON"))
    }

    fn single_error(value: Value) -> ConfigError {
        let Err(errors) = converted(value) else {
            panic!("invalid fixture converted successfully");
        };
        assert_eq!(errors.0.len(), 1, "expected one error: {errors:?}");
        errors.0.into_iter().next().expect("one error")
    }

    fn assert_matches(actual: &ConfigError, expected: &ConfigError) {
        assert!(
            matches!(actual, variant if std::mem::discriminant(variant) == std::mem::discriminant(expected)),
            "expected {expected:?}, got {actual:?}"
        );
    }

    #[test]
    fn valid_config_converts_and_defaults_unknown_hosts_to_tunnel() {
        let config = converted(valid_raw()).expect("valid config");
        assert_eq!(config.listen, "127.0.0.1:8080".parse().expect("listen"));
        assert_eq!(config.state_dir, PathBuf::from("/var/lib/airlock"));
        assert!(
            config.clients.values().all(|client| {
                client.token_file.path() == Path::new("/run/airlock/harness-token")
            })
        );

        let credential = config
            .credentials
            .get(&CredentialId::try_from("claude").expect("credential id"))
            .expect("credential");
        assert!(matches!(
            credential.auth,
            Auth::OauthBearer {
                file: ref secret_file
            } if secret_file.path() == Path::new("/run/airlock/claude-token")
        ));
        assert_eq!(
            credential.upstream,
            UpstreamId::try_from("anthropic").expect("upstream id")
        );

        let upstream = config
            .upstreams
            .get(&UpstreamId::try_from("anthropic").expect("upstream id"))
            .expect("upstream");
        assert!(matches!(upstream.provider, Provider::Anthropic));
        assert_eq!(
            upstream.hosts,
            vec![HostName::try_from("api.anthropic.com").expect("host")]
        );
        assert_eq!(config.unknown_hosts(), UnknownHosts::Tunnel);
    }

    #[test]
    fn empty_grants_are_rejected() {
        let mut value = valid_raw();
        value["clients"]["harness"]["grants"] = json!([]);
        assert_matches(
            &single_error(value),
            &ConfigError::EmptyGrants {
                client: String::new(),
            },
        );
    }

    #[test]
    fn empty_grant_credentials_use_a_distinct_diagnostic() {
        let mut value = valid_raw();
        value["clients"]["harness"]["grants"][0]["credentials"] = json!([]);
        assert_matches(
            &single_error(value),
            &ConfigError::EmptyGrantCredentials {
                client: String::new(),
            },
        );
    }

    #[test]
    fn duplicate_intercept_hosts_are_rejected() {
        let mut value = valid_raw();
        value["upstreams"]["openai"] = json!({
            "intercept": ["api.anthropic.com"],
            "provider": "anthropic"
        });
        assert_matches(
            &single_error(value),
            &ConfigError::DuplicateInterceptHost {
                host: String::new(),
                first: String::new(),
                second: String::new(),
            },
        );
    }

    #[test]
    fn credential_upstream_mismatches_are_rejected() {
        let mut value = valid_raw();
        value["credentials"]["openai"] = json!({
            "auth": {
                "file": "/run/airlock/openai-token",
                "type": "api_key"
            },
            "upstream": "openai"
        });
        value["upstreams"]["openai"] = json!({
            "intercept": ["api.openai.com"],
            "provider": "anthropic"
        });
        value["clients"]["harness"]["grants"][0]["credentials"] = json!(["openai"]);
        assert_matches(
            &single_error(value),
            &ConfigError::CredentialUpstreamMismatch {
                client: String::new(),
                credential: String::new(),
                granted: String::new(),
                actual: String::new(),
            },
        );
    }

    #[test]
    fn invalid_listen_is_rejected() {
        let mut value = valid_raw();
        value["listen"] = json!("127.0.0.1");
        assert_matches(
            &single_error(value),
            &ConfigError::InvalidListen {
                value: String::new(),
            },
        );
    }

    #[test]
    fn invalid_intercept_host_is_rejected() {
        let mut value = valid_raw();
        value["upstreams"]["anthropic"]["intercept"] = json!(["api.example.com:443"]);
        assert_matches(
            &single_error(value),
            &ConfigError::InvalidHost {
                upstream: String::new(),
                host: String::new(),
            },
        );
    }

    #[test]
    fn invalid_identifier_is_rejected() {
        let mut value = valid_raw();
        value["clients"]["Harness"] = value["clients"]["harness"].clone();
        value["clients"]
            .as_object_mut()
            .expect("clients")
            .remove("harness");
        assert_matches(
            &single_error(value),
            &ConfigError::InvalidName {
                field: "client",
                value: String::new(),
            },
        );
    }

    #[test]
    fn invalid_unknown_host_policy_is_rejected() {
        let mut value = valid_raw();
        value["unknown_hosts"] = json!("forward");
        assert_matches(
            &single_error(value),
            &ConfigError::InvalidUnknownHostPolicy {
                value: String::new(),
            },
        );
    }

    #[test]
    fn non_loopback_listen_is_rejected() {
        let mut value = valid_raw();
        value["listen"] = json!("192.0.2.1:8080");
        assert_matches(
            &single_error(value),
            &ConfigError::NonLoopbackListen {
                address: "192.0.2.1:8080".parse().expect("socket address"),
            },
        );
    }

    #[test]
    fn relative_auth_file_is_rejected() {
        let mut value = valid_raw();
        value["credentials"]["claude"]["auth"]["file"] = json!("tokens/claude");
        assert_matches(
            &single_error(value),
            &ConfigError::RelativeAuthFile {
                credential: String::new(),
                path: PathBuf::new(),
            },
        );
    }

    #[test]
    fn relative_state_dir_is_rejected() {
        let mut value = valid_raw();
        value["state_dir"] = json!("state");
        assert_matches(
            &single_error(value),
            &ConfigError::RelativeStateDir {
                path: PathBuf::new(),
            },
        );
    }

    #[test]
    fn relative_token_file_is_rejected() {
        let mut value = valid_raw();
        value["clients"]["harness"]["token_file"] = json!("tokens/harness");
        assert_matches(
            &single_error(value),
            &ConfigError::RelativeTokenFile {
                client: String::new(),
                path: PathBuf::new(),
            },
        );
    }

    #[test]
    fn unknown_credential_upstream_and_dependent_mismatch_are_collected() {
        let mut value = valid_raw();
        value["credentials"]["claude"]["upstream"] = json!("missing");

        let Err(errors) = converted(value) else {
            panic!("invalid fixture converted successfully");
        };
        assert_eq!(errors.0.len(), 2);
        assert!(matches!(
            errors.0[0],
            ConfigError::UnknownCredentialUpstream { .. }
        ));
        assert!(matches!(
            errors.0[1],
            ConfigError::CredentialUpstreamMismatch { .. }
        ));
    }

    #[test]
    fn unknown_grant_credential_is_rejected() {
        let mut value = valid_raw();
        value["clients"]["harness"]["grants"][0]["credentials"] = json!(["missing"]);
        assert_matches(
            &single_error(value),
            &ConfigError::UnknownGrantCredential {
                client: String::new(),
                credential: String::new(),
            },
        );
    }

    #[test]
    fn unknown_grant_upstream_and_dependent_mismatch_are_collected() {
        let mut value = valid_raw();
        value["clients"]["harness"]["grants"][0]["upstream"] = json!("missing");

        let Err(errors) = converted(value) else {
            panic!("invalid fixture converted successfully");
        };
        assert_eq!(errors.0.len(), 2);
        assert!(matches!(
            errors.0[0],
            ConfigError::UnknownGrantUpstream { .. }
        ));
        assert!(matches!(
            errors.0[1],
            ConfigError::CredentialUpstreamMismatch { .. }
        ));
    }

    #[test]
    fn unsupported_provider_is_rejected() {
        let mut value = valid_raw();
        value["upstreams"]["anthropic"]["provider"] = json!("openai");
        assert_matches(
            &single_error(value),
            &ConfigError::UnsupportedProvider {
                upstream: String::new(),
                provider: String::new(),
            },
        );
    }

    #[test]
    fn unknown_auth_fields_are_rejected_by_raw_deserialization() {
        let mut value = valid_raw();
        value["credentials"]["claude"]["auth"]["unexpected"] = json!(true);
        let result = serde_json::from_value::<RawConfig>(value);
        assert!(result.is_err(), "unknown auth field was accepted");
    }

    #[test]
    fn empty_grant_credentials_are_reported_even_when_grant_upstream_is_invalid() {
        let mut value = valid_raw();
        value["clients"]["harness"]["grants"][0]["credentials"] = json!([]);
        value["clients"]["harness"]["grants"][0]["upstream"] = json!("Anthropic");

        let Err(errors) = converted(value) else {
            panic!("invalid fixture converted successfully");
        };
        assert!(
            errors
                .0
                .iter()
                .any(|error| matches!(error, ConfigError::EmptyGrantCredentials { .. }))
        );
        assert!(errors.0.iter().any(|error| matches!(
            error,
            ConfigError::InvalidName {
                field: "upstream",
                ..
            }
        )));
    }

    #[test]
    fn duplicate_hosts_are_reported_even_when_second_upstream_id_is_invalid() {
        let mut value = valid_raw();
        value["upstreams"]["Anthropic"] = json!({
            "intercept": ["api.anthropic.com"],
            "provider": "anthropic"
        });

        let Err(errors) = converted(value) else {
            panic!("invalid fixture converted successfully");
        };
        assert!(
            errors
                .0
                .iter()
                .any(|error| matches!(error, ConfigError::DuplicateInterceptHost { .. }))
        );
        assert!(errors.0.iter().any(|error| matches!(
            error,
            ConfigError::InvalidName {
                field: "upstream",
                ..
            }
        )));
    }

    #[test]
    fn mismatch_is_reported_even_when_granted_upstream_reference_is_unknown() {
        let mut value = valid_raw();
        value["clients"]["harness"]["grants"][0]["upstream"] = json!("missing");

        let Err(errors) = converted(value) else {
            panic!("invalid fixture converted successfully");
        };
        assert!(
            errors
                .0
                .iter()
                .any(|error| matches!(error, ConfigError::UnknownGrantUpstream { .. }))
        );
        assert!(
            errors
                .0
                .iter()
                .any(|error| matches!(error, ConfigError::CredentialUpstreamMismatch { .. }))
        );
    }

    #[test]
    fn independent_domain_errors_are_all_collected() {
        let mut value = valid_raw();
        value["clients"]["Harness"] = value["clients"]["harness"].clone();
        value["clients"]
            .as_object_mut()
            .expect("clients")
            .remove("harness");
        value["clients"]["Harness"]["grants"][0]["credentials"] = json!(["Claude"]);
        value["credentials"]["Claude"] = value["credentials"]["claude"].clone();
        value["credentials"]
            .as_object_mut()
            .expect("credentials")
            .remove("claude");
        value["upstreams"]["anthropic"]["intercept"] = json!(["api.example.com:443"]);
        value["upstreams"]["Anthropic"] = value["upstreams"]["anthropic"].clone();
        value["upstreams"]
            .as_object_mut()
            .expect("upstreams")
            .remove("anthropic");
        value["clients"]["Harness"]["grants"][0]["upstream"] = json!("Anthropic");
        value["credentials"]["Claude"]["upstream"] = json!("Anthropic");
        value["state_dir"] = json!("state");
        value["listen"] = json!("192.0.2.1:8080");

        let Err(errors) = converted(value) else {
            panic!("multi-error fixture converted successfully");
        };
        let invalid_names = errors
            .0
            .iter()
            .filter(|error| matches!(error, ConfigError::InvalidName { .. }))
            .count();
        assert_eq!(invalid_names, 6);
        assert!(
            errors
                .0
                .iter()
                .any(|error| matches!(error, ConfigError::InvalidHost { .. }))
        );
        assert!(
            errors
                .0
                .iter()
                .any(|error| matches!(error, ConfigError::RelativeStateDir { .. }))
        );
        assert!(
            errors
                .0
                .iter()
                .any(|error| matches!(error, ConfigError::NonLoopbackListen { .. }))
        );
        assert_eq!(errors.0.len(), 9);
    }
}
