//! HTTP messages relayed between a client and an upstream server: the shared
//! response type and the hop-by-hop cleanup each relayed request and response
//! needs.
// cspell:words dechunks
use http_body_util::{Either, Full};
use hyper::{
    HeaderMap, Method, Request, Response, StatusCode, Version,
    body::{Body, Bytes, Incoming},
    header::{
        CONNECTION, CONTENT_LENGTH, HeaderName, HeaderValue, PROXY_AUTHENTICATE,
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
    if request.headers().contains_key(UPGRADE) {
        return Err((StatusCode::BAD_REQUEST, "HTTP upgrades are unsupported\n"));
    }
    // Only HTTP/2 bodies of unknown length need new framing for HTTP/1.1.
    let needs_chunked = request.version() == Version::HTTP_2
        && !request.body().is_end_stream()
        && request.body().size_hint().exact().is_none();
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
    // HEAD and 304 lengths describe the representation, not this empty body.
    if method != Method::HEAD
        && response.status() != StatusCode::NOT_MODIFIED
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
