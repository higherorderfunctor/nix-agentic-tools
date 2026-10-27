//! HTTP messages relayed between a client and an upstream server: the shared
//! response type and the hop-by-hop cleanup each relayed request and response
//! needs.
// cspell:words dechunks
use http_body_util::{Either, Full};
use hyper::{
    HeaderMap, Method, Request, Response, StatusCode, Version,
    body::{Body, Bytes, Incoming},
    header::{
        CONNECTION, CONTENT_LENGTH, COOKIE, HeaderName, HeaderValue, PROXY_AUTHENTICATE,
        PROXY_AUTHORIZATION, TE, TRANSFER_ENCODING, UPGRADE,
    },
};

/// Either an error Airlock wrote itself or the upstream's streamed response.
pub(crate) type ProxyResponse = Response<Either<Full<Bytes>, Incoming>>;

/// Check a client request and clean it for sending upstream as `output`.
pub(crate) fn prepare_request(
    request: &mut Request<Incoming>,
    output: Version,
) -> Result<(), (StatusCode, &'static str)> {
    if !matches!(request.version(), Version::HTTP_11 | Version::HTTP_2) {
        return Err((
            StatusCode::HTTP_VERSION_NOT_SUPPORTED,
            "HTTP/1.1 or HTTP/2 requests are required\n",
        ));
    }
    if !supported_transfer_encoding(request.headers()) {
        return Err((
            StatusCode::BAD_REQUEST,
            "unsupported request transfer coding\n",
        ));
    }
    // Only HTTP/2 bodies of unknown length need new framing for HTTP/1.1.
    let needs_chunked = request.version() == Version::HTTP_2
        && !request.body().is_end_stream()
        && request.body().size_hint().exact().is_none();
    let accepts_trailers = request.headers().get_all(TE).iter().any(|value| {
        value
            .as_bytes()
            .split(|byte| *byte == b',')
            .any(|token| token.trim_ascii().eq_ignore_ascii_case(b"trailers"))
    });
    if !strip_hop_by_hop(request.headers_mut()) {
        return Err((StatusCode::BAD_REQUEST, "malformed Connection header\n"));
    }
    if output == Version::HTTP_2 {
        request.headers_mut().remove(TRANSFER_ENCODING);
    } else if needs_chunked {
        request
            .headers_mut()
            .insert(TRANSFER_ENCODING, HeaderValue::from_static("chunked"));
    }
    if accepts_trailers {
        request
            .headers_mut()
            .insert(TE, HeaderValue::from_static("trailers"));
        if output == Version::HTTP_11 {
            request
                .headers_mut()
                .insert(CONNECTION, HeaderValue::from_static("TE"));
        }
    }
    if request.version() == Version::HTTP_2
        && output == Version::HTTP_11
        && request.headers().get_all(COOKIE).iter().count() > 1
    {
        let cookies = request
            .headers()
            .get_all(COOKIE)
            .iter()
            .map(HeaderValue::as_bytes)
            .collect::<Vec<_>>()
            .join(b"; ".as_slice());
        request.headers_mut().insert(
            COOKIE,
            HeaderValue::from_bytes(&cookies)
                .expect("joining valid Cookie fields preserves header bytes"),
        );
    }
    // Without this, hyper sends an unknown-length HTTP/2 upload to HTTP/1 with length 0.
    *request.version_mut() = output;
    Ok(())
}

pub(crate) fn prepare_response(
    response: &mut Response<Incoming>,
    method: &Method,
) -> Result<(), &'static str> {
    if response.status().is_informational() {
        return Err("upstream informational responses are unsupported\n");
    }
    // Stripping chunked framing while retaining Content-Length would put the client out of sync.
    if !supported_transfer_encoding(response.headers())
        || (response.headers().contains_key(TRANSFER_ENCODING)
            && response.headers().contains_key(CONTENT_LENGTH))
    {
        return Err("unsupported upstream framing\n");
    }
    if !strip_hop_by_hop(response.headers_mut()) {
        return Err("malformed upstream Connection header\n");
    }
    response.headers_mut().remove(TRANSFER_ENCODING);
    // 204 forbids Content-Length; HEAD and 304 lengths describe the representation.
    if method != Method::HEAD
        && !matches!(
            response.status(),
            StatusCode::NO_CONTENT | StatusCode::NOT_MODIFIED
        )
        && let Some(length) = response.body().size_hint().exact()
    {
        response.headers_mut().insert(CONTENT_LENGTH, length.into());
    }
    Ok(())
}

fn supported_transfer_encoding(headers: &HeaderMap<HeaderValue>) -> bool {
    let mut values = headers.get_all(TRANSFER_ENCODING).iter();
    match values.next() {
        None => true,
        Some(value) => {
            // Hyper only dechunks: accepting another coding would lose its
            // metadata when the hop-by-hop headers are stripped.
            value
                .as_bytes()
                .trim_ascii()
                .eq_ignore_ascii_case(b"chunked")
                && values.next().is_none()
        }
    }
}

fn strip_hop_by_hop(headers: &mut HeaderMap<HeaderValue>) -> bool {
    let mut connection_named = Vec::new();
    for value in headers.get_all(CONNECTION) {
        for token in value.as_bytes().split(|byte| *byte == b',') {
            let token = token.trim_ascii();
            if token.is_empty() {
                continue;
            }
            let Ok(name) = HeaderName::from_bytes(token) else {
                return false;
            };
            connection_named.push(name);
        }
    }

    headers.remove(CONNECTION);
    for name in connection_named {
        // Keep validated chunked framing for HTTP/1 requests, including GET/HEAD.
        if name != TRANSFER_ENCODING {
            headers.remove(name);
        }
    }

    for name in [
        HeaderName::from_static("keep-alive"),
        HeaderName::from_static("proxy-connection"),
        PROXY_AUTHENTICATE,
        PROXY_AUTHORIZATION,
        TE,
        UPGRADE,
    ] {
        headers.remove(name);
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use hyper_util::rt::TokioIo;
    use tokio::io::AsyncWriteExt;

    #[tokio::test]
    async fn empty_statuses_do_not_regenerate_content_length() {
        for (head, expected) in [
            ("HTTP/1.1 204 No Content\r\n\r\n", None),
            (
                "HTTP/1.1 304 Not Modified\r\nContent-Length: 42\r\n\r\n",
                Some("42"),
            ),
        ] {
            let (client, mut server) = tokio::io::duplex(1024);
            let (mut sender, connection) =
                hyper::client::conn::http1::handshake::<_, Full<Bytes>>(TokioIo::new(client))
                    .await
                    .unwrap();
            let driver = tokio::spawn(connection);
            let upstream = tokio::spawn(async move {
                use tokio::io::AsyncReadExt;
                let mut request = [0; 1024];
                assert!(server.read(&mut request).await.unwrap() > 0);
                server.write_all(head.as_bytes()).await.unwrap();
            });
            let mut response = sender
                .send_request(
                    Request::builder()
                        .uri("/")
                        .body(Full::new(Bytes::new()))
                        .unwrap(),
                )
                .await
                .unwrap();
            prepare_response(&mut response, &Method::GET).unwrap();
            assert_eq!(
                response
                    .headers()
                    .get(CONTENT_LENGTH)
                    .map(|value| value.to_str().unwrap()),
                expected
            );
            upstream.await.unwrap();
            driver.abort();
        }
    }
}
