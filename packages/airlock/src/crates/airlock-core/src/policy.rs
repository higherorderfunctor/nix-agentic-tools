use std::collections::BTreeMap;

use crate::{
    config::Config,
    ids::{ClientId, GroupId, HostName},
};

#[derive(Debug, PartialEq, Eq)]
pub enum Decision<'policy> {
    Deny(DenyReason),
    Intercept { group: &'policy GroupId },
    Tunnel,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DenyReason {
    CedarDenied,
    CedarError,
    UnknownClient,
    UnknownHost,
}

#[derive(Clone)]
pub struct Policy {
    authorization: crate::authorization::Authorization,
    clients: BTreeMap<ClientId, Vec<GroupId>>,
    intercepted_hosts: BTreeMap<HostName, GroupId>,
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
        Self {
            authorization: config.authorization(),
            clients,
            intercepted_hosts,
            unknown_hosts: config.unknown_hosts(),
        }
    }

    #[must_use]
    pub fn decide(&self, client: &ClientId, host: &HostName) -> Decision<'_> {
        let Some(grants) = self.clients.get(client) else {
            return Decision::Deny(DenyReason::UnknownClient);
        };
        let Some(group) = self.intercepted_hosts.get(host) else {
            if self.unknown_hosts == crate::config::UnknownHosts::Deny {
                return Decision::Deny(DenyReason::UnknownHost);
            }
            return match self.authorization.evaluate(client, host, None) {
                crate::authorization::Evaluation::Allow => Decision::Tunnel,
                crate::authorization::Evaluation::Deny => Decision::Deny(DenyReason::CedarDenied),
                crate::authorization::Evaluation::Error => Decision::Deny(DenyReason::CedarError),
            };
        };
        if !grants.contains(group) {
            return Decision::Deny(DenyReason::UnknownHost);
        }
        match self.authorization.evaluate(client, host, Some(group)) {
            crate::authorization::Evaluation::Allow => Decision::Intercept { group },
            crate::authorization::Evaluation::Deny => Decision::Deny(DenyReason::CedarDenied),
            crate::authorization::Evaluation::Error => Decision::Deny(DenyReason::CedarError),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{config::RawConfig, error::ConfigError};
    use serde_json::json;

    fn config(unknown_hosts: &str, authorization: Option<&str>) -> Config {
        let mut value = json!({
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
        });
        if let Some(authorization) = authorization {
            value["authorization"] = json!(authorization);
        }
        let raw = serde_json::from_value::<RawConfig>(value).expect("raw");
        Config::try_from(raw).expect("config")
    }

    fn rejected(authorization: &str, expected: &ConfigError) {
        let raw = serde_json::from_value::<RawConfig>(json!({
            "authorization": authorization,
            "clients": {"harness": {"grants": ["anthropic"], "token_file": "/run/missing"}},
            "credentials": {"claude": {"auth": {"type": "api_key", "file": "/run/missing"}, "provider": "claude"}},
            "groups": {"anthropic": {"intercept": ["api.anthropic.com"], "members": {"claude": {"models": []}}, "primary": "claude", "protocol": "anthropic"}},
            "listen": "127.0.0.1:8080",
            "providers": {"claude": {"preset": "claude"}},
            "state_dir": "/var/lib/airlock",
            "unknown_hosts": "tunnel"
        })).expect("raw");
        let Err(errors) = Config::try_from(raw) else {
            panic!("invalid authorization was accepted");
        };
        assert_eq!(errors.0.len(), 1);
        assert!(
            matches!(&errors.0[0], actual if std::mem::discriminant(actual) == std::mem::discriminant(expected))
        );
        let displayed = errors.to_string();
        assert!(!displayed.contains(authorization), "{displayed}");
    }

    #[test]
    fn omitted_policy_preserves_native_behavior() {
        let harness = ClientId::try_from("harness").expect("client");
        let stranger = ClientId::try_from("stranger").expect("client");
        let group = GroupId::try_from("anthropic").expect("group");
        let anthropic = HostName::try_from("api.anthropic.com").expect("host");
        let other = HostName::try_from("api.other.test").expect("host");
        let unknown = HostName::try_from("unknown.test").expect("host");

        for unknown_hosts in ["deny", "tunnel"] {
            let policy = Policy::from_config(&config(unknown_hosts, None));
            assert_eq!(
                policy.decide(&harness, &anthropic),
                Decision::Intercept { group: &group }
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

    #[test]
    fn explicit_null_policy_preserves_native_behavior() {
        let harness = ClientId::try_from("harness").expect("client");
        let group = GroupId::try_from("anthropic").expect("group");
        let anthropic = HostName::try_from("api.anthropic.com").expect("host");
        let value = json!({
            "authorization": null,
            "clients": {"harness": {"grants": ["anthropic"], "token_file": "/run/harness"}},
            "credentials": {"claude": {"auth": {"type": "api_key", "file": "/run/claude"}, "provider": "claude"}},
            "groups": {
                "anthropic": {
                    "intercept": ["api.anthropic.com"],
                    "members": {"claude": {"models": []}},
                    "primary": "claude",
                    "protocol": "anthropic"
                }
            },
            "listen": "127.0.0.1:8080",
            "providers": {"claude": {"preset": "claude"}},
            "state_dir": "/var/lib/airlock",
            "unknown_hosts": "tunnel"
        });
        let raw = serde_json::from_value::<RawConfig>(value).expect("raw");
        let policy = Policy::from_config(&Config::try_from(raw).expect("config"));
        assert_eq!(
            policy.decide(&harness, &anthropic),
            Decision::Intercept { group: &group }
        );
    }

    #[test]
    fn explicit_policy_permits_forbids_and_covers_native_bounds() {
        let harness = ClientId::try_from("harness").expect("client");
        let stranger = ClientId::try_from("stranger").expect("client");
        let group = GroupId::try_from("anthropic").expect("group");
        let anthropic = HostName::try_from("api.anthropic.com").expect("host");
        let other = HostName::try_from("api.other.test").expect("host");
        let unknown = HostName::try_from("unknown.test").expect("host");
        let permit = "permit(principal, action, resource);";
        let policy = Policy::from_config(&config("tunnel", Some(permit)));
        assert_eq!(
            policy.decide(&harness, &anthropic),
            Decision::Intercept { group: &group }
        );
        assert_eq!(
            policy.decide(&stranger, &anthropic),
            Decision::Deny(DenyReason::UnknownClient)
        );
        assert_eq!(
            policy.decide(&harness, &other),
            Decision::Deny(DenyReason::UnknownHost)
        );
        assert_eq!(policy.decide(&harness, &unknown), Decision::Tunnel);
    }

    #[test]
    fn forbid_takes_precedence_and_empty_policy_denies_all() {
        let harness = ClientId::try_from("harness").expect("client");
        let anthropic = HostName::try_from("api.anthropic.com").expect("host");
        let unknown = HostName::try_from("unknown.test").expect("host");
        let source = r#"permit(principal, action, resource);
        forbid(principal == Client::"harness", action == Action::"CONNECT", resource == Host::"api.anthropic.com");"#;
        let policy = Policy::from_config(&config("tunnel", Some(source)));
        assert_eq!(
            policy.decide(&harness, &anthropic),
            Decision::Deny(DenyReason::CedarDenied)
        );
        assert_eq!(policy.decide(&harness, &unknown), Decision::Tunnel);

        let empty = Policy::from_config(&config("tunnel", Some("")));
        assert_eq!(
            empty.decide(&harness, &anthropic),
            Decision::Deny(DenyReason::CedarDenied)
        );
        assert_eq!(
            empty.decide(&harness, &unknown),
            Decision::Deny(DenyReason::CedarDenied)
        );
    }

    #[test]
    fn unknown_host_forbid_cannot_be_bypassed_by_tunnel_mode() {
        let harness = ClientId::try_from("harness").expect("client");
        let unknown = HostName::try_from("unknown.test").expect("host");
        let source = r#"permit(principal, action, resource);
        forbid(principal == Client::"harness", action == Action::"CONNECT", resource == Host::"unknown.test");"#;
        let policy = Policy::from_config(&config("tunnel", Some(source)));
        assert_eq!(
            policy.decide(&harness, &unknown),
            Decision::Deny(DenyReason::CedarDenied)
        );
    }

    #[test]
    fn cedar_error_fails_closed_even_when_another_policy_permits() {
        let harness = ClientId::try_from("harness").expect("client");
        let unknown = HostName::try_from("unknown.test").expect("host");
        let source = r#"permit(principal, action, resource);
        permit(
            principal == Client::"harness",
            action == Action::"CONNECT",
            resource == Host::"unknown.test"
        ) when { 9223372036854775807 + 1 == 1 };"#;
        let policy = Policy::from_config(&config("tunnel", Some(source)));
        assert_eq!(
            policy.decide(&harness, &unknown),
            Decision::Deny(DenyReason::CedarError)
        );
    }

    #[test]
    fn malformed_and_schema_invalid_policies_fail_conversion_without_source_leakage() {
        rejected(
            "permit(not cedar);",
            &ConfigError::InvalidAuthorizationParse,
        );
        rejected(
            r#"permit(principal == User::"harness", action, resource);"#,
            &ConfigError::InvalidAuthorizationSchema,
        );
        rejected(
            r#"permit(principal, action == Action::"REQUEST", resource) when { context.intercepted };"#,
            &ConfigError::InvalidAuthorizationSchema,
        );
    }
}
