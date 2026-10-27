// cspell:words alpn
//! TLS interception fixtures: an outer CONNECT tunnel over HTTP/1 or HTTP/2,
//! an intercepting Airlock with its own CA, and a client that trusts that CA.
use std::{fs, io, net::SocketAddr, sync::Arc, time::Duration};

use airlock::{ca, config::Interception};
use h2::SendStream;
use hyper::body::Bytes;
use rcgen::{CertificateParams, KeyPair};
use rustls::{
    ClientConfig, RootCertStore, ServerConfig,
    pki_types::{PrivatePkcs8KeyDer, ServerName},
};
use tempfile::TempDir;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
    sync::Mutex,
    task::JoinHandle,
    time::timeout,
};
use tokio_rustls::TlsConnector;

use super::h2_client;

pub const LIMIT: Duration = Duration::from_secs(3);
pub trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}
pub type BoxIo = Box<dyn Io>;

/// Keeps an HTTP/2 outer tunnel open; dropping it resets the CONNECT stream
/// and stops the client. An HTTP/1 tunnel needs no guard.
#[derive(Default)]
pub struct Guards {
    // Dropped with the guard, which stops the HTTP/2 connection driver.
    _client: Option<h2_client::Client>,
    relay: Option<JoinHandle<()>>,
    pub reset: Option<Arc<Mutex<SendStream<Bytes>>>>,
}
impl Drop for Guards {
    fn drop(&mut self) {
        // A busy relay holds the lock; aborting it below still resets the
        // stream, because h2 cancels a stream whose handles are all dropped.
        if let Some(send) = &self.reset
            && let Ok(mut send) = send.try_lock()
        {
            send.send_reset(h2::Reason::CANCEL);
        }
        if let Some(relay) = &self.relay {
            relay.abort();
        }
    }
}

pub async fn outer(address: SocketAddr, target: &str, h2: bool) -> (BoxIo, Guards) {
    let mut socket = TcpStream::connect(address).await.unwrap();
    if !h2 {
        let response = super::request(&mut socket, "CONNECT", target).await;
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        return (Box::new(socket), Guards::default());
    }
    let client = h2_client::Client::connect(address).await;
    let (send, mut recv) = client.tunnel(target).await;
    // Shared with `Guards`, so a test can reset the stream itself.
    let send = Arc::new(Mutex::new(send));
    let writer = Arc::clone(&send);
    let (io, bridge) = tokio::io::duplex(8192);
    let (mut read, mut write) = tokio::io::split(bridge);
    // Copy between the duplex end the test holds and the CONNECT stream.
    let relay = tokio::spawn(async move {
        let upload = async {
            let mut buffer = [0; 8192];
            loop {
                let count = read.read(&mut buffer).await?;
                let mut writer = writer.lock().await;
                if count == 0 {
                    return writer
                        .send_data(Bytes::new(), true)
                        .map_err(io::Error::other);
                }
                h2_client::write(&mut writer, Bytes::copy_from_slice(&buffer[..count]))
                    .await
                    .map_err(io::Error::other)?;
            }
        };
        let download = async {
            while let Some(bytes) = recv.data().await {
                let bytes = bytes.map_err(io::Error::other)?;
                write.write_all(&bytes).await?;
                recv.flow_control()
                    .release_capacity(bytes.len())
                    .map_err(io::Error::other)?;
            }
            write.shutdown().await
        };
        let _ = tokio::try_join!(upload, download);
    });
    (
        Box::new(io),
        Guards {
            _client: Some(client),
            relay: Some(relay),
            reset: Some(send),
        },
    )
}

pub fn fixture_certificate(host: &str, expired: bool) -> (Arc<ServerConfig>, String) {
    let mut parameters = CertificateParams::new(vec![host.to_owned()]).unwrap();
    if expired {
        parameters.not_before = time::OffsetDateTime::now_utc() - time::Duration::days(2);
        parameters.not_after = time::OffsetDateTime::now_utc() - time::Duration::days(1);
    }
    let key = KeyPair::generate().unwrap();
    let certificate = parameters.self_signed(&key).unwrap();
    let mut config =
        ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![certificate.der().clone()],
                PrivatePkcs8KeyDer::from(key.serialize_der()).into(),
            )
            .unwrap();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    (Arc::new(config), certificate.pem())
}

pub async fn proxy(directory: &TempDir, target: SocketAddr, root: Option<&str>) -> super::Server {
    let ca_directory = directory.path().join("ca");
    ca::init(&ca_directory).unwrap();
    // Keep fixtures hermetic when a Nix build has no host certificate store.
    // None trusts an unrelated fixture, so untrusted origins still fail closed.
    let fallback = fixture_certificate("unused.test", false).1;
    let path = directory.path().join("upstream.pem");
    fs::write(&path, root.unwrap_or(&fallback)).unwrap();
    super::start_with(Some(Interception {
        ca_directory,
        destinations: vec![format!("localhost:{}", target.port())],
        upstream_roots: Some(path),
    }))
    .await
}

pub fn client_config(directory: &TempDir) -> Arc<ClientConfig> {
    let pem = pem::parse(fs::read(directory.path().join("ca/ca.pem")).unwrap()).unwrap();
    let mut roots = RootCertStore::empty();
    roots.add(pem.into_contents().into()).unwrap();
    let mut config =
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_root_certificates(roots)
            .with_no_client_auth();
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Arc::new(config)
}

pub async fn tls_client(
    directory: &TempDir,
    socket: BoxIo,
    name: &str,
) -> io::Result<tokio_rustls::client::TlsStream<BoxIo>> {
    timeout(
        LIMIT,
        TlsConnector::from(client_config(directory))
            .connect(ServerName::try_from(name.to_owned()).unwrap(), socket),
    )
    .await
    .unwrap()
}
