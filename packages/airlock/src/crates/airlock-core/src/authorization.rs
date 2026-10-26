use std::{str::FromStr, sync::Arc};

use cedar_policy::{
    Authorizer, Context, Decision as CedarDecision, Entities, EntityId, EntityTypeName, EntityUid,
    PolicySet, Request, RestrictedExpression, Schema, ValidationMode, Validator,
};

use crate::ids::{ClientId, CredentialId, GroupId, HostName, ProviderId};

/// Stage at which an inline Cedar policy was rejected. Error details stay out of this type:
/// Cedar diagnostics can quote policy source, which must not reach logs or clients.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthorizationError {
    Parse,
    Schema,
}

struct CompiledPolicy {
    client_type: EntityTypeName,
    connect_action: EntityUid,
    credential_type: EntityTypeName,
    host_type: EntityTypeName,
    policies: PolicySet,
    request_action: EntityUid,
    schema: Schema,
}

#[derive(Clone)]
pub struct Authorization {
    compiled: Arc<CompiledPolicy>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Evaluation {
    Allow,
    Deny,
    Error,
}

#[derive(Clone, Copy)]
pub enum RequestOperation {
    Classifier,
    Inference,
    Oauth,
    Other,
}

impl RequestOperation {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Classifier => "classifier",
            Self::Inference => "inference",
            Self::Oauth => "oauth",
            Self::Other => "other",
        }
    }
}

pub struct RequestFacts<'input> {
    pub client: &'input ClientId,
    pub credential: &'input CredentialId,
    pub group: &'input GroupId,
    pub model: Option<&'input str>,
    pub operation: RequestOperation,
    pub primary: bool,
    pub provider: &'input ProviderId,
}

impl Authorization {
    /// Compile an inline policy. `None` selects the explicit built-in permit-all policy;
    /// an empty string selects an empty policy set and therefore denies every action.
    pub(crate) fn compile(policy: Option<&str>) -> Result<Self, AuthorizationError> {
        let schema = Schema::from_str(
            r"
            entity Client, Host, Credential;
            action CONNECT appliesTo {
              principal: Client,
              resource: Host,
              context: { intercepted: Bool, group?: String }
            };
            action REQUEST appliesTo {
              principal: Client,
              resource: Credential,
              context: {
                group: String,
                model?: String,
                operation: String,
                primary: Bool,
                provider: String
              }
            };
            ",
        )
        .map_err(|_| AuthorizationError::Schema)?;
        let client_type =
            EntityTypeName::from_str("Client").map_err(|_| AuthorizationError::Schema)?;
        let credential_type =
            EntityTypeName::from_str("Credential").map_err(|_| AuthorizationError::Schema)?;
        let host_type = EntityTypeName::from_str("Host").map_err(|_| AuthorizationError::Schema)?;
        let connect_action = action("CONNECT")?;
        let request_action = action("REQUEST")?;
        let source = policy.unwrap_or("permit(principal, action, resource);");
        let policies = PolicySet::from_str(source).map_err(|_| AuthorizationError::Parse)?;
        let validation = Validator::new(schema.clone()).validate(&policies, ValidationMode::Strict);
        if !validation.validation_passed() {
            return Err(AuthorizationError::Schema);
        }
        Ok(Self {
            compiled: Arc::new(CompiledPolicy {
                client_type,
                connect_action,
                credential_type,
                host_type,
                policies,
                request_action,
                schema,
            }),
        })
    }

    pub(crate) fn evaluate(
        &self,
        client: &ClientId,
        host: &HostName,
        group: Option<&GroupId>,
    ) -> Evaluation {
        let compiled = &self.compiled;
        let mut context = vec![(
            "intercepted".to_owned(),
            RestrictedExpression::new_bool(group.is_some()),
        )];
        if let Some(group) = group {
            context.push((
                "group".to_owned(),
                RestrictedExpression::new_string(group.as_ref().to_owned()),
            ));
        }
        let Ok(context) = Context::from_pairs(context) else {
            return Evaluation::Error;
        };
        let principal = EntityUid::from_type_name_and_id(
            compiled.client_type.clone(),
            EntityId::new(client.as_ref()),
        );
        let resource = EntityUid::from_type_name_and_id(
            compiled.host_type.clone(),
            EntityId::new(host.as_ref()),
        );
        evaluate(
            compiled,
            principal,
            compiled.connect_action.clone(),
            resource,
            context,
        )
    }

    pub(crate) fn evaluate_request(&self, facts: &RequestFacts<'_>) -> Evaluation {
        let compiled = &self.compiled;
        let mut context = vec![
            (
                "group".to_owned(),
                RestrictedExpression::new_string(facts.group.as_ref().to_owned()),
            ),
            (
                "operation".to_owned(),
                RestrictedExpression::new_string(facts.operation.as_str().to_owned()),
            ),
            (
                "primary".to_owned(),
                RestrictedExpression::new_bool(facts.primary),
            ),
            (
                "provider".to_owned(),
                RestrictedExpression::new_string(facts.provider.as_ref().to_owned()),
            ),
        ];
        if let Some(model) = facts.model {
            context.push((
                "model".to_owned(),
                RestrictedExpression::new_string(model.to_owned()),
            ));
        }
        let Ok(context) = Context::from_pairs(context) else {
            return Evaluation::Error;
        };
        let principal = EntityUid::from_type_name_and_id(
            compiled.client_type.clone(),
            EntityId::new(facts.client.as_ref()),
        );
        let resource = EntityUid::from_type_name_and_id(
            compiled.credential_type.clone(),
            EntityId::new(facts.credential.as_ref()),
        );
        evaluate(
            compiled,
            principal,
            compiled.request_action.clone(),
            resource,
            context,
        )
    }
}

fn action(name: &'static str) -> Result<EntityUid, AuthorizationError> {
    let action_type = EntityTypeName::from_str("Action").map_err(|_| AuthorizationError::Schema)?;
    Ok(EntityUid::from_type_name_and_id(
        action_type,
        EntityId::new(name),
    ))
}

fn evaluate(
    compiled: &CompiledPolicy,
    principal: EntityUid,
    action: EntityUid,
    resource: EntityUid,
    context: Context,
) -> Evaluation {
    let Ok(request) = Request::new(principal, action, resource, context, Some(&compiled.schema))
    else {
        return Evaluation::Error;
    };
    let response =
        Authorizer::new().is_authorized(&request, &compiled.policies, &Entities::empty());
    if response.diagnostics().errors().next().is_some() {
        return Evaluation::Error;
    }
    match response.decision() {
        CedarDecision::Allow => Evaluation::Allow,
        CedarDecision::Deny => Evaluation::Deny,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cloned_authorizers_share_one_compiled_policy() {
        let authorization = Authorization::compile(None).expect("authorization");
        let shared = authorization.clone();
        assert!(Arc::ptr_eq(&authorization.compiled, &shared.compiled));
    }

    #[test]
    fn omitted_policy_permits_and_empty_policy_denies_requests() {
        let client = ClientId::try_from("harness").expect("client");
        let group = GroupId::try_from("anthropic").expect("group");
        let credential = CredentialId::try_from("claude").expect("credential");
        let provider = ProviderId::try_from("claude").expect("provider");
        let facts = RequestFacts {
            client: &client,
            credential: &credential,
            group: &group,
            model: None,
            operation: RequestOperation::Other,
            primary: true,
            provider: &provider,
        };
        let omitted = Authorization::compile(None).expect("authorization");
        assert_eq!(omitted.evaluate_request(&facts), Evaluation::Allow);
        let empty = Authorization::compile(Some("")).expect("authorization");
        assert_eq!(empty.evaluate_request(&facts), Evaluation::Deny);
    }

    #[test]
    fn request_evaluation_errors_fail_closed() {
        let client = ClientId::try_from("harness").expect("client");
        let group = GroupId::try_from("anthropic").expect("group");
        let credential = CredentialId::try_from("claude").expect("credential");
        let provider = ProviderId::try_from("claude").expect("provider");
        let source = r#"
            permit(principal, action, resource);
            permit(
                principal == Client::"harness",
                action == Action::"REQUEST",
                resource == Credential::"claude"
            ) when { 9223372036854775807 + 1 == 1 };
        "#;
        let authorization = Authorization::compile(Some(source)).expect("authorization");
        let facts = RequestFacts {
            client: &client,
            credential: &credential,
            group: &group,
            model: Some("claude-sonnet-5"),
            operation: RequestOperation::Inference,
            primary: true,
            provider: &provider,
        };
        assert_eq!(authorization.evaluate_request(&facts), Evaluation::Error);
    }
}
