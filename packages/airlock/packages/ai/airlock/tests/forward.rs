mod common;

use std::time::Duration;

use common::{message, start};
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
    let mut received = Vec::new();
    let mut buffer = [0_u8; 1024];

    loop {
        let bytes = socket.read(&mut buffer).await.expect("read until marker");
        assert_ne!(bytes, 0, "peer closed before marker");
        received.extend_from_slice(&buffer[..bytes]);
        if received
            .windows(marker.len())
            .any(|window| window == marker)
        {
            return received;
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
        let request = message(&mut upstream).await;
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

    let response = message(&mut socket).await;
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
        let head = message(&mut upstream).await;
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
        message(&mut upstream).await;
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
        message(&mut upstream).await;
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
    let response = message(&mut socket).await;
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
            message(&mut upstream).await;
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
        message(&mut upstream).await;
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
        let response = message(&mut socket).await;
        assert!(response.starts_with("HTTP/1.1 204 "), "{response}");
    }

    timeout(Duration::from_millis(500), first_eof)
        .await
        .expect("replaced target connection closes immediately")
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
async fn http_rejects_unsupported_request_transfer_codings_before_connecting() {
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
        let response = timeout(Duration::from_secs(2), message(&mut socket))
            .await
            .expect("reject request without waiting for upstream");
        assert!(response.starts_with("HTTP/1.1 400 "), "{response}");
    }
    assert!(
        timeout(Duration::from_millis(100), listener.accept())
            .await
            .is_err(),
        "unsupported transfer coding connected upstream"
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
            message(&mut upstream).await;
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
        let response = timeout(Duration::from_secs(2), message(&mut socket))
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
async fn http_reset_cancels_before_response_headers_and_during_stalled_upload() {
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
            let head = message(&mut upstream).await;
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
        socket.set_zero_linger().expect("reset abandoned request");
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
        let request = message(&mut upstream).await;
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
        let request = message(&mut upstream).await;
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
async fn http_unsupported_proxy_targets_are_rejected_without_connecting() {
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
    let response = message(&mut socket).await;
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
        let request = message(&mut socket).await;
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

#[tokio::test]
async fn http_forwarding_delivers_response_after_client_fin() {
    forwarding_after_half_close("GET", "").await;
}

#[tokio::test]
async fn http_forwarding_answers_post_after_client_half_close() {
    forwarding_after_half_close("POST", "body").await;
}

async fn forwarding_after_half_close(method: &'static str, body: &'static str) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (respond, after_fin) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let request = message(&mut socket).await;
        assert!(
            request.starts_with(&format!("{method} /half-close HTTP/1.1\r\n")),
            "{request}"
        );
        assert!(request.ends_with(body), "{request}");
        after_fin.await.unwrap();
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            .await
            .unwrap();
    });
    let proxy = start().await;
    let mut socket = proxy.client().await;
    let framing = if method == "GET" {
        String::new()
    } else {
        format!("Content-Length: {}\r\n", body.len())
    };
    send_request(&mut socket, &format!("{method} http://{address}/half-close HTTP/1.1\r\nHost: {address}\r\n{framing}\r\n{body}")).await;
    socket.shutdown().await.unwrap();
    respond.send(()).unwrap();
    let response = message(&mut socket).await;
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");
    assert!(response.ends_with("ok"), "{response}");
    upstream.await.unwrap();
    drop(socket);
    proxy.stop().await;
}

#[tokio::test]
async fn http_forwarding_preserves_request_trailers() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (head_sent, head_seen) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let head = message(&mut socket).await;
        assert!(head.contains("trailer: x-request-signature\r\n"), "{head}");
        assert!(!head.contains("\r\nte:"), "{head}");
        head_sent.send(()).unwrap();
        let body = timeout(
            Duration::from_secs(2),
            read_until_marker(&mut socket, b"0\r\nx-request-signature: abc\r\n\r\n"),
        )
        .await
        .expect("request trailer forwards");
        assert!(body.starts_with(b"4\r\nbody\r\n"), "{body:?}");
        socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: x-response-signature\r\n\r\n4\r\nbody\r\n0\r\nx-response-signature: def\r\n\r\n").await.unwrap();
    });
    let proxy = start().await;
    let mut socket = proxy.client().await;
    send_request(&mut socket, &format!("POST http://{address}/trailers HTTP/1.1\r\nHost: {address}\r\nTransfer-Encoding: chunked\r\nTE: trailers\r\nTrailer: x-request-signature\r\n\r\n")).await;
    timeout(Duration::from_secs(2), head_seen)
        .await
        .unwrap()
        .unwrap();
    send_request(
        &mut socket,
        "4\r\nbody\r\n0\r\nx-request-signature: abc\r\n\r\n",
    )
    .await;
    let response = timeout(
        Duration::from_secs(2),
        read_until_marker(&mut socket, b"0\r\nx-response-signature: def\r\n\r\n"),
    )
    .await
    .expect("response trailer forwards");
    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");
    assert!(
        response.contains("trailer: x-response-signature\r\n"),
        "{response}"
    );
    upstream.await.unwrap();
    drop(socket);
    proxy.stop().await;
}

#[tokio::test]
async fn http_forwarding_normalizes_response_content_length() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        message(&mut socket).await;
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2, 2\r\n\r\nok")
            .await
            .unwrap();
    });
    let proxy = start().await;
    let mut socket = proxy.client().await;
    let response = common::request(&mut socket, "GET", &format!("http://{address}/length")).await;
    assert!(response.contains("content-length: 2\r\n"), "{response}");
    assert!(response.ends_with("ok"), "{response}");
    upstream.await.unwrap();
    drop(socket);
    proxy.stop().await;
}

#[tokio::test]
async fn http_forwarding_strips_opportunistic_upgrade() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let request = message(&mut socket).await;
        assert!(
            request.starts_with("GET /upgrade HTTP/1.1\r\n"),
            "{request}"
        );
        assert!(
            !request.to_ascii_lowercase().contains("upgrade:"),
            "{request}"
        );
        assert!(
            !request.to_ascii_lowercase().contains("connection:"),
            "{request}"
        );
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            .await
            .unwrap();
    });
    let proxy = start().await;
    let mut socket = proxy.client().await;
    send_request(&mut socket, &format!("GET http://{address}/upgrade HTTP/1.1\r\nHost: {address}\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n")).await;
    let response = message(&mut socket).await;
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");
    assert!(response.ends_with("ok"), "{response}");
    upstream.await.unwrap();
    drop(socket);
    proxy.stop().await;
}

#[tokio::test]
async fn http_forwarding_rejects_upstream_switching_protocols() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        message(&mut socket).await;
        socket.write_all(b"HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n").await.unwrap();
    });
    let proxy = start().await;
    let mut socket = proxy.client().await;
    let response = common::request(&mut socket, "GET", &format!("http://{address}/upgrade")).await;
    assert!(response.starts_with("HTTP/1.1 502 "), "{response}");
    upstream.await.unwrap();
    drop(socket);
    proxy.stop().await;
}

#[tokio::test]
async fn http_forwarding_preserves_response_trailers() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        message(&mut socket).await;
        socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: x-signature\r\n\r\n4\r\nbody\r\n0\r\nx-signature: abc\r\n\r\n").await.unwrap();
    });
    let proxy = start().await;
    let mut socket = proxy.client().await;
    send_request(
        &mut socket,
        &format!(
            "GET http://{address}/trailers HTTP/1.1\r\nHost: {address}\r\nTE: trailers\r\n\r\n"
        ),
    )
    .await;
    let head = message(&mut socket).await;
    assert!(head.contains("trailer: x-signature\r\n"), "{head}");
    let body = timeout(
        Duration::from_secs(2),
        read_until_marker(&mut socket, b"0\r\nx-signature: abc\r\n\r\n"),
    )
    .await
    .expect("response trailer forwards");
    assert!(body.starts_with(b"4\r\nbody\r\n"), "{body:?}");
    upstream.await.unwrap();
    drop(socket);
    proxy.stop().await;
}

#[tokio::test]
async fn http_forwarding_preserves_head_representation_length() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        message(&mut socket).await;
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n")
            .await
            .unwrap();
    });
    let proxy = start().await;
    let mut socket = proxy.client().await;
    send_request(
        &mut socket,
        &format!("HEAD http://{address}/metadata HTTP/1.1\r\nHost: {address}\r\n\r\n"),
    )
    .await;
    let response = timeout(
        Duration::from_secs(2),
        read_until_marker(&mut socket, b"\r\n\r\n"),
    )
    .await
    .unwrap();
    let response = String::from_utf8(response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200 "), "{response}");
    assert!(response.contains("content-length: 42\r\n"), "{response}");
    assert!(response.ends_with("\r\n\r\n"), "{response}");
    upstream.await.unwrap();
    drop(socket);
    proxy.stop().await;
}

#[tokio::test]
async fn http_forwarding_reconnects_after_upstream_closes() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let upstream = tokio::spawn(async move {
        for _ in 0..2 {
            let (mut socket, _) = listener.accept().await.unwrap();
            message(&mut socket).await;
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok")
                .await
                .unwrap();
        }
    });
    let proxy = start().await;
    let mut socket = proxy.client().await;
    for _ in 0..2 {
        let response =
            common::request(&mut socket, "GET", &format!("http://{address}/reconnect")).await;
        assert!(response.starts_with("HTTP/1.1 200 "), "{response}");
        assert!(response.ends_with("ok"), "{response}");
    }
    upstream.await.unwrap();
    drop(socket);
    proxy.stop().await;
}
