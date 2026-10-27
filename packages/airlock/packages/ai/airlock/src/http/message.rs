//! HTTP messages relayed between a client and an upstream server: the shared
//! response type and the hop-by-hop cleanup each relayed request and response
//! needs.
// cspell:words dechunks
use http_body_util::{Either, Full};
use hyper::{
    HeaderMap, Request, Response, StatusCode, Version,
    body::{Bytes, Incoming},
    header::{
        CONNECTION, CONTENT_LENGTH, HeaderName, HeaderValue, PROXY_AUTHENTICATE,
        PROXY_AUTHORIZATION, TE, TRAILER, TRANSFER_ENCODING, UPGRADE,
    },
};

/// Either an error Airlock wrote itself or the upstream's streamed response.
pub(crate) type ProxyResponse = Response<Either<Full<Bytes>, Incoming>>;

pub(crate) fn prepare_request(
    request: &mut Request<Incoming>,
) -> Result<(), (StatusCode, &'static str)> {
    if request.version() != Version::HTTP_11 {
        return Err((
            StatusCode::HTTP_VERSION_NOT_SUPPORTED,
            "HTTP/1.1 requests are required\n",
        ));
    }
    if !supported_transfer_encoding(request.headers()) {
        return Err((
            StatusCode::BAD_REQUEST,
            "unsupported request transfer coding\n",
        ));
    }
    let chunked = request.headers().contains_key(TRANSFER_ENCODING);
    if !strip_hop_by_hop(request.headers_mut()) {
        return Err((StatusCode::BAD_REQUEST, "malformed Connection header\n"));
    }
    // Incoming has decoded chunks; unknown-length GET/HEAD need explicit framing.
    if chunked {
        request
            .headers_mut()
            .insert(TRANSFER_ENCODING, HeaderValue::from_static("chunked"));
    }
    Ok(())
}

pub(crate) fn prepare_response(response: &mut Response<Incoming>) -> Result<(), &'static str> {
    if !supported_transfer_encoding(response.headers())
        || (response.headers().contains_key(TRANSFER_ENCODING)
            && response.headers().contains_key(CONTENT_LENGTH))
    {
        return Err("unsupported upstream framing\n");
    }
    if !strip_hop_by_hop(response.headers_mut()) {
        return Err("malformed upstream Connection header\n");
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
        headers.remove(name);
    }

    for name in [
        HeaderName::from_static("keep-alive"),
        HeaderName::from_static("proxy-connection"),
        PROXY_AUTHENTICATE,
        PROXY_AUTHORIZATION,
        TE,
        TRAILER,
        TRANSFER_ENCODING,
        UPGRADE,
    ] {
        headers.remove(name);
    }
    true
}
