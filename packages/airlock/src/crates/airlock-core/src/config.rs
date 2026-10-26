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
    storage::StorageIdentities,
};

#[derive(Clone)]
pub struct Config {
    clients: BTreeMap<ClientId, ClientConfig>,
    control: Option<ControlConfig>,
    credentials: BTreeMap<CredentialId, CredentialConfig>,
    groups: BTreeMap<GroupId, GroupConfig>,
    listen: SocketAddr,
    providers: BTreeMap<ProviderId, ProviderConfig>,
    state_dir: PathBuf,
    unknown_hosts: UnknownHosts,
    usage_credentials: BTreeSet<CredentialId>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Route<'config> {
    pub credential: &'config CredentialId,
    pub endpoint: &'config str,
    pub is_primary: bool,
    pub primary_credential: &'config CredentialId,
}

#[derive(Clone)]
struct ClientConfig {
    grants: Vec<GroupId>,
    token_file: SecretFile,
}

/// Optional loopback read-only control listener.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ControlConfig {
    listen: SocketAddr,
    read_token_file: SecretFile,
}

impl ControlConfig {
    #[must_use]
    pub fn listen(&self) -> SocketAddr {
        self.listen
    }

    #[must_use]
    pub fn read_token_file(&self) -> &SecretFile {
        &self.read_token_file
    }
}

#[derive(Clone)]
struct CredentialConfig {
    auth: Auth,
    provider: ProviderId,
    usage_account_id: Option<String>,
}

#[derive(Clone)]
pub enum Auth {
    ApiKey { file: SecretFile },
    OauthBearer { file: SecretFile },
    OauthManaged,
}

#[derive(Clone)]
struct GroupConfig {
    hosts: Vec<HostName>,
    members: BTreeMap<CredentialId, Vec<String>>,
    primary: CredentialId,
    protocol: Protocol,
}

#[derive(Clone)]
struct ProviderConfig {
    claude_preset: bool,
    codex_preset: bool,
    endpoints: BTreeMap<Protocol, Endpoint>,
    zai_preset: bool,
}

#[derive(Clone)]
struct Endpoint {
    url: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Protocol {
    Anthropic,
    Openai,
}

impl Protocol {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic",
            Self::Openai => "openai",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "anthropic" => Some(Self::Anthropic),
            "openai" => Some(Self::Openai),
            _ => None,
        }
    }
}

impl Auth {
    const fn kind(&self) -> CredentialAuthKind {
        match self {
            Self::ApiKey { .. } => CredentialAuthKind::ApiKey,
            Self::OauthBearer { .. } => CredentialAuthKind::OauthBearer,
            Self::OauthManaged => CredentialAuthKind::OauthManaged,
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
    #[serde(default)]
    pub control: Option<RawControl>,
    pub credentials: BTreeMap<String, RawCredential>,
    pub groups: BTreeMap<String, RawGroup>,
    pub listen: String,
    pub providers: BTreeMap<String, RawProvider>,
    pub state_dir: PathBuf,
    #[serde(default)]
    pub usage: RawUsage,
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
pub struct RawControl {
    pub listen: String,
    pub read_token_file: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawCredential {
    #[serde(default)]
    pub account_id: Option<String>,
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

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawUsage {
    #[serde(default)]
    pub credentials: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CredentialAuthKind {
    ApiKey,
    OauthBearer,
    OauthManaged,
}

#[derive(Debug, PartialEq, Eq)]
pub struct UsageCredential {
    pub account_id: Option<String>,
    pub auth: CredentialAuthKind,
    pub client: Option<ClientId>,
    pub explicit_usage_selection: bool,
    pub group: Option<GroupId>,
    pub id: CredentialId,
    pub provider: ProviderId,
    pub provider_kind: UsageProviderKind,
    pub routes: Vec<UsageRoute>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UsageProviderKind {
    Claude,
    Codex,
    Zai,
}

#[derive(Debug, PartialEq, Eq)]
pub struct UsageRoute {
    pub client: ClientId,
    pub group: GroupId,
    pub models: Vec<String>,
    pub primary: bool,
    pub protocol: &'static str,
}

#[derive(Debug, thiserror::Error)]
pub enum UnsupportedExecution {
    #[error("group {group} uses OpenAI, which serve does not support yet")]
    Openai { group: GroupId },
    #[error("credential {credential} has an unsupported managed OAuth route")]
    ManagedOauth { credential: CredentialId },
}

impl Config {
    #[must_use]
    pub fn listen(&self) -> SocketAddr {
        self.listen
    }

    #[must_use]
    pub fn control(&self) -> Option<ControlConfig> {
        self.control.clone()
    }

    /// Loads the dedicated control token and rejects reuse of a proxy client token.
    ///
    /// Only client token files are opened. In particular, ungranted credential and group auth
    /// files remain unread so the control plane cannot destroy lazy secret loading.
    ///
    /// # Errors
    /// Returns the first secret-loading error, or `ControlTokenReuse` when material matches.
    pub fn load_control_token(&self) -> Result<crate::secret::Secret, crate::error::SecretError> {
        let control = self
            .control
            .as_ref()
            .ok_or(crate::error::SecretError::ControlNotConfigured)?;
        let token = control.read_token_file.load_bounded_regular(8192)?;
        for (_, client_token) in self.client_token_files() {
            if client_token
                .load_bounded_regular(8192)?
                .matches(token.as_str().as_bytes())
            {
                return Err(crate::error::SecretError::ControlTokenReuse);
            }
        }
        Ok(token)
    }

    #[must_use]
    pub fn state_dir(&self) -> &std::path::Path {
        &self.state_dir
    }

    /// Projects configured identities for durable state initialization.
    ///
    /// Configuration validation has already established all references. The timestamp belongs to
    /// the caller so startup remains deterministic and testable.
    #[must_use]
    pub fn storage_identities(&self, inserted_at_unix: i64) -> StorageIdentities {
        StorageIdentities {
            clients: self.clients.keys().cloned().collect(),
            credentials: self
                .credentials
                .iter()
                .map(|(id, credential)| (id.clone(), credential.provider.clone()))
                .collect(),
            group_members: self
                .groups
                .iter()
                .flat_map(|(group, config)| {
                    config
                        .members
                        .keys()
                        .map(move |credential| (group.clone(), credential.clone()))
                })
                .collect(),
            groups: self.groups.keys().cloned().collect(),
            inserted_at_unix,
            providers: self.providers.keys().cloned().collect(),
        }
    }

    pub fn client_token_files(&self) -> impl Iterator<Item = (&ClientId, &SecretFile)> {
        self.clients
            .iter()
            .map(|(client, config)| (client, &config.token_file))
    }

    /// Projects every credential the quota collector may read, with its routing eligibility.
    ///
    /// Explicit out-of-band credentials such as Codex have no protocol or model eligibility.
    #[must_use]
    pub fn usage_credentials(&self) -> Vec<UsageCredential> {
        self.project_usage_credentials(true)
    }

    /// Collector metadata excludes report-only routes and model lists.
    #[must_use]
    pub fn usage_collector_credentials(&self) -> Vec<UsageCredential> {
        self.project_usage_credentials(false)
    }

    fn project_usage_credentials(&self, include_routes: bool) -> Vec<UsageCredential> {
        let mut selected = self.usage_credentials.clone();
        selected.extend(
            self.clients
                .values()
                .flat_map(|client| &client.grants)
                .filter_map(|group| self.groups.get(group))
                .flat_map(|group| group.members.keys().cloned()),
        );
        selected
            .into_iter()
            .filter_map(|id| {
                let credential = self.credentials.get(&id)?;
                let provider = self.providers.get(&credential.provider)?;
                let provider_kind = if provider.claude_preset {
                    UsageProviderKind::Claude
                } else if provider.zai_preset {
                    UsageProviderKind::Zai
                } else if provider.codex_preset {
                    UsageProviderKind::Codex
                } else {
                    return None;
                };
                let (client, group) = self.sole_usage_route(&id);
                let routes = if include_routes {
                    self.usage_routes(&id)
                } else {
                    Vec::new()
                };
                Some(UsageCredential {
                    account_id: credential.usage_account_id.clone(),
                    auth: credential.auth.kind(),
                    client,
                    explicit_usage_selection: self.usage_credentials.contains(&id),
                    group,
                    id: id.clone(),
                    provider: credential.provider.clone(),
                    provider_kind,
                    routes,
                })
            })
            .collect()
    }

    fn sole_usage_route(&self, credential: &CredentialId) -> (Option<ClientId>, Option<GroupId>) {
        let mut seen = BTreeSet::new();
        let mut routes = self
            .clients
            .iter()
            .flat_map(|(client, config)| {
                config.grants.iter().filter_map(move |group| {
                    self.groups
                        .get(group)?
                        .members
                        .contains_key(credential)
                        .then_some((client, group))
                })
            })
            .filter(|route| seen.insert(*route));
        match (routes.next(), routes.next()) {
            (Some((client, group)), None) => (Some(client.clone()), Some(group.clone())),
            _ => (None, None),
        }
    }

    /// Groups reachable by at least one granted client.
    #[must_use]
    pub fn usage_groups(&self) -> BTreeSet<GroupId> {
        self.clients
            .values()
            .flat_map(|client| &client.grants)
            .filter(|group| self.groups.contains_key(group))
            .cloned()
            .collect()
    }

    fn usage_routes(&self, credential: &CredentialId) -> Vec<UsageRoute> {
        self.clients
            .iter()
            .flat_map(|(client, config)| {
                config
                    .grants
                    .iter()
                    .map(move |group| (client.clone(), group.clone()))
            })
            .collect::<BTreeSet<_>>()
            .into_iter()
            .filter_map(|(client, group)| {
                let config = self.groups.get(&group)?;
                Some(UsageRoute {
                    client,
                    group,
                    models: config.members.get(credential)?.clone(),
                    primary: config.primary == *credential,
                    protocol: config.protocol.as_str(),
                })
            })
            .collect()
    }
    #[must_use]
    pub fn credential_provider(&self, credential: &CredentialId) -> Option<&ProviderId> {
        self.credentials
            .get(credential)
            .map(|entry| &entry.provider)
    }

    /// Only the daemon's collector calls this; the read-only CLI never loads it.
    #[must_use]
    pub fn usage_auth(&self, credential: &CredentialId) -> Option<&Auth> {
        self.credentials.get(credential).map(|config| &config.auth)
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

    #[must_use]
    pub fn managed_provider(&self, credential: &CredentialId) -> Option<&ProviderId> {
        self.credentials
            .get(credential)
            .and_then(|entry| matches!(entry.auth, Auth::OauthManaged).then_some(&entry.provider))
    }

    #[must_use]
    pub fn managed_host_allowed(&self, group: &GroupId, host: &HostName) -> bool {
        if host.as_ref() == "platform.claude.com" {
            return true;
        }
        self.route(group, None)
            .and_then(|route| route.endpoint.strip_prefix("https://"))
            .and_then(|authority| authority.split('/').next())
            .and_then(|authority| authority.split(':').next())
            .is_some_and(|endpoint_host| endpoint_host == host.as_ref())
    }

    #[must_use]
    pub fn oauth_token_host_allowed(&self, group: &GroupId, host: &HostName) -> bool {
        host.as_ref() == "platform.claude.com"
            || (host.as_ref() != "api.anthropic.com" && self.managed_host_allowed(group, host))
    }

    #[must_use]
    pub fn has_active_managed_oauth(&self) -> bool {
        self.granted_credentials()
            .any(|(_, auth)| matches!(auth, Auth::OauthManaged))
    }

    pub(crate) fn intercepted_hosts(&self) -> impl Iterator<Item = (&HostName, &GroupId)> {
        self.groups
            .iter()
            .flat_map(|(group_id, group)| group.hosts.iter().map(move |host| (host, group_id)))
    }

    /// Selects one credential and its protocol endpoint. Unclaimed models belong to the primary.
    #[must_use]
    pub fn route(&self, group: &GroupId, model: Option<&str>) -> Option<Route<'_>> {
        let group = self.groups.get(group)?;
        let credential_id = model
            .and_then(|model| {
                group.members.iter().find_map(|(id, models)| {
                    models
                        .iter()
                        .any(|candidate| candidate == model)
                        .then_some(id)
                })
            })
            .unwrap_or(&group.primary);
        let credential = self.credentials.get(credential_id)?;
        let endpoint = self
            .providers
            .get(&credential.provider)?
            .endpoints
            .get(&group.protocol)?;
        Some(Route {
            credential: credential_id,
            endpoint: endpoint.url.as_str(),
            is_primary: credential_id == &group.primary,
            primary_credential: &group.primary,
        })
    }

    /// The `ToolSearch` spelling shim belongs to the selected z.ai Anthropic preset.
    #[must_use]
    pub fn zai_anthropic(&self, group: &GroupId, credential: &CredentialId) -> bool {
        self.groups.get(group).is_some_and(|group| {
            group.protocol == Protocol::Anthropic
                && self
                    .credentials
                    .get(credential)
                    .and_then(|credential| self.providers.get(&credential.provider))
                    .is_some_and(|provider| provider.zai_preset)
        })
    }

    pub(crate) fn unknown_hosts(&self) -> UnknownHosts {
        self.unknown_hosts
    }

    /// Refuse active routes whose configured behavior the current transport cannot execute.
    ///
    /// # Errors
    /// Returns the first active group with unsupported protocol or auth.
    pub fn validate_executable(&self) -> Result<(), UnsupportedExecution> {
        let active: BTreeSet<&GroupId> = self
            .clients
            .values()
            .flat_map(|client| &client.grants)
            .collect();
        let mut managed_owners = BTreeSet::new();
        for group_id in active {
            let Some(group) = self.groups.get(group_id) else {
                continue;
            };
            if group.protocol != Protocol::Anthropic {
                return Err(UnsupportedExecution::Openai {
                    group: group_id.clone(),
                });
            }
            for credential_id in group.members.keys() {
                let Some(credential) = self.credentials.get(credential_id) else {
                    continue;
                };
                if matches!(credential.auth, Auth::OauthManaged)
                    && (credential_id != &group.primary
                        || !self
                            .providers
                            .get(&credential.provider)
                            .is_some_and(|provider| provider.claude_preset)
                        || self
                            .clients
                            .values()
                            .filter(|client| client.grants.contains(group_id))
                            .count()
                            != 1
                        || !group
                            .hosts
                            .iter()
                            .any(|host| host.as_ref() == "platform.claude.com")
                        || !managed_owners.insert(credential_id.clone()))
                {
                    return Err(UnsupportedExecution::ManagedOauth {
                        credential: credential_id.clone(),
                    });
                }
            }
        }
        Ok(())
    }
}

impl TryFrom<RawConfig> for Config {
    type Error = ConfigErrors;

    fn try_from(raw: RawConfig) -> Result<Self, Self::Error> {
        let mut errors = Vec::new();
        validate_usage_projection(&raw, &mut errors);
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

        let control = parse_control(&raw, listen, &mut errors);
        let providers = parse_providers(&raw, &mut errors);
        let credentials = parse_credentials(&raw, &mut errors);
        let groups = parse_groups(&raw, &mut errors);
        let clients = parse_clients(&raw, &mut errors);
        let usage_credentials = parse_usage(&raw, &mut errors);
        validate_references(&raw, &providers, &mut errors);

        match (listen, state_dir, unknown_hosts, control) {
            (Some(listen), Some(state_dir), Some(unknown_hosts), control) if errors.is_empty() => {
                Ok(Self {
                    clients,
                    control,
                    credentials,
                    groups,
                    listen,
                    providers,
                    state_dir,
                    unknown_hosts,
                    usage_credentials,
                })
            }
            _ => Err(ConfigErrors(errors)),
        }
    }
}

fn validate_usage_projection(raw: &RawConfig, errors: &mut Vec<ConfigError>) {
    // One client grant per group contributes one route for every group member;
    // the report clones that member's model list into each route.
    let mut routes = 0usize;
    let mut models = 0usize;
    let mut credentials = raw.usage.credentials.iter().collect::<BTreeSet<_>>();
    for client in raw.clients.values() {
        for group in client.grants.iter().collect::<BTreeSet<_>>() {
            if let Some(group) = raw.groups.get(group) {
                routes = routes.saturating_add(group.members.len());
                for (credential, member) in &group.members {
                    credentials.insert(credential);
                    models = models.saturating_add(member.models.len());
                }
            }
        }
    }
    for (dimension, count, limit) in [
        ("credentials", credentials.len(), 64),
        ("routes", routes, 256),
        ("cloned model strings", models, 8_192),
    ] {
        if count > limit {
            errors.push(ConfigError::UsageProjectionLimit { dimension, limit });
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

fn parse_control(
    raw: &RawConfig,
    listen: Option<SocketAddr>,
    errors: &mut Vec<ConfigError>,
) -> Option<ControlConfig> {
    let raw_control = raw.control.as_ref()?;
    let control_listen = match raw_control.listen.parse::<SocketAddr>() {
        Ok(address)
            if address.ip() == std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST)
                && address.port() != 0 =>
        {
            Some(address)
        }
        Ok(address) if address.ip() == std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST) => {
            errors.push(ConfigError::ControlListenPortZero);
            None
        }
        Ok(address) => {
            errors.push(ConfigError::NonLoopbackControlListen { address });
            None
        }
        Err(_) => {
            errors.push(ConfigError::InvalidControlListen {
                value: raw_control.listen.clone(),
            });
            None
        }
    };
    let read_token_file = SecretFile::try_from(raw_control.read_token_file.clone())
        .map_err(|_| {
            errors.push(ConfigError::RelativeControlTokenFile {
                path: raw_control.read_token_file.clone(),
            });
        })
        .ok();
    if let (Some(control_listen), Some(read_token_file)) = (control_listen, read_token_file) {
        if listen.is_some_and(|gateway_listen| gateway_listen.port() == control_listen.port()) {
            errors.push(ConfigError::ControlListenConflict {
                port: control_listen.port(),
            });
        }
        return Some(ControlConfig {
            listen: control_listen,
            read_token_file,
        });
    }
    None
}

fn parse_usage(raw: &RawConfig, errors: &mut Vec<ConfigError>) -> BTreeSet<CredentialId> {
    let mut selected = BTreeSet::new();
    for credential in &raw.usage.credentials {
        match CredentialId::try_from(credential.as_str()) {
            Ok(id) => {
                selected.insert(id);
            }
            Err(error) => errors.push(invalid_name("usage credential", error)),
        }
    }
    selected
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
        let usage_account_id = raw_credential.account_id.clone();
        if usage_account_id
            .as_ref()
            .is_some_and(|account| account.is_empty() || account.len() > 128)
        {
            errors.push(ConfigError::InvalidUsageAccount {
                credential: raw_id.clone(),
            });
        }
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
            credentials.insert(
                id,
                CredentialConfig {
                    auth,
                    provider,
                    usage_account_id,
                },
            );
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
            Some("codex") | None => {}
            Some(preset) => errors.push(ConfigError::UnknownPreset {
                provider: raw_id.clone(),
                preset: preset.to_owned(),
            }),
        }
        endpoints.extend(raw_provider.endpoints.clone());
        let codex_preset = raw_provider.preset.as_deref() == Some("codex");
        if endpoints.is_empty() && !codex_preset {
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
                Some(()) => {
                    resolved.insert(protocol, Endpoint { url });
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
                    claude_preset: raw_provider.preset.as_deref() == Some("claude"),
                    codex_preset,
                    endpoints: resolved,
                    zai_preset: raw_provider.preset.as_deref() == Some("zai"),
                },
            );
        }
    }
    providers
}

fn parse_endpoint(url: &str) -> Option<()> {
    let rest = url.strip_prefix("https://")?;
    let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
    if authority.contains(['@', '?', '#']) || !valid_uri_path(path) {
        return None;
    }
    let (host, port) = authority
        .rsplit_once(':')
        .map_or((authority, None), |(host, port)| (host, Some(port)));
    HostName::try_from(host).ok()?;
    if let Some(port) = port {
        port.parse::<std::num::NonZeroU16>().ok()?;
    }
    Some(())
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
    for credential in &raw.usage.credentials {
        let Some(raw_credential) = raw.credentials.get(credential) else {
            errors.push(ConfigError::UnknownUsageCredential {
                credential: credential.clone(),
            });
            continue;
        };
        let Ok(provider_id) = ProviderId::try_from(raw_credential.provider.as_str()) else {
            continue;
        };
        let Some(provider) = providers.get(&provider_id) else {
            continue;
        };
        let codex = provider.codex_preset;
        let supported = match raw_credential.auth {
            RawAuth::OauthManaged {} => provider.claude_preset,
            RawAuth::OauthBearer { .. } => provider.claude_preset || codex,
            RawAuth::ApiKey { .. } => provider.zai_preset,
        };
        if !supported
            || (codex
                && (raw_credential.account_id.as_deref().is_none()
                    || !matches!(raw_credential.auth, RawAuth::OauthBearer { .. })))
            || (!codex && raw_credential.account_id.is_some())
        {
            errors.push(ConfigError::UnsupportedUsageCredential {
                credential: credential.clone(),
            });
        }
    }
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
            {
                if provider.codex_preset {
                    errors.push(ConfigError::UsageOnlyCredentialInGroup {
                        credential: credential_id.clone(),
                        group: group_id.clone(),
                    });
                } else if !provider.endpoints.contains_key(&protocol) {
                    errors.push(ConfigError::MissingProviderProtocol {
                        group: group_id.clone(),
                        credential: credential_id.clone(),
                        provider: credential.provider.clone(),
                        protocol: group.protocol.clone(),
                    });
                }
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
            baseline.clients[&ClientId::try_from("harness").expect("id")].token_file,
            SecretFile::try_from(std::path::PathBuf::from("/run/airlock/harness"))
                .expect("absolute token file")
        );
        let storage_identities = baseline.storage_identities(1);
        assert_eq!(storage_identities.clients.len(), 1);
        assert_eq!(storage_identities.providers.len(), 2);
        assert_eq!(storage_identities.credentials.len(), 2);
        assert_eq!(storage_identities.groups.len(), 1);
        assert_eq!(storage_identities.group_members.len(), 2);
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
        assert!(config.validate_executable().is_ok());
        let group = GroupId::try_from("anthropic").expect("group");
        let zai = config
            .route(&group, Some("glm-4.7"))
            .expect("claimed model route");
        assert_eq!(zai.credential.as_ref(), "zai");
        assert_eq!(zai.endpoint, "https://api.z.ai/api/anthropic");
        assert!(!zai.is_primary);
        assert_eq!(zai.primary_credential.as_ref(), "claude");
        let claude = config
            .route(&group, Some("new-claude-model"))
            .expect("unclaimed model route");
        assert!(claude.is_primary);
        assert_eq!(claude.primary_credential.as_ref(), "claude");
        assert_eq!(
            config
                .route(&group, None)
                .map(|route| route.credential.as_ref()),
            Some("claude")
        );

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
        assert!(config.validate_executable().is_ok());
        assert_eq!(
            config.route(&group, None).map(|route| route.endpoint),
            Some("https://other.example")
        );

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
    fn explicit_usage_credentials_are_inference_inert() {
        let mut value = valid_raw();
        value["credentials"]["codex"] = json!({
            "account_id": "fake-chatgpt-account",
            "auth": {"type": "oauth_bearer", "file": "/run/airlock/codex"},
            "provider": "codex"
        });
        value["providers"]["codex"] = json!({"preset": "codex"});
        value["usage"] = json!({"credentials": ["codex"]});
        let config = converted(value).expect("explicit Codex usage config");
        assert_eq!(
            config
                .granted_credentials()
                .find_map(|(id, _)| (id.as_ref() == "codex").then_some(())),
            None
        );
        assert_eq!(
            config
                .route(
                    &GroupId::try_from("anthropic").expect("group ID"),
                    Some("codex")
                )
                .map(|route| route.credential.as_ref()),
            Some("claude")
        );
        let usage = config
            .usage_credentials()
            .into_iter()
            .find(|credential| credential.id.as_ref() == "codex")
            .expect("Codex usage credential");
        assert!(usage.explicit_usage_selection);
        assert_eq!(usage.account_id.as_deref(), Some("fake-chatgpt-account"));
        assert_eq!(usage.routes.len(), 0);
        assert!(usage.group.is_none());
    }

    #[test]
    fn usage_projection_preserves_all_grants_and_primary_ownership() {
        let mut value = valid_raw();
        value["groups"]["other"] = json!({
            "intercept": ["other.example"],
            "members": {"zai": {"models": []}},
            "primary": "zai", "protocol": "anthropic"
        });
        value["clients"]["harness"]["grants"] = json!(["anthropic", "other"]);
        value["clients"]["second"] = json!({
            "grants": ["anthropic"], "token_file": "/run/airlock/second"
        });
        let config = converted(value).expect("reused credential config");
        let credentials = config.usage_credentials();
        assert_eq!(credentials.len(), 2, "one collection per credential");
        let zai = credentials
            .iter()
            .find(|item| item.id.as_ref() == "zai")
            .expect("zai");
        assert_eq!(zai.routes.len(), 3);
        assert!(zai.client.is_none(), "multiple routes have no sole owner");
        assert!(zai.routes.iter().any(|route| route.primary
            && route.models.is_empty()
            && route.group.as_ref() == "other"));
        assert_eq!(zai.routes.iter().filter(|route| route.primary).count(), 1);
    }

    #[test]
    fn explicit_usage_selection_is_provider_and_shape_checked() {
        let mut missing_account = valid_raw();
        missing_account["credentials"]["codex"] = json!({
            "auth": {"type": "oauth_bearer", "file": "/run/airlock/codex"},
            "provider": "codex"
        });
        missing_account["providers"]["codex"] = json!({"preset": "codex"});
        missing_account["usage"] = json!({"credentials": ["codex"]});
        has_error(missing_account, |error| {
            matches!(error, ConfigError::UnsupportedUsageCredential { .. })
        });

        let mut wrong_provider = valid_raw();
        wrong_provider["usage"] = json!({"credentials": ["claude"]});
        wrong_provider["credentials"]["claude"]["account_id"] = json!("fake-account");
        has_error(wrong_provider, |error| {
            matches!(error, ConfigError::UnsupportedUsageCredential { .. })
        });

        let mut wrong_auth = valid_raw();
        wrong_auth["usage"] = json!({"credentials": ["claude"]});
        wrong_auth["credentials"]["claude"]["auth"] =
            json!({"type": "api_key", "file": "/run/airlock/claude"});
        has_error(wrong_auth, |error| {
            matches!(error, ConfigError::UnsupportedUsageCredential { .. })
        });

        let mut unknown = valid_raw();
        unknown["usage"] = json!({"credentials": ["missing"]});
        has_error(unknown, |error| {
            matches!(error, ConfigError::UnknownUsageCredential { .. })
        });

        let mut routed = valid_raw();
        routed["credentials"]["codex"] = json!({
            "account_id": "fake-account",
            "auth": {"type": "oauth_bearer", "file": "/run/airlock/codex"},
            "provider": "codex"
        });
        routed["providers"]["codex"] =
            json!({"preset": "codex", "endpoints": {"anthropic": "https://example.invalid"}});
        routed["groups"]["anthropic"]["members"]["codex"] = json!({"models": ["fake-codex-model"]});
        has_error(routed, |error| {
            matches!(error, ConfigError::UsageOnlyCredentialInGroup { .. })
        });
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
    #[test]
    fn usage_projection_rejects_amplification_before_cloning() {
        let mut value = valid_raw();
        let clients = (0..300)
            .map(|index| {
                (
                    format!("fake-client-{index}"),
                    json!({"grants":["anthropic"],"token_file":"/run/fake-unused"}),
                )
            })
            .collect::<serde_json::Map<_, _>>();
        value["clients"] = Value::Object(clients);
        value["groups"]["anthropic"]["members"]["zai"]["models"] = json!(
            (0..1000)
                .map(|i| format!("fake-model-{i}"))
                .collect::<Vec<_>>()
        );
        let bytes = serde_json::to_vec(&value).expect("config bytes").len();
        assert_eq!(bytes, 39_755);
        has_error(value, |error| {
            matches!(error, ConfigError::UsageProjectionLimit { .. })
        });
        let config = converted(valid_raw()).expect("small config");
        assert!(
            config
                .usage_collector_credentials()
                .iter()
                .all(|credential| credential.routes.is_empty())
        );
    }
}
