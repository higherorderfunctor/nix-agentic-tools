// cspell:ignore Zml4dHVyZTp0b2tlbg
#[allow(dead_code)]
mod common;

use airlock::config::Client;
use hyper::{Request, body::Bytes};
use std::{collections::BTreeMap, fs, os::unix::fs::PermissionsExt, time::Duration};
use tempfile::TempDir;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    time::timeout,
};

const GOOD: &str = "Basic Zml4dHVyZTp0b2tlbg==";
const LIMIT: Duration = Duration::from_secs(2);

async fn fixture() -> (common::Server, TempDir) {
    let directory = TempDir::new().unwrap();
    let path = directory.path().join("token");
    fs::write(&path, b"token\n").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let clients = BTreeMap::from([("fixture".into(), Client { token_file: path })]);
    (common::start_with_clients(Some(clients)).await, directory)
}

async fn no_dial(listener: &TcpListener) {
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err(),
        "rejected admission must not dial"
    );
}

fn challenge(headers: &str) {
    assert!(headers.starts_with("HTTP/1.1 407 "), "{headers}");
    assert!(headers.contains("proxy-authenticate: Basic realm=\"airlock\", charset=\"UTF-8\"\r\n"));
}

#[tokio::test]
async fn h1_admits_each_forward_request_and_connect_before_dial() {
    let (proxy, _directory) = fixture().await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let mut client = proxy.client().await;
    assert!(
        common::request(&mut client, "GET", "/health")
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    for headers in [
        String::new(),
        "Proxy-Authorization: Basic !!!!\r\n".into(),
        "Proxy-Authorization: Basic Zml4dHVyZTp3cm9uZw==\r\n".into(),
        format!("Proxy-Authorization: {GOOD}\r\nProxy-Authorization: {GOOD}\r\n"),
    ] {
        client
            .write_all(
                format!("GET http://{address}/health HTTP/1.1\r\nHost: localhost\r\n{headers}\r\n")
                    .as_bytes(),
            )
            .await
            .unwrap();
        challenge(&common::response(&mut client).await);
        no_dial(&listener).await;
    }
    client.write_all(format!("GET http://{address}/native HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer native\r\nProxy-Authorization: {GOOD}\r\n\r\n").as_bytes()).await.unwrap();
    let (mut upstream, _) = timeout(LIMIT, listener.accept()).await.unwrap().unwrap();
    let headers = common::response(&mut upstream).await;
    assert!(headers.contains("authorization: Bearer native\r\n"));
    assert!(!headers.contains("proxy-authorization"));
    upstream
        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        .await
        .unwrap();
    assert!(
        common::response(&mut client)
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    challenge(&common::request(&mut client, "GET", &format!("http://{address}/native")).await);
    no_dial(&listener).await;
    drop(client);
    drop(upstream);

    let mut client = proxy.client().await;
    challenge(&common::request(&mut client, "CONNECT", &address.to_string()).await);
    no_dial(&listener).await;
    client.write_all(format!("CONNECT {address} HTTP/1.1\r\nHost: {address}\r\nProxy-Authorization: {GOOD}\r\n\r\n").as_bytes()).await.unwrap();
    let (mut upstream, _) = timeout(LIMIT, listener.accept()).await.unwrap().unwrap();
    assert!(
        common::response(&mut client)
            .await
            .starts_with("HTTP/1.1 200 ")
    );
    client.write_all(b"echo").await.unwrap();
    let mut bytes = [0; 4];
    timeout(LIMIT, upstream.read_exact(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&bytes, b"echo");
    upstream.write_all(&bytes).await.unwrap();
    timeout(LIMIT, client.read_exact(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&bytes, b"echo");
    drop(client);
    drop(upstream);
    proxy.stop().await;
}

#[tokio::test]
async fn h2_rejects_then_accepts_streams_on_the_same_connection() {
    let (proxy, _directory) = fixture().await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (sender, driver) = h2::client::handshake(proxy.client().await).await.unwrap();
    let driver = tokio::spawn(driver);
    let mut sender = sender.ready().await.unwrap();
    let (response, _) = sender
        .send_request(
            Request::builder()
                .uri("http://localhost/health")
                .body(())
                .unwrap(),
            true,
        )
        .unwrap();
    assert_eq!(
        timeout(LIMIT, response).await.unwrap().unwrap().status(),
        200
    );
    for values in [
        vec![],
        vec!["Basic !!!!"],
        vec![GOOD, GOOD],
        vec![GOOD],
        vec![],
    ] {
        let mut request = Request::builder()
            .method("CONNECT")
            .uri(address.to_string())
            .body(())
            .unwrap();
        for value in &values {
            request
                .headers_mut()
                .append(hyper::header::PROXY_AUTHORIZATION, value.parse().unwrap());
        }
        let valid = values == vec![GOOD];
        let (response, mut send) = sender.send_request(request, false).unwrap();
        let response = timeout(LIMIT, response).await.unwrap().unwrap();
        if valid {
            assert_eq!(response.status(), 200);
            let (mut upstream, _) = timeout(LIMIT, listener.accept()).await.unwrap().unwrap();
            send.send_data(Bytes::from_static(b"echo"), true).unwrap();
            let mut bytes = [0; 4];
            timeout(LIMIT, upstream.read_exact(&mut bytes))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(&bytes, b"echo");
            upstream.write_all(&bytes).await.unwrap();
            upstream.shutdown().await.unwrap();
            let mut recv = response.into_body();
            let mut result = Vec::new();
            timeout(LIMIT, async {
                while let Some(data) = recv.data().await {
                    result.extend_from_slice(&data.unwrap());
                }
            })
            .await
            .unwrap();
            assert_eq!(result, b"echo");
        } else {
            assert_eq!(response.status(), 407);
            assert_eq!(
                response.headers()[hyper::header::PROXY_AUTHENTICATE],
                "Basic realm=\"airlock\", charset=\"UTF-8\""
            );
            no_dial(&listener).await;
        }
    }
    drop(sender);
    driver.abort();
    proxy.stop().await;
}
