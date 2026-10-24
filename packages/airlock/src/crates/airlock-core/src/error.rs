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
    #[error("secret file {path} is empty after trimming one trailing newline")]
    Empty { path: PathBuf },
    #[error("could not read secret file {path}: {source}")]
    Read {
        path: PathBuf,
        source: std::io::Error,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error(
        "credential {credential:?} for client {client:?} belongs to {actual:?}, not {granted:?}"
    )]
    CredentialUpstreamMismatch {
        actual: String,
        client: String,
        credential: String,
        granted: String,
    },
    #[error("host {host:?} is intercepted by both {first:?} and {second:?}")]
    DuplicateInterceptHost {
        first: String,
        host: String,
        second: String,
    },
    #[error("grant for client {client:?} has no credentials")]
    EmptyGrantCredentials { client: String },
    #[error("client {client:?} has no grants")]
    EmptyGrants { client: String },
    #[error("upstream {upstream:?} has invalid intercept host {host:?}")]
    InvalidHost { host: String, upstream: String },
    #[error("listen address {value:?} is not a valid socket address")]
    InvalidListen { value: String },
    #[error("invalid {field} identifier {value:?}")]
    InvalidName { field: &'static str, value: String },
    #[error("unknown_hosts must be \"tunnel\" or \"deny\", not {value:?}")]
    InvalidUnknownHostPolicy { value: String },
    #[error("listen address {address} is not loopback")]
    NonLoopbackListen { address: SocketAddr },
    #[error("credential {credential:?} has a relative auth file {path:?}")]
    RelativeAuthFile { credential: String, path: PathBuf },
    #[error("state_dir {path:?} must be absolute")]
    RelativeStateDir { path: PathBuf },
    #[error("client {client:?} has a relative token file {path:?}")]
    RelativeTokenFile { client: String, path: PathBuf },
    #[error("credential {credential:?} references unknown upstream {upstream:?}")]
    UnknownCredentialUpstream {
        credential: String,
        upstream: String,
    },
    #[error("grant for client {client:?} references unknown credential {credential:?}")]
    UnknownGrantCredential { client: String, credential: String },
    #[error("grant for client {client:?} references unknown upstream {upstream:?}")]
    UnknownGrantUpstream { client: String, upstream: String },
    #[error("upstream {upstream:?} has unsupported provider {provider:?}")]
    UnsupportedProvider { provider: String, upstream: String },
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
