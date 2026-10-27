//! What `serve` needs from the config, opened before the listener binds so a
//! bad token file, CA directory or trust root fails startup instead of a
//! request.
use std::{io, sync::Arc};

use crate::{auth::Clients, config::Config, tls::Interceptor};

pub struct Proxy {
    pub(crate) clients: Clients,
    pub(crate) interceptor: Option<Arc<Interceptor>>,
}

impl Proxy {
    pub fn load(config: &Config) -> io::Result<Self> {
        let clients = Clients::load(config.clients.as_ref())?;
        let interceptor = config
            .interception
            .as_ref()
            .map(Interceptor::open)
            .transpose()?
            .map(Arc::new);
        Ok(Self {
            clients,
            interceptor,
        })
    }
}
