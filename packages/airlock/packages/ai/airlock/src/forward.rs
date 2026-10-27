//! Absolute-form `http://` requests: validate the target and stream each
//! exchange over one upstream connection owned by the downstream connection.
use std::io;

use http_body_util::Either;
use hyper::{
    Request, StatusCode, Uri, Version, body::Incoming, client::conn::http1, header::HeaderValue,
};
use hyper_util::rt::TokioIo;
use tokio::{task::JoinHandle, time::timeout};

use crate::{
    client::replies::proxy_response,
    http::message::{ProxyResponse, prepare_request, prepare_response},
    upstream::{CONNECT_TIMEOUT, connect_upstream},
};

/// HTTP/1 serves serial exchanges; only the current target's sender is cached.
pub(crate) struct Forwarder {
    current: Option<Upstream>,
}

impl Forwarder {
    pub(crate) fn new() -> Self {
        Self { current: None }
    }

    pub(crate) async fn forward(&mut self, mut request: Request<Incoming>) -> ProxyResponse {
        let Some(target) = ForwardTarget::parse(request.uri()) else {
            return proxy_response(StatusCode::BAD_REQUEST, "malformed HTTP proxy target\n");
        };
        if let Err((status, message)) = prepare_request(&mut request, Version::HTTP_11) {
            return proxy_response(status, message);
        }
        request.headers_mut().insert(
            hyper::header::HOST,
            HeaderValue::from_str(&target.authority).expect("validated authority is header-safe"),
        );
        *request.uri_mut() = request
            .uri()
            .path_and_query()
            .expect("absolute URI has a path")
            .clone()
            .into();

        let method = request.method().clone();
        let mut response = match self.sender_for(target).await {
            Ok(sender) => match sender.send_request(request).await {
                Ok(response) => response,
                Err(_) => {
                    self.current = None;
                    return proxy_response(StatusCode::BAD_GATEWAY, "upstream request failed\n");
                }
            },
            Err(_) => return proxy_response(StatusCode::BAD_GATEWAY, "upstream connect failed\n"),
        };
        if let Err(message) = prepare_response(&mut response, &method) {
            self.current = None;
            return proxy_response(StatusCode::BAD_GATEWAY, message);
        }
        response.map(Either::Right)
    }

    async fn sender_for(
        &mut self,
        target: ForwardTarget,
    ) -> io::Result<&mut http1::SendRequest<Incoming>> {
        if let Some(current) = &mut self.current
            && current.authority == target.authority
            && current.sender.ready().await.is_ok()
        {
            return Ok(&mut self.current.as_mut().expect("current sender").sender);
        }
        // Release the old socket before waiting for the next destination.
        self.current = None;
        let socket = timeout(CONNECT_TIMEOUT, connect_upstream(target.host, target.port))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "upstream connect timed out"))??;
        let (sender, connection) = http1::handshake(TokioIo::new(socket))
            .await
            .map_err(io::Error::other)?;
        let driver = tokio::spawn(async move {
            let _ = connection.await;
        });
        let current = self.current.insert(Upstream {
            authority: target.authority,
            driver,
            sender,
        });
        Ok(&mut current.sender)
    }
}

struct Upstream {
    authority: String,
    driver: JoinHandle<()>,
    sender: http1::SendRequest<Incoming>,
}

impl Drop for Upstream {
    fn drop(&mut self) {
        // A dropped sender alone can leave the driver reading a stalled body.
        self.driver.abort();
    }
}

struct ForwardTarget {
    authority: String,
    host: String,
    port: u16,
}

impl ForwardTarget {
    fn parse(uri: &Uri) -> Option<Self> {
        if uri.scheme().map(|scheme| scheme.as_str()) != Some("http") {
            return None;
        }
        let authority = uri.authority()?;
        let (host, port) = crate::http::authority::parse(authority.as_str(), Some(80))?;
        Some(Self {
            authority: authority.as_str().to_owned(),
            host,
            port,
        })
    }
}

// Target parsing is private; default-port fixtures do not need a bound port 80.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_port_and_implicit_path_targets_are_valid() {
        for uri in ["http://example.test", "http://example.test?query=1"] {
            let target = ForwardTarget::parse(&uri.parse().unwrap()).unwrap();
            assert_eq!(target.authority, "example.test");
            assert_eq!(target.host, "example.test");
            assert_eq!(target.port, 80);
        }
        let target = ForwardTarget::parse(&"http://[::1]/".parse().unwrap()).unwrap();
        assert_eq!(target.host, "::1");
        assert_eq!(target.port, 80);
    }
}
