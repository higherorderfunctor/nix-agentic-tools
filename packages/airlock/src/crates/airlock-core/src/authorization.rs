use std::{str::FromStr, sync::Arc};

use cedar_policy::{
    Authorizer, Context, Decision as CedarDecision, Entities, EntityId, EntityTypeName, EntityUid,
    PolicySet, Request, RestrictedExpression, Schema, ValidationMode, Validator,
};

use crate::ids::{ClientId, GroupId, HostName};

/// Stage at which an inline Cedar policy was rejected. Error details stay out of this type:
/// Cedar diagnostics can quote policy source, which must not reach logs or clients.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthorizationError {
    Parse,
    Schema,
}

struct CompiledPolicy {
    action: EntityUid,
    client_type: EntityTypeName,
    host_type: EntityTypeName,
    policies: PolicySet,
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

impl Authorization {
    /// Compile an inline policy. `None` selects the explicit built-in permit-all policy;
    /// an empty string selects an empty policy set and therefore denies every action.
    pub(crate) fn compile(policy: Option<&str>) -> Result<Self, AuthorizationError> {
        let schema = Schema::from_str(
            r"
            entity Client, Host;
            action CONNECT appliesTo {
              principal: Client,
              resource: Host,
              context: { intercepted: Bool, group?: String }
            };
            ",
        )
        .map_err(|_| AuthorizationError::Schema)?;
        let client_type =
            EntityTypeName::from_str("Client").map_err(|_| AuthorizationError::Schema)?;
        let host_type = EntityTypeName::from_str("Host").map_err(|_| AuthorizationError::Schema)?;
        let action_type =
            EntityTypeName::from_str("Action").map_err(|_| AuthorizationError::Schema)?;
        let action = EntityUid::from_type_name_and_id(action_type, EntityId::new("CONNECT"));
        let source = policy.unwrap_or("permit(principal, action, resource);");
        let policies = PolicySet::from_str(source).map_err(|_| AuthorizationError::Parse)?;
        let validation = Validator::new(schema.clone()).validate(&policies, ValidationMode::Strict);
        if !validation.validation_passed() {
            return Err(AuthorizationError::Schema);
        }
        Ok(Self {
            compiled: Arc::new(CompiledPolicy {
                action,
                client_type,
                host_type,
                policies,
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
        let Ok(request) = Request::new(
            principal,
            compiled.action.clone(),
            resource,
            context,
            Some(&compiled.schema),
        ) else {
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
}
