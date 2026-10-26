use std::{net::IpAddr, num::NonZeroU16};

use crate::{error::HostNameError, ids::HostName};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConnectTarget {
    host: HostName,
    port: NonZeroU16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum TargetDenyReason {
    #[error("IP literals bypass hostname policy")]
    IpLiteral,
    #[error("CONNECT requires a DNS host and a nonzero numeric port")]
    MalformedAuthority,
}

impl TryFrom<&str> for ConnectTarget {
    type Error = TargetDenyReason;

    fn try_from(authority: &str) -> Result<Self, Self::Error> {
        let (host, port) = authority
            .rsplit_once(':')
            .ok_or(TargetDenyReason::MalformedAuthority)?;
        // IP literals would bypass hostname policy, so CONNECT refuses them.
        if host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<IpAddr>()
            .is_ok()
        {
            return Err(TargetDenyReason::IpLiteral);
        }
        let host = HostName::try_from(host).map_err(|error| match error {
            HostNameError::IpAddress { .. } => TargetDenyReason::IpLiteral,
            HostNameError::InvalidHostName { .. } => TargetDenyReason::MalformedAuthority,
        })?;
        if port.is_empty() || !port.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(TargetDenyReason::MalformedAuthority);
        }
        let port = port
            .parse::<NonZeroU16>()
            .map_err(|_| TargetDenyReason::MalformedAuthority)?;
        Ok(Self { host, port })
    }
}

impl ConnectTarget {
    #[must_use]
    pub fn host(&self) -> &HostName {
        &self.host
    }

    #[must_use]
    pub fn port(&self) -> u16 {
        self.port.get()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authorities_require_dns_host_and_nonzero_port() {
        let target = ConnectTarget::try_from("localhost:443").expect("target");
        assert_eq!(target.host().as_ref(), "localhost");
        assert_eq!(target.port(), 443);
        for authority in [
            "localhost",
            "localhost:0",
            "localhost:+1",
            "localhost:65536",
            "user@localhost:443",
            "https://localhost:443",
            "localhost:443/path",
        ] {
            assert_eq!(
                ConnectTarget::try_from(authority),
                Err(TargetDenyReason::MalformedAuthority),
                "{authority}"
            );
        }
        for authority in [
            "127.0.0.1:443",
            "[::1]:443",
            "::1:443",
            "2130706433:443",
            "0x7f000001:443",
        ] {
            assert_eq!(
                ConnectTarget::try_from(authority),
                Err(TargetDenyReason::IpLiteral)
            );
        }
    }
}
