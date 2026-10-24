use std::collections::BTreeMap;

use crate::{
    config::{Config, NonEmpty},
    ids::{ClientId, CredentialId, HostName, UpstreamId},
};

#[derive(Clone, Debug)]
pub enum Grant {
    Upstream {
        credentials: NonEmpty<CredentialId>,
        upstream: UpstreamId,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub enum Decision<'policy> {
    Deny(DenyReason),
    Intercept {
        credentials: &'policy [CredentialId],
        upstream: &'policy UpstreamId,
    },
    Tunnel,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DenyReason {
    UnknownClient,
    UnknownHost,
}

#[derive(Clone, Debug)]
pub struct Policy {
    clients: BTreeMap<ClientId, Vec<Grant>>,
    intercepted_hosts: BTreeMap<HostName, UpstreamId>,
    unknown_hosts: crate::config::UnknownHosts,
}

impl Policy {
    #[must_use]
    pub fn from_config(config: &Config) -> Self {
        let intercepted_hosts = config
            .intercepted_hosts()
            .map(|(host, upstream)| (host.clone(), upstream.clone()))
            .collect();
        Self {
            clients: config
                .client_grants()
                .map(|(client, grants)| (client.clone(), grants.to_vec()))
                .collect(),
            intercepted_hosts,
            unknown_hosts: config.unknown_hosts(),
        }
    }

    #[must_use]
    pub fn decide(&self, client: &ClientId, host: &HostName) -> Decision<'_> {
        let Some(grants) = self.clients.get(client) else {
            return Decision::Deny(DenyReason::UnknownClient);
        };

        let Some(upstream) = self.intercepted_hosts.get(host) else {
            return match self.unknown_hosts {
                crate::config::UnknownHosts::Deny => Decision::Deny(DenyReason::UnknownHost),
                crate::config::UnknownHosts::Tunnel => Decision::Tunnel,
            };
        };

        grants
            .iter()
            .find_map(|grant| match grant {
                Grant::Upstream {
                    credentials,
                    upstream: granted_upstream,
                } if granted_upstream == upstream => Some(Decision::Intercept {
                    credentials: credentials.as_slice(),
                    upstream,
                }),
                Grant::Upstream { .. } => None,
            })
            .unwrap_or(Decision::Deny(DenyReason::UnknownHost))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::RawConfig;
    use serde_json::json;

    fn config(unknown_hosts: &str) -> Config {
        let raw = serde_json::from_value::<RawConfig>(json!({
            "clients": {
                "harness": {
                    "grants": [{
                        "credentials": ["claude"],
                        "upstream": "anthropic"
                    }],
                    "token_file": "/run/airlock/harness-token"
                },
                "outsider": {
                    "grants": [{
                        "credentials": ["claude"],
                        "upstream": "anthropic"
                    }],
                    "token_file": "/run/airlock/outsider-token"
                }
            },
            "credentials": {
                "claude": {
                    "auth": {"file": "/run/airlock/claude", "type": "api_key"},
                    "upstream": "anthropic"
                }
            },
            "listen": "127.0.0.1:8080",
            "state_dir": "/var/lib/airlock",
            "unknown_hosts": unknown_hosts,
            "upstreams": {
                "anthropic": {
                    "intercept": ["api.anthropic.com"],
                    "provider": "anthropic"
                },
                "other": {
                    "intercept": ["api.other.test"],
                    "provider": "anthropic"
                }
            }
        }))
        .expect("raw config");
        Config::try_from(raw).expect("valid config")
    }

    #[test]
    fn decision_table_covers_grants_hosts_clients_and_policies() {
        let harness = ClientId::try_from("harness").expect("client id");
        let outsider = ClientId::try_from("outsider").expect("client id");
        let stranger = ClientId::try_from("stranger").expect("client id");
        let anthropic = HostName::try_from("api.anthropic.com").expect("host");
        let other = HostName::try_from("api.other.test").expect("host");
        let unknown = HostName::try_from("unknown.test").expect("host");
        let upstream = UpstreamId::try_from("anthropic").expect("upstream");
        let credential = CredentialId::try_from("claude").expect("credential");

        for unknown_hosts in ["tunnel", "deny"] {
            let policy = Policy::from_config(&config(unknown_hosts));
            assert_eq!(
                policy.decide(&harness, &anthropic),
                Decision::Intercept {
                    credentials: std::slice::from_ref(&credential),
                    upstream: &upstream,
                },
                "granted host must intercept under {unknown_hosts}"
            );
            assert_eq!(
                policy.decide(&outsider, &other),
                Decision::Deny(DenyReason::UnknownHost),
                "intercepted host without a grant must deny under {unknown_hosts}"
            );
            assert_eq!(
                policy.decide(&stranger, &anthropic),
                Decision::Deny(DenyReason::UnknownClient),
                "unknown client must deny under {unknown_hosts}"
            );

            let unknown_decision = policy.decide(&harness, &unknown);
            let expected = if unknown_hosts == "tunnel" {
                Decision::Tunnel
            } else {
                Decision::Deny(DenyReason::UnknownHost)
            };
            assert_eq!(unknown_decision, expected);
        }
    }
}
