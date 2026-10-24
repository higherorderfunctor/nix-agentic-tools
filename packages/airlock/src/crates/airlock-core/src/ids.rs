use std::fmt;

use serde::Deserialize;

use crate::error::NameError;

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize)]
#[serde(try_from = "String")]
pub struct Name(String);

impl Name {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for Name {
    type Error = NameError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        let valid = value.len() <= 63
            && !value.is_empty()
            && value
                .bytes()
                .next()
                .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
            && value
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-');

        if valid {
            Ok(Self(value))
        } else {
            Err(NameError::InvalidName { value })
        }
    }
}

impl TryFrom<&str> for Name {
    type Error = NameError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

impl AsRef<str> for Name {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Name {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

macro_rules! domain_id {
    ($name:ident) => {
        #[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize)]
        #[serde(try_from = "Name")]
        pub struct $name(Name);

        impl TryFrom<String> for $name {
            type Error = NameError;

            fn try_from(value: String) -> Result<Self, Self::Error> {
                Ok(Self(Name::try_from(value)?))
            }
        }

        impl TryFrom<&str> for $name {
            type Error = NameError;

            fn try_from(value: &str) -> Result<Self, Self::Error> {
                Self::try_from(value.to_owned())
            }
        }

        impl From<Name> for $name {
            fn from(value: Name) -> Self {
                Self(value)
            }
        }

        impl AsRef<str> for $name {
            fn as_ref(&self) -> &str {
                self.0.as_str()
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                std::fmt::Display::fmt(&self.0, formatter)
            }
        }
    };
}

domain_id!(ClientId);
domain_id!(CredentialId);
domain_id!(UpstreamId);

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct HostName(String);

impl TryFrom<String> for HostName {
    type Error = HostNameError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() > 253
            || value.is_empty()
            || value.split('.').any(|label| {
                label.is_empty()
                    || label.len() > 63
                    || label.starts_with('-')
                    || label.ends_with('-')
                    || !label.bytes().all(|byte| {
                        byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-'
                    })
            })
        {
            return Err(HostNameError::InvalidHostName { value });
        }

        // Resolvers also accept integer, shortened, octal, and hexadecimal IPv4 spellings.
        if value.split('.').all(|label| {
            label.bytes().all(|byte| byte.is_ascii_digit())
                || label.strip_prefix("0x").is_some_and(|digits| {
                    !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_hexdigit())
                })
        }) {
            return Err(HostNameError::IpAddress { value });
        }

        Ok(Self(value))
    }
}

impl TryFrom<&str> for HostName {
    type Error = HostNameError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

impl AsRef<str> for HostName {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for HostName {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

use crate::error::HostNameError;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn name_accepts_and_rejects_expected_values() {
        let max_length = format!("a{}", "-".repeat(62));
        for value in ["a", "0", "anthropic", "a0-1", "a-", max_length.as_str()] {
            assert!(
                Name::try_from(value).is_ok(),
                "rejected valid name: {value}"
            );
        }

        for value in ["", "A", "-a", "a_b", "a.b", "ä", &"a".repeat(64)] {
            assert!(
                Name::try_from(value).is_err(),
                "accepted invalid name: {value}"
            );
        }
    }

    #[test]
    fn host_name_accepts_dns_names() {
        for value in ["localhost", "api.anthropic.com", "a-1.example"] {
            assert!(
                HostName::try_from(value).is_ok(),
                "rejected valid host: {value}"
            );
        }
    }

    #[test]
    fn host_name_rejects_invalid_values() {
        for value in [
            "",
            ".",
            "api..example",
            "-api.example",
            "api-.example",
            "api.example-",
            "API.example",
            "api_1.example",
            "api.example:443",
            "127.0.0.1",
            "2130706433",
            "0x7f000001",
            "0177.0.0.1",
            &"a".repeat(254),
        ] {
            assert!(
                HostName::try_from(value).is_err(),
                "accepted invalid host: {value}"
            );
        }
    }
}
