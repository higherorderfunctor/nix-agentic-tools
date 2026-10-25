use std::{
    collections::{BTreeMap, BTreeSet},
    net::SocketAddr,
    path::PathBuf,
};

use serde::Deserialize;

use crate::{
    error::{ConfigError, ConfigErrors, NameError},
    ids::{ClientId, CredentialId, GroupId, HostName, ProviderId},
    secret::SecretFile,
};

pub struct Config {
    clients: BTreeMap<ClientId, ClientConfig>,
    credentials: BTreeMap<CredentialId, CredentialConfig>,
    groups: BTreeMap<GroupId, GroupConfig>,
    listen: SocketAddr,
    providers: BTreeMap<ProviderId, ProviderConfig>,
    state_dir: PathBuf,
    unknown_hosts: UnknownHosts,
}

struct ClientConfig {
    grants: Vec<GroupId>,
    token_file: SecretFile,
}

struct CredentialConfig {
    auth: Auth,
    provider: ProviderId,
}

pub enum Auth {
    ApiKey { file: SecretFile },
    OauthBearer { file: SecretFile },
    OauthManaged,
}

struct GroupConfig {
    hosts: Vec<HostName>,
    members: BTreeMap<CredentialId, Vec<String>>,
    primary: CredentialId,
    protocol: Protocol,
}

struct ProviderConfig {
    endpoints: BTreeMap<Protocol, Endpoint>,
}

struct Endpoint {
    host: HostName,
    url: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Protocol {
    Anthropic,
    Openai,
}

impl Protocol {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "anthropic" => Some(Self::Anthropic),
            "openai" => Some(Self::Openai),
            _ => None,
        }
    }
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
    pub groups: BTreeMap<String, RawGroup>,
    pub listen: String,
    pub providers: BTreeMap<String, RawProvider>,
    pub state_dir: PathBuf,
    #[serde(default)]
    pub unknown_hosts: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawClient {
    pub grants: Vec<String>,
    pub token_file: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawCredential {
    pub auth: RawAuth,
    pub provider: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, tag = "type", rename_all = "snake_case")]
pub enum RawAuth {
    ApiKey { file: PathBuf },
    OauthBearer { file: PathBuf },
    OauthManaged {},
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawGroup {
    pub intercept: Vec<String>,
    pub members: BTreeMap<String, RawMember>,
    pub primary: String,
    pub protocol: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawMember {
    pub models: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawProvider {
    #[serde(default)]
    pub endpoints: BTreeMap<String, String>,
    #[serde(default)]
    pub preset: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum UnsupportedExecution {
    #[error("group {group} uses OpenAI, which serve does not support yet")]
    Openai { group: GroupId },
    #[error("group {group} has multiple members; model routing is not implemented")]
    MultipleMembers { group: GroupId },
    #[error("credential {credential} uses managed OAuth, which serve does not support yet")]
    ManagedOauth { credential: CredentialId },
    #[error("group {group} endpoint {url:?} differs from the intercepted original host")]
    Endpoint { group: GroupId, url: String },
}

impl Config {
    #[must_use]
    pub fn listen(&self) -> SocketAddr {
        self.listen
    }

    #[must_use]
    pub fn state_dir(&self) -> &std::path::Path {
        &self.state_dir
    }

    pub fn client_token_files(&self) -> impl Iterator<Item = (&ClientId, &SecretFile)> {
        self.clients
            .iter()
            .map(|(client, config)| (client, &config.token_file))
    }

    pub(crate) fn client_grants(&self) -> impl Iterator<Item = (&ClientId, &[GroupId])> {
        self.clients
            .iter()
            .map(|(client, config)| (client, config.grants.as_slice()))
    }

    /// Configured but ungranted credentials remain unloaded.
    pub fn granted_credentials(&self) -> impl Iterator<Item = (&CredentialId, &Auth)> {
        let granted: BTreeSet<CredentialId> = self
            .clients
            .values()
            .flat_map(|client| &client.grants)
            .filter_map(|group| self.groups.get(group))
            .flat_map(|group| group.members.keys().cloned())
            .collect();
        self.credentials.iter().filter_map(move |(id, credential)| {
            granted.contains(id).then_some((id, &credential.auth))
        })
    }

    pub(crate) fn intercepted_hosts(&self) -> impl Iterator<Item = (&HostName, &GroupId)> {
        self.groups
            .iter()
            .flat_map(|(group_id, group)| group.hosts.iter().map(move |host| (host, group_id)))
    }

    pub(crate) fn group_primary(&self, group: &GroupId) -> Option<&CredentialId> {
        self.groups.get(group).map(|config| &config.primary)
    }

    pub(crate) fn unknown_hosts(&self) -> UnknownHosts {
        self.unknown_hosts
    }

    /// Refuse active routes whose configured behavior the current transport cannot execute.
    ///
    /// # Errors
    /// Returns the first active group with unsupported protocol, membership, auth or endpoint.
    pub fn validate_executable(&self) -> Result<(), UnsupportedExecution> {
        let active: BTreeSet<&GroupId> = self
            .clients
            .values()
            .flat_map(|client| &client.grants)
            .collect();
        for group_id in active {
            let Some(group) = self.groups.get(group_id) else {
                continue;
            };
            if group.protocol != Protocol::Anthropic {
                return Err(UnsupportedExecution::Openai {
                    group: group_id.clone(),
                });
            }
            if group.members.len() != 1 {
                return Err(UnsupportedExecution::MultipleMembers {
                    group: group_id.clone(),
                });
            }
            let Some(credential) = self.credentials.get(&group.primary) else {
                continue;
            };
            if matches!(credential.auth, Auth::OauthManaged) {
                return Err(UnsupportedExecution::ManagedOauth {
                    credential: group.primary.clone(),
                });
            }
            let Some(endpoint) = self
                .providers
                .get(&credential.provider)
                .and_then(|provider| provider.endpoints.get(&group.protocol))
            else {
                continue;
            };
            if group
                .hosts
                .iter()
                .any(|host| endpoint.host != *host || endpoint.url != format!("https://{host}"))
            {
                return Err(UnsupportedExecution::Endpoint {
                    group: group_id.clone(),
                    url: endpoint.url.clone(),
                });
            }
        }
        Ok(())
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
        let state_dir = if raw.state_dir.is_absolute() {
            Some(raw.state_dir.clone())
        } else {
            errors.push(ConfigError::RelativeStateDir {
                path: raw.state_dir.clone(),
            });
            None
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

        let providers = parse_providers(&raw, &mut errors);
        let credentials = parse_credentials(&raw, &mut errors);
        let groups = parse_groups(&raw, &mut errors);
        let clients = parse_clients(&raw, &mut errors);
        validate_references(&raw, &providers, &mut errors);

        match (listen, state_dir, unknown_hosts) {
            (Some(listen), Some(state_dir), Some(unknown_hosts)) if errors.is_empty() => Ok(Self {
                clients,
                credentials,
                groups,
                listen,
                providers,
                state_dir,
                unknown_hosts,
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

fn parse_clients(
    raw: &RawConfig,
    errors: &mut Vec<ConfigError>,
) -> BTreeMap<ClientId, ClientConfig> {
    let mut clients = BTreeMap::new();
    for (raw_id, raw_client) in &raw.clients {
        let id = ClientId::try_from(raw_id.as_str())
            .map_err(|error| errors.push(invalid_name("client", error)))
            .ok();
        let token_file = SecretFile::try_from(raw_client.token_file.clone())
            .map_err(|_| {
                errors.push(ConfigError::RelativeTokenFile {
                    client: raw_id.clone(),
                    path: raw_client.token_file.clone(),
                });
            })
            .ok();
        if raw_client.grants.is_empty() {
            errors.push(ConfigError::EmptyGrants {
                client: raw_id.clone(),
            });
        }
        let grants: Vec<_> = raw_client
            .grants
            .iter()
            .filter_map(|grant| {
                GroupId::try_from(grant.as_str())
                    .map_err(|error| errors.push(invalid_name("group", error)))
                    .ok()
            })
            .collect();
        if let (Some(id), Some(token_file)) = (id, token_file) {
            clients.insert(id, ClientConfig { grants, token_file });
        }
    }
    clients
}

fn parse_credentials(
    raw: &RawConfig,
    errors: &mut Vec<ConfigError>,
) -> BTreeMap<CredentialId, CredentialConfig> {
    let mut credentials = BTreeMap::new();
    for (raw_id, raw_credential) in &raw.credentials {
        let id = CredentialId::try_from(raw_id.as_str())
            .map_err(|error| errors.push(invalid_name("credential", error)))
            .ok();
        let provider = ProviderId::try_from(raw_credential.provider.as_str())
            .map_err(|error| errors.push(invalid_name("provider", error)))
            .ok();
        let auth = match &raw_credential.auth {
            RawAuth::OauthManaged {} => Some(Auth::OauthManaged),
            RawAuth::ApiKey { file } | RawAuth::OauthBearer { file } => {
                if let Ok(file) = SecretFile::try_from(file.clone()) {
                    Some(match raw_credential.auth {
                        RawAuth::ApiKey { .. } => Auth::ApiKey { file },
                        _ => Auth::OauthBearer { file },
                    })
                } else {
                    errors.push(ConfigError::RelativeAuthFile {
                        credential: raw_id.clone(),
                        path: file.clone(),
                    });
                    None
                }
            }
        };
        if let (Some(id), Some(provider), Some(auth)) = (id, provider, auth) {
            credentials.insert(id, CredentialConfig { auth, provider });
        }
    }
    credentials
}

fn parse_groups(raw: &RawConfig, errors: &mut Vec<ConfigError>) -> BTreeMap<GroupId, GroupConfig> {
    let mut groups = BTreeMap::new();
    let mut intercepted = BTreeMap::<HostName, String>::new();
    for (raw_id, raw_group) in &raw.groups {
        let id = GroupId::try_from(raw_id.as_str())
            .map_err(|error| errors.push(invalid_name("group", error)))
            .ok();
        let primary = CredentialId::try_from(raw_group.primary.as_str())
            .map_err(|error| errors.push(invalid_name("credential", error)))
            .ok();
        let protocol = Protocol::parse(&raw_group.protocol);
        if protocol.is_none() {
            errors.push(ConfigError::UnsupportedProtocol {
                group: raw_id.clone(),
                protocol: raw_group.protocol.clone(),
            });
        }
        if raw_group.members.is_empty() {
            errors.push(ConfigError::EmptyGroupMembers {
                group: raw_id.clone(),
            });
        }
        let mut members = BTreeMap::new();
        let mut model_owners = BTreeMap::<&str, &str>::new();
        for (raw_credential, member) in &raw_group.members {
            if raw_credential != &raw_group.primary && member.models.is_empty() {
                errors.push(ConfigError::EmptyNonPrimaryModels {
                    group: raw_id.clone(),
                    credential: raw_credential.clone(),
                });
            }
            for model in &member.models {
                if model.is_empty() {
                    errors.push(ConfigError::EmptyModel {
                        group: raw_id.clone(),
                        credential: raw_credential.clone(),
                    });
                } else if let Some(first) = model_owners.insert(model, raw_credential) {
                    errors.push(ConfigError::DuplicateModel {
                        group: raw_id.clone(),
                        model: model.clone(),
                        first: first.to_owned(),
                        second: raw_credential.clone(),
                    });
                }
            }
            match CredentialId::try_from(raw_credential.as_str()) {
                Ok(id) => {
                    members.insert(id, member.models.clone());
                }
                Err(error) => errors.push(invalid_name("credential", error)),
            }
        }
        if !raw_group.members.contains_key(&raw_group.primary) {
            errors.push(ConfigError::PrimaryNotMember {
                group: raw_id.clone(),
                primary: raw_group.primary.clone(),
            });
        }
        let mut hosts = Vec::new();
        for raw_host in &raw_group.intercept {
            match HostName::try_from(raw_host.as_str()) {
                Ok(host) => {
                    if let Some(first) = intercepted.insert(host.clone(), raw_id.clone()) {
                        errors.push(ConfigError::DuplicateInterceptHost {
                            host: raw_host.clone(),
                            first,
                            second: raw_id.clone(),
                        });
                    }
                    hosts.push(host);
                }
                Err(_) => errors.push(ConfigError::InvalidHost {
                    group: raw_id.clone(),
                    host: raw_host.clone(),
                }),
            }
        }
        if let (Some(id), Some(primary), Some(protocol)) = (id, primary, protocol) {
            groups.insert(
                id,
                GroupConfig {
                    hosts,
                    members,
                    primary,
                    protocol,
                },
            );
        }
    }
    groups
}

fn parse_providers(
    raw: &RawConfig,
    errors: &mut Vec<ConfigError>,
) -> BTreeMap<ProviderId, ProviderConfig> {
    let mut providers = BTreeMap::new();
    for (raw_id, raw_provider) in &raw.providers {
        let id = ProviderId::try_from(raw_id.as_str())
            .map_err(|error| errors.push(invalid_name("provider", error)))
            .ok();
        let mut endpoints = BTreeMap::new();
        match raw_provider.preset.as_deref() {
            Some("claude") => {
                endpoints.insert(
                    "anthropic".to_owned(),
                    "https://api.anthropic.com".to_owned(),
                );
            }
            Some("zai") => {
                endpoints.insert(
                    "anthropic".to_owned(),
                    "https://api.z.ai/api/anthropic".to_owned(),
                );
                endpoints.insert(
                    "openai".to_owned(),
                    "https://api.z.ai/api/coding/paas/v4".to_owned(),
                );
            }
            Some(preset) => errors.push(ConfigError::UnknownPreset {
                provider: raw_id.clone(),
                preset: preset.to_owned(),
            }),
            None => {}
        }
        endpoints.extend(raw_provider.endpoints.clone());
        if endpoints.is_empty() {
            errors.push(ConfigError::EmptyProviderEndpoints {
                provider: raw_id.clone(),
            });
        }
        let mut resolved = BTreeMap::new();
        for (raw_protocol, url) in endpoints {
            let Some(protocol) = Protocol::parse(&raw_protocol) else {
                errors.push(ConfigError::UnsupportedProtocol {
                    group: format!("provider {raw_id}"),
                    protocol: raw_protocol,
                });
                continue;
            };
            match parse_endpoint(&url) {
                Some(host) => {
                    resolved.insert(protocol, Endpoint { host, url });
                }
                None => errors.push(ConfigError::InvalidEndpoint {
                    provider: raw_id.clone(),
                    protocol: raw_protocol,
                }),
            }
        }
        if let Some(id) = id {
            providers.insert(
                id,
                ProviderConfig {
                    endpoints: resolved,
                },
            );
        }
    }
    providers
}

fn parse_endpoint(url: &str) -> Option<HostName> {
    let rest = url.strip_prefix("https://")?;
    let (host, path) = rest.split_once('/').unwrap_or((rest, ""));
    if host.contains(['@', ':', '?', '#']) || !valid_uri_path(path) {
        return None;
    }
    HostName::try_from(host).ok()
}

fn valid_uri_path(path: &str) -> bool {
    let mut bytes = path.bytes();
    while let Some(byte) = bytes.next() {
        match byte {
            b'%' => {
                if !bytes.next().is_some_and(|digit| digit.is_ascii_hexdigit())
                    || !bytes.next().is_some_and(|digit| digit.is_ascii_hexdigit())
                {
                    return false;
                }
            }
            b'/' | b':' | b'@' | b'!' | b'$' | b'&' | b'\'' | b'(' | b')' | b'*' | b'+' | b','
            | b';' | b'=' | b'-' | b'.' | b'_' | b'~' => {}
            byte if byte.is_ascii_alphanumeric() => {}
            _ => return false,
        }
    }
    true
}

fn validate_references(
    raw: &RawConfig,
    providers: &BTreeMap<ProviderId, ProviderConfig>,
    errors: &mut Vec<ConfigError>,
) {
    for (credential_id, credential) in &raw.credentials {
        if !raw.providers.contains_key(&credential.provider) {
            errors.push(ConfigError::UnknownCredentialProvider {
                credential: credential_id.clone(),
                provider: credential.provider.clone(),
            });
        }
    }
    for (group_id, group) in &raw.groups {
        for credential_id in group.members.keys() {
            let Some(credential) = raw.credentials.get(credential_id) else {
                errors.push(ConfigError::UnknownGroupCredential {
                    group: group_id.clone(),
                    credential: credential_id.clone(),
                });
                continue;
            };
            if credential_id != &group.primary
                && matches!(credential.auth, RawAuth::OauthManaged {})
            {
                errors.push(ConfigError::NonPrimaryManagedOauth {
                    credential: credential_id.clone(),
                    group: group_id.clone(),
                });
            }
            if let (Some(provider_id), Some(protocol)) = (
                ProviderId::try_from(credential.provider.as_str()).ok(),
                Protocol::parse(&group.protocol),
            ) && let Some(provider) = providers.get(&provider_id)
                && !provider.endpoints.contains_key(&protocol)
            {
                errors.push(ConfigError::MissingProviderProtocol {
                    group: group_id.clone(),
                    credential: credential_id.clone(),
                    provider: credential.provider.clone(),
                    protocol: group.protocol.clone(),
                });
            }
        }
    }
    for (client_id, client) in &raw.clients {
        for group in &client.grants {
            if !raw.groups.contains_key(group) {
                errors.push(ConfigError::UnknownGrantGroup {
                    client: client_id.clone(),
                    group: group.clone(),
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn valid_raw() -> Value {
        json!({
            "clients": {"harness": {"grants": ["anthropic"], "token_file": "/run/airlock/harness"}},
            "credentials": {
                "claude": {"auth": {"type": "oauth_bearer", "file": "/run/airlock/claude"}, "provider": "claude"},
                "zai": {"auth": {"type": "api_key", "file": "/run/airlock/zai"}, "provider": "zai"}
            },
            "groups": {"anthropic": {
                "intercept": ["api.anthropic.com"],
                "members": {"claude": {"models": []}, "zai": {"models": ["glm-4.7"]}},
                "primary": "claude", "protocol": "anthropic"
            }},
            "listen": "127.0.0.1:8080",
            "providers": {"claude": {"preset": "claude"}, "zai": {"preset": "zai"}},
            "state_dir": "/var/lib/airlock"
        })
    }

    fn converted(value: Value) -> Result<Config, ConfigErrors> {
        Config::try_from(serde_json::from_value::<RawConfig>(value).expect("raw JSON"))
    }

    fn has_error(value: Value, predicate: impl Fn(&ConfigError) -> bool) {
        let Err(errors) = converted(value) else {
            panic!("invalid fixture accepted");
        };
        assert!(errors.0.iter().any(predicate), "missing error: {errors:?}");
    }

    #[test]
    fn presets_and_explicit_overrides_resolve_to_the_same_endpoints() {
        let baseline = converted(valid_raw()).expect("valid config");
        let mut overridden = valid_raw();
        overridden["providers"]["zai"]["endpoints"] = json!({
            "anthropic": "https://api.z.ai/api/anthropic",
            "openai": "https://api.z.ai/api/coding/paas/v4"
        });
        let overridden = converted(overridden).expect("valid override");
        let id = ProviderId::try_from("zai").expect("id");
        let endpoint =
            |config: &Config, protocol| config.providers[&id].endpoints[&protocol].url.clone();
        for protocol in [Protocol::Anthropic, Protocol::Openai] {
            assert_eq!(
                endpoint(&baseline, protocol),
                endpoint(&overridden, protocol)
            );
        }
        assert_eq!(baseline.granted_credentials().count(), 2);
        assert_eq!(
            baseline.state_dir(),
            std::path::Path::new("/var/lib/airlock")
        );
        assert_eq!(
            baseline.clients[&ClientId::try_from("harness").expect("id")]
                .token_file
                .path(),
            std::path::Path::new("/run/airlock/harness")
        );
        assert_eq!(baseline.unknown_hosts(), UnknownHosts::Tunnel);
    }

    #[test]
    fn endpoint_paths_require_uri_syntax_without_normalizing_valid_escapes() {
        for url in [
            "https://api.anthropic.com/\ninvalid",
            "https://api.anthropic.com/\0invalid",
            "https://api.anthropic.com/a b",
            "https://api.anthropic.com/%zz",
        ] {
            let mut value = valid_raw();
            value["providers"]["claude"]["endpoints"] = json!({"anthropic": url});
            has_error(value, |error| {
                matches!(error, ConfigError::InvalidEndpoint { .. })
            });
        }

        let mut value = valid_raw();
        let url = "https://api.z.ai/api/%76%31";
        value["providers"]["zai"]["endpoints"] = json!({"anthropic": url});
        let config = converted(value).expect("valid percent-encoded endpoint");
        let id = ProviderId::try_from("zai").expect("id");
        assert_eq!(
            config.providers[&id].endpoints[&Protocol::Anthropic].url,
            url
        );
    }

    #[test]
    fn primary_owns_undeclared_models_and_unused_secrets_stay_inert() {
        let mut raw = valid_raw();
        raw["groups"]["anthropic"]["members"] = json!({"claude": {"models": []}});
        raw["credentials"]["unused"] =
            json!({"auth": {"type": "api_key", "file": "/missing"}, "provider": "zai"});
        let config = converted(raw).expect("valid config");
        assert_eq!(config.granted_credentials().count(), 1);
        assert!(config.validate_executable().is_ok());
    }

    #[test]
    fn invalid_membership_and_references_are_rejected() {
        let mut value = valid_raw();
        value["groups"]["anthropic"]["members"]["zai"]["models"] = json!(["x", "x"]);
        has_error(value, |error| {
            matches!(error, ConfigError::DuplicateModel { .. })
        });

        let mut value = valid_raw();
        value["groups"]["anthropic"]["primary"] = json!("missing");
        has_error(value, |error| {
            matches!(error, ConfigError::PrimaryNotMember { .. })
        });

        let mut value = valid_raw();
        value["groups"]["anthropic"]["members"]["missing"] = json!({"models": ["x"]});
        has_error(value, |error| {
            matches!(error, ConfigError::UnknownGroupCredential { .. })
        });

        let mut value = valid_raw();
        value["providers"]["zai"] =
            json!({"endpoints": {"openai": "https://api.z.ai/api/coding/paas/v4"}});
        has_error(value, |error| {
            matches!(error, ConfigError::MissingProviderProtocol { .. })
        });

        let mut value = valid_raw();
        value["clients"]["harness"]["grants"] = json!(["missing"]);
        has_error(value, |error| {
            matches!(error, ConfigError::UnknownGrantGroup { .. })
        });

        let mut value = valid_raw();
        value["credentials"]["zai"]["auth"] = json!({"type": "oauth_managed"});
        has_error(value, |error| {
            matches!(error, ConfigError::NonPrimaryManagedOauth { .. })
        });
    }

    fn has_replaced_error(
        pointer: &str,
        replacement: Value,
        predicate: impl Fn(&ConfigError) -> bool,
    ) {
        let mut value = valid_raw();
        let (parent, key) = pointer.rsplit_once('/').expect("fixture pointer");
        value
            .pointer_mut(parent)
            .expect("fixture parent")
            .as_object_mut()
            .expect("fixture object")
            .insert(key.to_owned(), replacement);
        has_error(value, predicate);
    }

    #[test]
    fn transport_and_secret_shape_errors_remain_guarded() {
        has_replaced_error("/clients/harness/grants", json!([]), |error| {
            matches!(error, ConfigError::EmptyGrants { .. })
        });
        has_replaced_error("/listen", json!("127.0.0.1"), |error| {
            matches!(error, ConfigError::InvalidListen { .. })
        });
        has_replaced_error("/listen", json!("192.0.2.1:8080"), |error| {
            matches!(error, ConfigError::NonLoopbackListen { .. })
        });
        has_replaced_error("/state_dir", json!("relative"), |error| {
            matches!(error, ConfigError::RelativeStateDir { .. })
        });
        has_replaced_error("/unknown_hosts", json!("forward"), |error| {
            matches!(error, ConfigError::InvalidUnknownHostPolicy { .. })
        });
        has_replaced_error("/clients/harness/token_file", json!("relative"), |error| {
            matches!(error, ConfigError::RelativeTokenFile { .. })
        });
        has_replaced_error(
            "/credentials/claude/auth/file",
            json!("relative"),
            |error| matches!(error, ConfigError::RelativeAuthFile { .. }),
        );
        has_replaced_error(
            "/groups/anthropic/intercept",
            json!(["api.example.com:443"]),
            |error| matches!(error, ConfigError::InvalidHost { .. }),
        );
        has_replaced_error("/credentials/claude/provider", json!("missing"), |error| {
            matches!(error, ConfigError::UnknownCredentialProvider { .. })
        });
        has_replaced_error(
            "/providers/claude/endpoints",
            json!({"anthropic": "http://api.anthropic.com"}),
            |error| matches!(error, ConfigError::InvalidEndpoint { .. }),
        );

        let mut value = valid_raw();
        value["groups"]["other"] = json!({"intercept": ["api.anthropic.com"], "members": {"claude": {"models": []}}, "primary": "claude", "protocol": "anthropic"});
        has_error(value, |error| {
            matches!(error, ConfigError::DuplicateInterceptHost { .. })
        });
        let mut value = valid_raw();
        value["clients"]["Harness"] = value["clients"]["harness"].take();
        value["clients"]
            .as_object_mut()
            .expect("object")
            .remove("harness");
        has_error(value, |error| {
            matches!(error, ConfigError::InvalidName { .. })
        });
    }

    #[test]
    fn independent_errors_are_collected() {
        let mut value = valid_raw();
        value["listen"] = json!("192.0.2.1:8080");
        value["state_dir"] = json!("relative");
        value["groups"]["anthropic"]["intercept"] = json!(["bad:443"]);
        let Err(errors) = converted(value) else {
            panic!("invalid fixture accepted");
        };
        assert_eq!(errors.0.len(), 3);
        assert!(
            errors
                .0
                .iter()
                .any(|error| matches!(error, ConfigError::NonLoopbackListen { .. }))
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
                .any(|error| matches!(error, ConfigError::InvalidHost { .. }))
        );
    }

    #[test]
    fn unsupported_execution_is_explicit() {
        let config = converted(valid_raw()).expect("valid multiplex config");
        assert!(matches!(
            config.validate_executable(),
            Err(UnsupportedExecution::MultipleMembers { .. })
        ));

        let mut value = valid_raw();
        value["groups"]["anthropic"]["members"] = json!({"claude": {"models": []}});
        value["credentials"]["claude"]["auth"] = json!({"type": "oauth_managed"});
        let config = converted(value).expect("valid managed OAuth config");
        assert!(matches!(
            config.validate_executable(),
            Err(UnsupportedExecution::ManagedOauth { .. })
        ));

        let mut value = valid_raw();
        value["groups"]["anthropic"]["members"] = json!({"claude": {"models": []}});
        value["providers"]["claude"]["endpoints"] = json!({"anthropic": "https://other.example"});
        let config = converted(value).expect("valid override config");
        assert!(matches!(
            config.validate_executable(),
            Err(UnsupportedExecution::Endpoint { .. })
        ));

        let mut value = valid_raw();
        value["groups"]["openai"] = json!({
            "intercept": ["api.z.ai"],
            "members": {"zai": {"models": []}},
            "primary": "zai", "protocol": "openai"
        });
        value["clients"]["harness"]["grants"] = json!(["openai"]);
        let config = converted(value).expect("valid OpenAI shape");
        assert!(matches!(
            config.validate_executable(),
            Err(UnsupportedExecution::Openai { .. })
        ));
    }

    #[test]
    fn unknown_fields_are_rejected() {
        let mut value = valid_raw();
        value["groups"]["anthropic"]["unexpected"] = json!(true);
        assert!(serde_json::from_value::<RawConfig>(value).is_err());
        let mut value = valid_raw();
        value["credentials"]["claude"]["auth"]["unexpected"] = json!(true);
        assert!(serde_json::from_value::<RawConfig>(value).is_err());

        for auth in [
            json!({"type": "oauth_managed", "file": "/obvious-fake-secret"}),
            json!({"type": "oauth_managed", "unexpected": true}),
        ] {
            let mut value = valid_raw();
            value["credentials"]["claude"]["auth"] = auth;
            assert!(serde_json::from_value::<RawConfig>(value).is_err());
        }
    }
}
