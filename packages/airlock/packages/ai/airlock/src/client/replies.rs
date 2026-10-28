//! Replies Airlock writes itself rather than relaying: the health route and
//! short plain-text status responses.
use http_body_util::Full;
use hyper::{
    Method, Response, StatusCode, Uri,
    body::Bytes,
    header::{ALLOW, CONTENT_TYPE, HeaderValue},
};

/// The status and body for a request addressed to Airlock itself.
pub(crate) fn route(method: &Method, uri: &Uri) -> (StatusCode, &'static str) {
    if uri.path() != "/health" {
        (StatusCode::NOT_FOUND, "not found\n")
    } else if method != Method::GET {
        (StatusCode::METHOD_NOT_ALLOWED, "GET required\n")
    } else {
        (StatusCode::OK, "ok\n")
    }
}

pub(crate) fn response(status: StatusCode, body: &'static str) -> Response<Full<Bytes>> {
    let mut response = Response::new(Full::new(Bytes::from_static(body.as_bytes())));
    *response.status_mut() = status;
    if !body.is_empty() {
        response.headers_mut().insert(
            CONTENT_TYPE,
            HeaderValue::from_static("text/plain; charset=utf-8"),
        );
    }
    if status == StatusCode::METHOD_NOT_ALLOWED {
        response
            .headers_mut()
            .insert(ALLOW, HeaderValue::from_static("GET"));
    }
    response
}
