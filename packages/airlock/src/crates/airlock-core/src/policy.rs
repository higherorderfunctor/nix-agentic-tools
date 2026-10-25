use std::collections::BTreeMap;

use crate::{
    config::Config,
    ids::{ClientId, CredentialId, GroupId, HostName},
};

#[derive(Debug, PartialEq, Eq)]
pub enum Decision<'policy> {
    Deny(DenyReason),
    Intercept {
        credentials: &'policy [CredentialId],
        group: &'policy GroupId,
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
    clients: BTreeMap<ClientId, Vec<GroupId>>,
    intercepted_hosts: BTreeMap<HostName, GroupId>,
    primary: BTreeMap<GroupId, Vec<CredentialId>>,
    unknown_hosts: crate::config::UnknownHosts,
}

impl Policy {
    #[must_use]
    pub fn from_config(config: &Config) -> Self {
        let intercepted_hosts = config
            .intercepted_hosts()
            .map(|(host, group)| (host.clone(), group.clone()))
            .collect();
        let clients = config
            .client_grants()
            .map(|(client, grants)| (client.clone(), grants.to_vec()))
            .collect();
        let primary = config
            .client_grants()
            .flat_map(|(_, grants)| grants)
            .filter_map(|group| {
                config
                    .group_primary(group)
                    .map(|credential| (group.clone(), vec![credential.clone()]))
            })
            .collect();
        Self {
            clients,
            intercepted_hosts,
            primary,
            unknown_hosts: config.unknown_hosts(),
        }
    }

    #[must_use]
    pub fn decide(&self, client: &ClientId, host: &HostName) -> Decision<'_> {
        let Some(grants) = self.clients.get(client) else {
            return Decision::Deny(DenyReason::UnknownClient);
        };
        let Some(group) = self.intercepted_hosts.get(host) else {
            return match self.unknown_hosts {
                crate::config::UnknownHosts::Deny => Decision::Deny(DenyReason::UnknownHost),
                crate::config::UnknownHosts::Tunnel => Decision::Tunnel,
            };
        };
        if !grants.contains(group) {
            return Decision::Deny(DenyReason::UnknownHost);
        }
        self.primary
            .get(group)
            .map_or(Decision::Deny(DenyReason::UnknownHost), |credentials| {
                Decision::Intercept { credentials, group }
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::RawConfig;
    use serde_json::json;

    fn config(unknown_hosts: &str) -> Config {
        let raw = serde_json::from_value::<RawConfig>(json!({
            "clients": {"harness": {"grants": ["anthropic"], "token_file": "/run/harness"}},
            "credentials": {"claude": {"auth": {"type": "api_key", "file": "/run/claude"}, "provider": "claude"}},
            "groups": {
                "anthropic": {"intercept": ["api.anthropic.com"], "members": {"claude": {"models": []}}, "primary": "claude", "protocol": "anthropic"},
                "other": {"intercept": ["api.other.test"], "members": {"claude": {"models": []}}, "primary": "claude", "protocol": "anthropic"}
            },
            "listen": "127.0.0.1:8080",
            "providers": {"claude": {"preset": "claude"}},
            "state_dir": "/var/lib/airlock",
            "unknown_hosts": unknown_hosts
        })).expect("raw");
        Config::try_from(raw).expect("config")
    }

    #[test]
    fn decision_table_covers_group_grants_hosts_clients_and_policies() {
        let harness = ClientId::try_from("harness").expect("client");
        let stranger = ClientId::try_from("stranger").expect("client");
        let claude = CredentialId::try_from("claude").expect("credential");
        let group = GroupId::try_from("anthropic").expect("group");
        let anthropic = HostName::try_from("api.anthropic.com").expect("host");
        let other = HostName::try_from("api.other.test").expect("host");
        let unknown = HostName::try_from("unknown.test").expect("host");

        for unknown_hosts in ["deny", "tunnel"] {
            let config = config(unknown_hosts);
            let policy = Policy::from_config(&config);
            assert_eq!(
                policy.decide(&harness, &anthropic),
                Decision::Intercept {
                    credentials: std::slice::from_ref(&claude),
                    group: &group,
                }
            );
            assert_eq!(
                policy.decide(&harness, &other),
                Decision::Deny(DenyReason::UnknownHost)
            );
            assert_eq!(
                policy.decide(&stranger, &anthropic),
                Decision::Deny(DenyReason::UnknownClient)
            );
            let expected = if unknown_hosts == "deny" {
                Decision::Deny(DenyReason::UnknownHost)
            } else {
                Decision::Tunnel
            };
            assert_eq!(policy.decide(&harness, &unknown), expected);
        }
    }
}
