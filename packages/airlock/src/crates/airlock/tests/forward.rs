mod common;

use std::time::Duration;

use common::{response as read_response, start};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    time::timeout,
};

async fn send_request(socket: &mut TcpStream, request: &str) {
    socket
        .write_all(request.as_bytes())
        .await
        .expect("write proxy request");
}

async fn read_until_marker(socket: &mut TcpStream, marker: &[u8]) -> Vec<u8> {
    let mut message = Vec::new();
    let mut buffer = [0_u8; 1024];

    loop {
        let bytes = socket.read(&mut buffer).await.expect("read until marker");
        assert_ne!(bytes, 0, "peer closed before marker");
        message.extend_from_slice(&buffer[..bytes]);
        if message.windows(marker.len()).any(|window| window == marker) {
            return message;
        }
    }
}

#[tokio::test]
async fn http_proxy_forwards_absolute_requests_and_filters_hop_headers() {
    let upstream_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind HTTP upstream");
    let upstream_address = upstream_listener
        .local_addr()
        .expect("HTTP upstream address");
    let upstream = tokio::spawn(async move {
        let (mut upstream, _) = upstream_listener
            .accept()
            .await
            .expect("accept HTTP upstream");
        let request = read_response(&mut upstream).await;
        assert!(
            request.starts_with("POST /path?query=1 HTTP/1.1\r\n"),
            "{request}"
        );
        assert!(
            request.contains(&format!("host: {upstream_address}\r\n")),
            "{request}"
        );
        assert!(
            request.contains("authorization: Bearer retained\r\n"),
            "{request}"
        );
        assert!(!request.contains("proxy-authorization"), "{request}");
        assert!(!request.contains("proxy-connection"), "{request}");
        assert!(!request.contains("connection:"), "{request}");
        assert!(!request.contains("x-request-hop:"), "{request}");
        assert!(!request.contains("transfer-encoding:"), "{request}");

        upstream
            .write_all(
                b"HTTP/1.1 302 Found\r\nLocation: http://example.test/next\r\n\
                 Authorization-Info: retained\r\nConnection: x-response-hop\r\n\
                 X-Response-Hop: remove\r\nProxy-Authenticate: Basic secret\r\n\
                 Keep-Alive: timeout=1\r\nContent-Length: 2\r\n\r\nok",
            )
            .await
            .expect("write HTTP upstream response");
    });

    let proxy = start().await;
    let mut socket = proxy.client().await;
    send_request(
        &mut socket,
        &format!(
            "POST http://{upstream_address}/path?query=1 HTTP/1.1\r\nHost: wrong.test\r\n\
             Authorization: Bearer retained\r\nProxy-Authorization: Basic secret\r\n\
             Proxy-Connection: keep-alive\r\nConnection: x-request-hop\r\n\
             X-Request-Hop: remove\r\nContent-Length: 0\r\n\r\n"
        ),
    )
    .await;

    let response = read_response(&mut socket).await;
    assert!(response.starts_with("HTTP/1.1 302 "), "{response}");
    assert!(
        response.contains("location: http://example.test/next"),
        "{response}"
    );
    assert!(
        response.contains("authorization-info: retained"),
        "{response}"
    );
    assert!(response.ends_with("ok"), "{response}");
    assert!(!response.contains("proxy-authenticate"), "{response}");
    assert!(!response.contains("connection:"), "{response}");
    assert!(!response.contains("x-response-hop"), "{response}");
    assert!(!response.contains("keep-alive"), "{response}");

    upstream.await.expect("HTTP upstream task");
    drop(socket);
    proxy.stop().await;
}

#[tokio::test]
async fn http_proxy_streams_chunked_get_request_and_response_before_eof() {
    let upstream_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind streaming upstream");
    let upstream_address = upstream_listener
        .local_addr()
        .expect("streaming upstream address");
    let (request_head_send, request_head_seen) = oneshot::channel();
    let (request_first_half, request_first_seen) = oneshot::channel();
    let (response_first_send, mut response_first_seen) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (mut upstream, _) = upstream_listener
            .accept()
            .await
            .expect("accept streaming upstream");
        let head = read_response(&mut upstream).await;
        assert!(head.contains("transfer-encoding: chunked"), "{head}");
        request_head_send
            .send(())
            .expect("release request body writer");

        let mut first = [0_u8; 10];
        upstream
            .read_exact(&mut first)
            .await
            .expect("read first request chunk");
        assert_eq!(&first, b"5\r\nfirst\r\n");
        request_first_half
            .send(())
            .expect("release first response half");

        let mut final_chunk = [0_u8; 11];
        upstream
            .read_exact(&mut final_chunk)
            .await
            .expect("read final request chunk");
        assert_eq!(&final_chunk, b"6\r\nsecond\r\n");

        upstream
            .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nfirst\r\n")
            .await
            .expect("write first response chunk");
        let _ = (&mut response_first_seen).await;
        upstream
            .write_all(b"6\r\nsecond\r\n0\r\n\r\n")
            .await
            .expect("write final response chunks");
    });

    let proxy = start().await;
    let mut socket = proxy.client().await;
    send_request(
        &mut socket,
        &format!(
            "GET http://{upstream_address}/stream HTTP/1.1\r\nHost: {upstream_address}\r\n\
             Transfer-Encoding: chunked\r\n\r\n"
        ),
    )
    .await;
    timeout(Duration::from_secs(2), request_head_seen)
        .await
        .expect("upstream receives request head")
        .expect("request head channel remains open");
    send_request(&mut socket, "5\r\nfirst\r\n").await;

    timeout(Duration::from_secs(2), request_first_seen)
        .await
        .expect("first request chunk forwards before EOF")
        .expect("streaming signal channel remains open");

    send_request(&mut socket, "6\r\nsecond\r\n0\r\n\r\n").await;
    let first = timeout(
        Duration::from_secs(2),
        read_until_marker(&mut socket, b"first"),
    )
    .await
    .expect("first response chunk streams before EOF");
    let first = String::from_utf8(first).expect("first response is UTF-8");
    assert!(first.starts_with("HTTP/1.1 200 "), "{first}");

    response_first_send
        .send(())
        .expect("release final response half");
    let rest = read_until_marker(&mut socket, b"0\r\n\r\n").await;
    let rest = String::from_utf8_lossy(&rest);
    assert!(rest.contains("second"), "{rest}");

    upstream.await.expect("streaming upstream task");
    drop(socket);
    proxy.stop().await;
}

fn assert_peer_closed(outcome: std::io::Result<usize>) {
    match outcome {
        Ok(bytes) => assert_eq!(bytes, 0, "peer sent data instead of closing"),
        Err(error) => assert!(
            matches!(
                error.kind(),
                std::io::ErrorKind::ConnectionAborted | std::io::ErrorKind::ConnectionReset
            ),
            "expected EOF or connection reset, got {error}"
        ),
    }
}

#[tokio::test]
async fn http_client_disconnect_cancels_the_upstream_stream() {
    let upstream_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind cancel upstream");
    let upstream_address = upstream_listener
        .local_addr()
        .expect("cancel upstream address");
    let (upstream_closed, closed) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (mut upstream, _) = upstream_listener
            .accept()
            .await
            .expect("accept cancel upstream");
        read_response(&mut upstream).await;
        upstream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n")
            .await
            .expect("write cancel response head");
        let payload = vec![b'a'; 512_000];
        upstream.write_all(&payload).await.expect("write payload");
        let mut byte = [0_u8; 1];
        let outcome = upstream.read(&mut byte).await;
        upstream_closed
            .send(outcome)
            .expect("report upstream cancellation");
    });

    let proxy = start().await;
    let mut socket = proxy.client().await;
    send_request(
        &mut socket,
        &format!(
            "GET http://{upstream_address}/cancel HTTP/1.1\r\nHost: {upstream_address}\r\n\
             Content-Length: 0\r\n\r\n"
        ),
    )
    .await;
    let response = timeout(
        Duration::from_secs(2),
        read_until_marker(&mut socket, b"\r\n\r\n"),
    )
    .await
    .expect("streaming response headers arrive before body EOF");
    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");

    drop(socket);
    assert_peer_closed(
        timeout(Duration::from_secs(5), closed)
            .await
            .expect("upstream closes after client disconnect")
            .expect("upstream cancellation channel remains open"),
    );

    upstream.await.expect("cancel upstream task");
    proxy.stop().await;
}

#[tokio::test]
async fn http_shutdown_closes_an_idle_upstream_connection() {
    let upstream_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind idle upstream");
    let upstream_address = upstream_listener
        .local_addr()
        .expect("idle upstream address");
    let (upstream_closed, closed) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (mut upstream, _) = upstream_listener
            .accept()
            .await
            .expect("accept idle upstream");
        read_response(&mut upstream).await;
        upstream
            .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
            .await
            .expect("write idle response");
        let mut byte = [0_u8; 1];
        let end = upstream.read(&mut byte).await.expect("read idle EOF");
        assert_eq!(end, 0);
        upstream_closed.send(()).expect("report idle EOF");
    });

    let proxy = start().await;
    let mut socket = proxy.client().await;
    send_request(
        &mut socket,
        &format!(
            "GET http://{upstream_address}/idle HTTP/1.1\r\nHost: {upstream_address}\r\n\
             Content-Length: 0\r\n\r\n"
        ),
    )
    .await;
    let response = read_response(&mut socket).await;
    assert!(response.starts_with("HTTP/1.1 204 "), "{response}");

    proxy.shutdown.send(()).expect("start proxy shutdown");
    timeout(Duration::from_secs(4), proxy.task)
        .await
        .expect("HTTP shutdown is bounded")
        .expect("proxy task")
        .expect("proxy serve");
    timeout(Duration::from_secs(1), closed)
        .await
        .expect("idle upstream closes on shutdown")
        .expect("idle upstream channel remains open");
    upstream.await.expect("idle upstream task");
}

#[tokio::test]
async fn http_forwarder_reuses_same_target_and_releases_replaced_target() {
    let first_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind first target");
    let first_address = first_listener.local_addr().expect("first target address");
    let second_listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind second target");
    let second_address = second_listener.local_addr().expect("second target address");
    let (first_closed, first_eof) = oneshot::channel();
    let (second_closed, second_eof) = oneshot::channel();

    let first = tokio::spawn(async move {
        let (mut upstream, _) = first_listener.accept().await.expect("accept first target");
        for _ in 0..2 {
            read_response(&mut upstream).await;
            upstream
                .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
                .await
                .expect("write first response");
        }
        let mut byte = [0_u8; 1];
        let end = upstream.read(&mut byte).await.expect("read first EOF");
        assert_eq!(end, 0);
        first_closed.send(()).expect("report first EOF");
    });
    let second = tokio::spawn(async move {
        let (mut upstream, _) = second_listener
            .accept()
            .await
            .expect("accept second target");
        read_response(&mut upstream).await;
        upstream
            .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
            .await
            .expect("write second response");
        let mut byte = [0_u8; 1];
        let end = upstream.read(&mut byte).await.expect("read second EOF");
        assert_eq!(end, 0);
        second_closed.send(()).expect("report second EOF");
    });

    let proxy = start().await;
    let mut socket = proxy.client().await;
    for address in [first_address, first_address, second_address] {
        send_request(
            &mut socket,
            &format!(
                "GET http://{address}/target HTTP/1.1\r\nHost: {address}\r\n\
                 Content-Length: 0\r\n\r\n"
            ),
        )
        .await;
        let response = read_response(&mut socket).await;
        assert!(response.starts_with("HTTP/1.1 204 "), "{response}");
    }

    timeout(Duration::from_millis(500), first_eof)
        .await
        .expect("replaced target pool closes immediately")
        .expect("first target channel remains open");

    drop(socket);
    timeout(Duration::from_secs(2), second_eof)
        .await
        .expect("current target closes with downstream")
        .expect("second target channel remains open");

    first.await.expect("first target task");
    second.await.expect("second target task");
    proxy.stop().await;
}

#[tokio::test]
async fn http_rejects_unsupported_request_transfer_codings_before_dialing() {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind observed upstream");
    let address = listener.local_addr().expect("observed upstream address");
    let proxy = start().await;

    for coding in ["gzip, chunked", "gzip\r\nTransfer-Encoding: chunked"] {
        let mut socket = proxy.client().await;
        send_request(
            &mut socket,
            &format!(
                "POST http://{address}/coding HTTP/1.1\r\nHost: {address}\r\n\
                 Transfer-Encoding: {coding}\r\n\r\n5\r\nfirst\r\n0\r\n\r\n"
            ),
        )
        .await;
        let response = timeout(Duration::from_secs(2), read_response(&mut socket))
            .await
            .expect("reject request without waiting for upstream");
        assert!(response.starts_with("HTTP/1.1 400 "), "{response}");
    }
    assert!(
        timeout(Duration::from_millis(100), listener.accept())
            .await
            .is_err(),
        "unsupported transfer coding dialed upstream"
    );
    proxy.stop().await;
}

#[tokio::test]
async fn http_rejects_unsupported_or_ambiguous_response_framing_before_forwarding_headers() {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind framing upstream");
    let address = listener.local_addr().expect("framing upstream address");
    let upstream = tokio::spawn(async move {
        for headers in [
            "Transfer-Encoding: gzip, chunked\r\n",
            "Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n",
            "Transfer-Encoding: gzip\r\n",
            "Transfer-Encoding: chunked\r\nContent-Length: 1\r\n",
        ] {
            let (mut upstream, _) = listener.accept().await.expect("accept framing upstream");
            read_response(&mut upstream).await;
            upstream.write_all(format!(
                "HTTP/1.1 200 OK\r\n{headers}X-Upstream: must-not-forward\r\n\r\n5\r\nfirst\r\n0\r\n\r\n"
            ).as_bytes()).await.expect("write invalid upstream framing");
        }
    });
    let proxy = start().await;
    for _ in 0..4 {
        let mut socket = proxy.client().await;
        send_request(
            &mut socket,
            &format!("GET http://{address}/framing HTTP/1.1\r\nHost: {address}\r\n\r\n"),
        )
        .await;
        let response = timeout(Duration::from_secs(2), read_response(&mut socket))
            .await
            .expect("reject upstream headers promptly");
        assert!(response.starts_with("HTTP/1.1 502 "), "{response}");
        assert!(!response.contains("x-upstream"), "{response}");
        assert!(!response.contains("first"), "{response}");
    }
    upstream.await.expect("framing upstream task");
    proxy.stop().await;
}

#[tokio::test]
async fn http_disconnect_cancels_before_response_headers_and_during_stalled_upload() {
    for stalled_upload in [false, true] {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind stalled upstream");
        let address = listener.local_addr().expect("stalled upstream address");
        let (ready, observed) = oneshot::channel();
        let (body_forwarded, body_seen) = oneshot::channel();
        let (upstream_closed, closed) = oneshot::channel();
        let upstream = tokio::spawn(async move {
            let (mut upstream, _) = listener.accept().await.expect("accept stalled upstream");
            let head = read_response(&mut upstream).await;
            if stalled_upload {
                assert!(head.contains("transfer-encoding: chunked"), "{head}");
                // The client waits for this signal before writing the chunk,
                // so read_http_head cannot consume it.
                ready.send(()).expect("report stalled upload head");
                let mut first = [0_u8; 10];
                upstream
                    .read_exact(&mut first)
                    .await
                    .expect("read stalled upload chunk");
                assert_eq!(&first, b"5\r\nfirst\r\n");
            } else {
                ready.send(()).expect("report pending response");
            }
            body_forwarded
                .send(())
                .expect("report upload forwarded before EOF");
            let mut byte = [0_u8; 1];
            upstream_closed
                .send(upstream.read(&mut byte).await)
                .expect("report stalled upstream closure");
        });
        let proxy = start().await;
        let mut socket = proxy.client().await;
        let framing = if stalled_upload {
            "Transfer-Encoding: chunked\r\n"
        } else {
            ""
        };
        send_request(
            &mut socket,
            &format!("HEAD http://{address}/stalled HTTP/1.1\r\nHost: {address}\r\n{framing}\r\n"),
        )
        .await;
        timeout(Duration::from_secs(2), observed)
            .await
            .expect("upstream receives head")
            .expect("stalled upstream ready channel remains open");
        if stalled_upload {
            send_request(&mut socket, "5\r\nfirst\r\n").await;
        }
        timeout(Duration::from_secs(2), body_seen)
            .await
            .expect("HEAD upload chunk forwards before EOF")
            .expect("upload forwarding channel remains open");
        drop(socket);
        assert_peer_closed(
            timeout(Duration::from_secs(2), closed)
                .await
                .expect("client disconnect cancels pending upstream")
                .expect("stalled closure channel remains open"),
        );
        upstream.await.expect("stalled upstream task");
        proxy.stop().await;
    }
}

#[tokio::test]
async fn http_pipelined_client_reset_cancels_pending_upstream_and_accepts_new_requests() {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind pipelined upstream");
    let address = listener.local_addr().expect("pipelined upstream address");
    let (request_received, received) = oneshot::channel();
    let (upstream_closed, closed) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (mut upstream, _) = listener.accept().await.expect("accept pending upstream");
        let request = read_response(&mut upstream).await;
        assert!(
            request.starts_with("GET /pending HTTP/1.1\r\n"),
            "{request}"
        );
        request_received.send(()).expect("report pending request");
        let mut byte = [0_u8; 1];
        assert_peer_closed(upstream.read(&mut byte).await);
        upstream_closed.send(()).expect("report reset cancellation");
        drop(upstream);

        let (mut upstream, _) = listener.accept().await.expect("accept recovery upstream");
        let request = read_response(&mut upstream).await;
        assert!(
            request.starts_with("GET /recovered HTTP/1.1\r\n"),
            "{request}"
        );
        upstream
            .write_all(b"HTTP/1.1 204 No Content\r\n\r\n")
            .await
            .expect("write recovery response");
    });
    let proxy = start().await;
    let mut socket = proxy.client().await;
    // One write makes both complete requests available to Hyper's read buffer.
    let request = format!("GET http://{address}/pending HTTP/1.1\r\nHost: {address}\r\n\r\n");
    send_request(&mut socket, &request.repeat(2)).await;
    timeout(Duration::from_secs(2), received)
        .await
        .expect("upstream receives first pipelined request")
        .expect("pending request channel remains open");
    socket
        .set_zero_linger()
        .expect("force reset on client close");
    drop(socket);
    timeout(Duration::from_secs(2), closed)
        .await
        .expect("client reset cancels pending upstream despite buffered request")
        .expect("reset cancellation channel remains open");

    let mut socket = proxy.client().await;
    let response =
        common::request(&mut socket, "GET", &format!("http://{address}/recovered")).await;
    assert!(response.starts_with("HTTP/1.1 204 "), "{response}");
    upstream.await.expect("pipelined upstream task");
    drop(socket);
    proxy.stop().await;
}

#[tokio::test]
async fn http_unsupported_proxy_targets_are_rejected_without_dialing() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let proxy = start().await;
    for target in [
        format!("https://{address}/resource"),
        format!("ftp://{address}/resource"),
        format!("http://user:secret@{address}/resource"),
        "http://example.test:0/resource".to_owned(),
    ] {
        let mut socket = proxy.client().await;
        let response = common::request(&mut socket, "GET", &target).await;
        assert!(
            response.starts_with("HTTP/1.1 400 "),
            "{target}: {response}"
        );
    }
    let mut socket = proxy.client().await;
    send_request(
        &mut socket,
        &format!("GET http://{address}/resource HTTP/1.0\r\nHost: {address}\r\n\r\n"),
    )
    .await;
    let response = read_response(&mut socket).await;
    assert!(response.starts_with("HTTP/1.0 505 "), "{response}");
    assert!(
        timeout(Duration::from_millis(100), listener.accept())
            .await
            .is_err()
    );
    drop(socket);
    proxy.stop().await;
}

#[tokio::test]
async fn http_forwarding_resolves_host_names_with_the_shared_resolver() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let request = read_response(&mut socket).await;
        assert!(
            request.starts_with("GET /resolved HTTP/1.1\r\n"),
            "{request}"
        );
        socket
            .write_all(b"HTTP/1.1 204 No Content\r\n\r\n")
            .await
            .unwrap();
    });
    let proxy = start().await;
    let mut socket = proxy.client().await;
    let response = common::request(
        &mut socket,
        "GET",
        &format!("http://localhost:{port}/resolved"),
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 204 "), "{response}");
    upstream.await.unwrap();
    drop(socket);
    proxy.stop().await;
}
