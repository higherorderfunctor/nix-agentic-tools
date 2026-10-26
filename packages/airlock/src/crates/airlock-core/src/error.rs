use std::{net::SocketAddr, path::PathBuf};

#[derive(Debug, thiserror::Error)]
pub enum NameError {
    #[error(
        "invalid domain name {value:?}: expected lowercase [a-z0-9][a-z0-9-] with length 1..=63"
    )]
    InvalidName { value: String },
}

impl NameError {
    #[must_use]
    pub fn into_name(self) -> String {
        match self {
            Self::InvalidName { value } => value,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum HostNameError {
    #[error("invalid DNS host name {value:?}")]
    InvalidHostName { value: String },
    #[error("host name {value:?} is an IP address")]
    IpAddress { value: String },
}

#[derive(Debug, thiserror::Error)]
pub enum SecretFileError {
    #[error("secret file path {path:?} must be absolute")]
    RelativePath { path: PathBuf },
}

#[derive(Debug, thiserror::Error)]
pub enum SecretError {
    #[error("control listener is not configured")]
    ControlNotConfigured,
    #[error("control read token must differ from every proxy client token")]
    ControlTokenReuse,
    #[error("secret file {path} is empty after trimming one trailing newline")]
    Empty { path: PathBuf },
    #[error("could not read secret file {path}: {source}")]
    Read {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("secret file {path} exceeds the {limit}-byte bound")]
    TooLarge { limit: usize, path: PathBuf },
    #[error("secret file {path} is not a regular file")]
    UnsupportedType { path: PathBuf },
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("control listener cannot share gateway port {port}")]
    ControlListenConflict { port: u16 },
    #[error("control listen port must be explicit and nonzero")]
    ControlListenPortZero,
    #[error("authorization policy could not be parsed")]
    InvalidAuthorizationParse,
    #[error("authorization policy does not match the CONNECT schema")]
    InvalidAuthorizationSchema,
    #[error("control listen address {value:?} is not a valid socket address")]
    InvalidControlListen { value: String },
    #[error("control listen address {address} is not loopback")]
    NonLoopbackControlListen { address: SocketAddr },
    #[error("control read token file {path:?} must be absolute")]
    RelativeControlTokenFile { path: PathBuf },
    #[error("usage route projection exceeds {limit} {dimension}")]
    UsageProjectionLimit {
        dimension: &'static str,
        limit: usize,
    },
    #[error("model {model:?} in group {group:?} is owned by both {first:?} and {second:?}")]
    DuplicateModel {
        first: String,
        group: String,
        model: String,
        second: String,
    },
    #[error("host {host:?} is intercepted by both {first:?} and {second:?}")]
    DuplicateInterceptHost {
        first: String,
        host: String,
        second: String,
    },
    #[error("client {client:?} has no grants")]
    EmptyGrants { client: String },
    #[error("group {group:?} has no members")]
    EmptyGroupMembers { group: String },
    #[error("group {group:?} member {credential:?} has no model IDs")]
    EmptyNonPrimaryModels { credential: String, group: String },
    #[error("provider {provider:?} has no resolved endpoints")]
    EmptyProviderEndpoints { provider: String },
    #[error("group {group:?} member {credential:?} has an empty model ID")]
    EmptyModel { credential: String, group: String },
    #[error("provider {provider:?} has invalid {protocol:?} endpoint")]
    InvalidEndpoint { protocol: String, provider: String },
    #[error("group {group:?} has invalid intercept host {host:?}")]
    InvalidHost { group: String, host: String },
    #[error("listen address {value:?} is not a valid socket address")]
    InvalidListen { value: String },
    #[error("invalid {field} identifier {value:?}")]
    InvalidName { field: &'static str, value: String },
    #[error(
        "group {group:?} credential {credential:?} uses provider {provider:?} without {protocol:?} endpoint"
    )]
    MissingProviderProtocol {
        credential: String,
        group: String,
        protocol: String,
        provider: String,
    },
    #[error("group {group:?} cannot route through usage-only Codex credential {credential:?}")]
    UsageOnlyCredentialInGroup { credential: String, group: String },
    #[error("unknown_hosts must be \"tunnel\" or \"deny\", not {value:?}")]
    InvalidUnknownHostPolicy { value: String },
    #[error("usage credential {credential:?} has an invalid account ID")]
    InvalidUsageAccount { credential: String },
    #[error("listen address {address} is not loopback")]
    NonLoopbackListen { address: SocketAddr },
    #[error("group {group:?} non-primary credential {credential:?} cannot use managed OAuth")]
    NonPrimaryManagedOauth { credential: String, group: String },
    #[error("group {group:?} primary {primary:?} is not a member")]
    PrimaryNotMember { group: String, primary: String },
    #[error("credential {credential:?} has a relative auth file {path:?}")]
    RelativeAuthFile { credential: String, path: PathBuf },
    #[error("state_dir {path:?} must be absolute")]
    RelativeStateDir { path: PathBuf },
    #[error("client {client:?} has a relative token file {path:?}")]
    RelativeTokenFile { client: String, path: PathBuf },
    #[error("credential {credential:?} references unknown provider {provider:?}")]
    UnknownCredentialProvider {
        credential: String,
        provider: String,
    },
    #[error("grant for client {client:?} references unknown group {group:?}")]
    UnknownGrantGroup { client: String, group: String },
    #[error("group {group:?} references unknown credential {credential:?}")]
    UnknownGroupCredential { credential: String, group: String },
    #[error("usage selection references unknown credential {credential:?}")]
    UnknownUsageCredential { credential: String },
    #[error(
        "usage credential {credential:?} requires a matching provider preset and authentication mode"
    )]
    UnsupportedUsageCredential { credential: String },
    #[error("provider {provider:?} has unknown preset {preset:?}")]
    UnknownPreset { preset: String, provider: String },
    #[error("group {group:?} uses unsupported protocol {protocol:?}")]
    UnsupportedProtocol { group: String, protocol: String },
}

#[derive(Debug, thiserror::Error)]
pub struct ConfigErrors(pub Vec<ConfigError>);

impl std::fmt::Display for ConfigErrors {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "invalid airlock configuration:")?;
        for error in &self.0 {
            write!(formatter, "\n{error}")?;
        }
        Ok(())
    }
}
