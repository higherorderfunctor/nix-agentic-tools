use std::{fs, io, sync::Arc, time::Duration};

use hyper::{Request, header::HOST, server::conn::http1, service::service_fn};
use hyper_util::rt::{TokioIo, TokioTimer};
use rcgen::{CertificateParams, ExtendedKeyUsagePurpose, Issuer, KeyPair};
use rustls::{
    ServerConfig,
    pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer},
};
use time::OffsetDateTime;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    time::timeout,
};
use tokio_rustls::TlsAcceptor;
use zeroize::Zeroizing;

use crate::{
    ca::{self, Instance, RuntimeBase},
    http::authority,
};

use super::{Gateway, reply};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

pub(super) struct Interception {
    host: String,
    port: u16,
    acceptor: TlsAcceptor,
}

impl Interception {
    pub fn load(target: &str, instance: Option<String>) -> Result<Self, String> {
        let (host, port) =
            authority::parse(target).ok_or("intercept must be one explicit host:port")?;
        let host = host.trim_end_matches('.').to_owned();
        let instance = instance
            .map(|name| name.parse::<Instance>())
            .transpose()?
            .unwrap_or_default();
        let certificate_path = ca::init(&RuntimeBase::from_environment()?, &instance)?;
        let cert = fs::read(&certificate_path).map_err(|error| error.to_string())?;
        let key = Zeroizing::new(
            fs::read_to_string(certificate_path.with_file_name("ca.key"))
                .map_err(|error| error.to_string())?,
        );
        let signing_key =
            Zeroizing::new(KeyPair::from_pem(&key).map_err(|error| error.to_string())?);
        let issuer = Issuer::from_ca_cert_der(
            &pem::parse(cert)
                .map_err(|error| error.to_string())?
                .into_contents()
                .into(),
            &*signing_key,
        )
        .map_err(|error| error.to_string())?;
        let leaf = Zeroizing::new(KeyPair::generate().map_err(|error| error.to_string())?);
        let mut params =
            CertificateParams::new(vec![host.clone()]).map_err(|error| error.to_string())?;
        let now = OffsetDateTime::now_utc();
        params.not_before = now - time::Duration::hours(1);
        params.not_after = now + time::Duration::days(7);
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        let certificate = params
            .signed_by(&*leaf, &issuer)
            .map_err(|error| error.to_string())?;
        let mut server =
            ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .map_err(|error| error.to_string())?
                .with_no_client_auth()
                .with_single_cert(
                    vec![certificate.der().clone()],
                    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf.serialize_der())),
                )
                .map_err(|error| error.to_string())?;
        server.alpn_protocols = vec![b"http/1.1".to_vec()];
        Ok(Self {
            host,
            port,
            acceptor: TlsAcceptor::from(Arc::new(server)),
        })
    }

    pub fn matches(&self, host: &str, port: u16) -> bool {
        port == self.port && host.trim_end_matches('.') == self.host
    }

    fn contains(&self, request: &Request<hyper::body::Incoming>) -> bool {
        let Some(host) = request
            .headers()
            .get(HOST)
            .and_then(|value| value.to_str().ok())
        else {
            return false;
        };
        authority::parse(host)
            .or_else(|| authority::parse(&format!("{host}:443")))
            .is_some_and(|(host, port)| self.matches(&host, port))
    }
}

pub(crate) async fn serve(
    client: impl AsyncRead + AsyncWrite + Unpin + Send + 'static,
    gateway: Arc<Gateway>,
    identity: String,
) -> io::Result<()> {
    let interception = gateway
        .interception
        .as_ref()
        .expect("selected tunnel has TLS");
    let tls = timeout(HANDSHAKE_TIMEOUT, interception.acceptor.accept(client)).await??;
    if tls.get_ref().1.server_name().is_some_and(|host| {
        !host
            .trim_end_matches('.')
            .eq_ignore_ascii_case(&interception.host)
    }) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "unexpected TLS server name",
        ));
    }
    let identity: Arc<str> = identity.into();
    let service = service_fn(move |request: Request<hyper::body::Incoming>| {
        let gateway = Arc::clone(&gateway);
        let identity = Arc::clone(&identity);
        async move {
            if !gateway
                .interception
                .as_ref()
                .is_some_and(|target| target.contains(&request))
            {
                return reply(hyper::StatusCode::MISDIRECTED_REQUEST, "unexpected host\n");
            }
            if request.uri().path() != "/v1/messages" {
                return reply(hyper::StatusCode::NOT_FOUND, "unknown native operation\n");
            }
            gateway.forward(&identity, request).await
        }
    });
    http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(HANDSHAKE_TIMEOUT)
        .serve_connection(TokioIo::new(tls), service)
        .await
        .map_err(io::Error::other)
}
