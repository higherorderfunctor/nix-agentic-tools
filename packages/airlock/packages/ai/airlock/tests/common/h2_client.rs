//! A prior-knowledge HTTP/2 client: open CONNECT tunnels and move bytes
//! through them within the stream's flow-control window.
use std::{fmt::Display, future::poll_fn, net::SocketAddr, time::Duration};

use h2::{RecvStream, SendStream, client::SendRequest};
use hyper::{Request, StatusCode, Version, body::Bytes, header::PROXY_AUTHORIZATION};
use tokio::{net::TcpStream, task::JoinHandle, time::timeout};

/// An HTTP/2 connection to Airlock. Dropping it stops the connection driver.
pub struct Client {
    pub sender: SendRequest<Bytes>,
    pub driver: JoinHandle<Result<(), h2::Error>>,
    authorization: Option<&'static str>,
}

impl Drop for Client {
    fn drop(&mut self) {
        self.driver.abort();
    }
}

impl Client {
    pub async fn connect(address: SocketAddr) -> Self {
        let socket = TcpStream::connect(address).await.unwrap();
        let (sender, connection) = h2::client::handshake(socket).await.unwrap();
        Self {
            sender,
            driver: tokio::spawn(connection),
            authorization: None,
        }
    }

    /// Send `value` as `Proxy-Authorization` on each tunnel request.
    pub fn authorized(mut self, value: &'static str) -> Self {
        self.authorization = Some(value);
        self
    }

    /// Open a CONNECT stream to `target` and require a `200`.
    pub async fn tunnel(&self, target: impl Display) -> (SendStream<Bytes>, RecvStream) {
        let mut sender = self.sender.clone().ready().await.unwrap();
        let mut request = Request::builder()
            .method("CONNECT")
            .uri(target.to_string())
            .version(Version::HTTP_2);
        if let Some(value) = self.authorization {
            request = request.header(PROXY_AUTHORIZATION, value);
        }
        let request = request.body(()).unwrap();
        let (response, send) = sender.send_request(request, false).unwrap();
        let response = timeout(Duration::from_secs(2), response)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.version(), Version::HTTP_2);
        (send, response.into_body())
    }
}

/// Send `bytes` as DATA frames, waiting for window capacity as needed.
pub async fn write(send: &mut SendStream<Bytes>, mut bytes: Bytes) -> Result<(), h2::Error> {
    while !bytes.is_empty() {
        send.reserve_capacity(bytes.len());
        let capacity = poll_fn(|cx| send.poll_capacity(cx))
            .await
            .ok_or(h2::Reason::STREAM_CLOSED)??;
        let count = capacity.min(bytes.len());
        send.send_data(bytes.split_to(count), false)?;
    }
    Ok(())
}

/// Send `bytes`, then end the stream.
pub async fn send_all(send: &mut SendStream<Bytes>, bytes: Bytes) {
    write(send, bytes).await.unwrap();
    send.send_data(Bytes::new(), true).unwrap();
}

/// Read the stream to its end, reopening the window for each frame read.
pub async fn read_all(recv: &mut RecvStream) -> Vec<u8> {
    let mut result = Vec::new();
    while let Some(data) = recv.data().await {
        let data = data.unwrap();
        recv.flow_control().release_capacity(data.len()).unwrap();
        result.extend_from_slice(&data);
    }
    result
}
