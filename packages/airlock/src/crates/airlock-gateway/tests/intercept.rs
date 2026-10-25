//! HTTP interception: airlock's leaf to the client, verified TLS upstream, swapped auth.

mod support;

use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    sync::{Arc, atomic::Ordering},
    time::Duration,
};

use airlock_gateway::{CaError, Error, Gateway};
use http_body_util::BodyExt;
use hyper::header::HeaderName;
use hyper::{
    body::Frame,
    header::{
        AUTHORIZATION, CONNECTION, PROXY_AUTHENTICATE, PROXY_AUTHORIZATION, TE, TRAILER, UPGRADE,
    },
};
use support::{
    FixtureAuth, HttpClient, HttpProtocol, REAL_API_KEY, REAL_OAUTH_TOKEN, Running, StallGates,
    TOKEN, TestCa, UpgradeBytes, UpstreamMode, config, fields, fnv1a_test, full_body,
    http_upstream, records, request, sink, streaming_body, tls_upstream, wait_for_request,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    time::timeout,
};
use x509_parser::{extensions::GeneralName, prelude::FromDer};

const LARGE_BODY: usize = 64 << 20;

#[tokio::test]
async fn http1_swaps_oauth_and_removes_client_auth() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_with_port(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;

    let response = client
        .send(request(
            "POST",
            "/v1/messages?client=fake-CLIENT-query",
            &[
                (AUTHORIZATION, "Bearer fake-CLIENT-oauth"),
                (HeaderName::from_static("x-api-key"), "fake-CLIENT-api-key"),
                (HeaderName::from_static("anthropic-beta"), "test"),
            ],
            full_body(br#"{"model":"claude-sonnet-5","messages":[]}"#),
        ))
        .await;

    assert_eq!(response.status(), hyper::StatusCode::OK);
    let body = response
        .into_body()
        .collect()
        .await
        .expect("body")
        .to_bytes();
    assert_eq!(&body[..], br#"{"model":"claude-sonnet-5","messages":[]}"#);
    let received = records(&upstream);
    assert_eq!(received.len(), 1);
    assert_eq!(received[0].path, "/v1/messages");
    assert_eq!(
        received[0].headers[AUTHORIZATION],
        format!("Bearer {REAL_OAUTH_TOKEN}")
    );
    assert!(received[0].headers.get("x-api-key").is_none());
    assert_eq!(received[0].headers["anthropic-beta"], "test");
    assert_eq!(
        &received[0].body[..],
        br#"{"model":"claude-sonnet-5","messages":[]}"#
    );
    let request_events = server.capture.request_events();
    assert_eq!(request_events[0]["fields"]["path"], "/v1/messages");
    assert_eq!(request_events[0]["fields"]["credential"], "claude");
    assert_eq!(request_events[0]["fields"]["model"], "claude-sonnet-5");
    let events = server.stop().await;
    assert_eq!(events.len(), 1);
    let audit = fields(&events[0]);
    assert_eq!(audit["requests"], 1);
    assert!(audit["client_to_upstream"].as_u64().expect("upload bytes") > 0);
    assert!(
        audit["upstream_to_client"]
            .as_u64()
            .expect("download bytes")
            > 0
    );
}

#[tokio::test]
async fn one_http1_connect_routes_each_model_and_keeps_feature_paths_primary() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let zai = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;

    for (path, body) in [
        (
            "/v1/messages",
            br#"{"model":"claude-sonnet-5","messages":[]}"#.as_slice(),
        ),
        (
            "/v1/messages",
            br#"{"messages":[],"model":"glm-4.7"}"#.as_slice(),
        ),
        ("/api/oauth/usage", b"".as_slice()),
        (
            "/v1/messages",
            br#"{"model":"new-claude-model","messages":[]}"#.as_slice(),
        ),
    ] {
        let response = client
            .send(request(
                "POST",
                path,
                &[
                    (AUTHORIZATION, "Bearer fake-CLIENT-oauth"),
                    (HeaderName::from_static("x-api-key"), "fake-CLIENT-api-key"),
                    (HeaderName::from_static("accept-encoding"), "gzip"),
                    (HeaderName::from_static("cookie"), "fake-CLIENT-session"),
                ],
                full_body(body),
            ))
            .await;
        assert_eq!(response.status(), hyper::StatusCode::OK);
        assert_eq!(
            &response
                .into_body()
                .collect()
                .await
                .expect("body")
                .to_bytes()[..],
            body
        );
    }
    let primary_requests = records(&primary);
    let zai_requests = records(&zai);
    assert_eq!(primary_requests.len(), 3);
    assert_eq!(zai_requests.len(), 1);
    assert_eq!(zai_requests[0].path, "/api/anthropic/v1/messages");
    assert_eq!(
        std::str::from_utf8(&zai_requests[0].body).expect("UTF-8"),
        r#"{"messages":[],"model":"glm-4.7"}"#
    );
    assert_eq!(zai_requests[0].headers["x-api-key"], "fake-REAL-zai");
    assert_eq!(zai_requests[0].headers["accept-encoding"], "gzip");
    assert!(zai_requests[0].headers.get(AUTHORIZATION).is_none());
    assert!(zai_requests[0].headers.get("cookie").is_none());
    assert!(
        primary_requests
            .iter()
            .all(|record| record.headers[AUTHORIZATION] == format!("Bearer {REAL_OAUTH_TOKEN}"))
    );
    let events = server.capture.request_events();
    assert_eq!(
        events
            .iter()
            .map(|event| event["fields"]["credential"].as_str().expect("credential"))
            .collect::<Vec<_>>(),
        ["claude", "zai", "claude", "claude"]
    );
    server.stop().await;
}

fn quota_mode(
    status: hyper::StatusCode,
    headers: &[(&'static str, &'static str)],
    body: &'static [u8],
) -> UpstreamMode {
    UpstreamMode::Quota(Arc::new(support::QuotaFixture {
        body,
        headers: headers.to_vec(),
        release_body: None,
        status,
    }))
}

#[tokio::test]
async fn primary_quota_headers_replace_zai_identity_and_stream_usage_stays_honest() {
    const PRIMARY_BODY: &[u8] = br#"{"usage":{"output_tokens":3}}"#;
    const ZAI_BODY: &[u8] =
        b"event: message\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\n";
    let ca = TestCa::new();
    let primary = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(
            hyper::StatusCode::OK,
            &[
                ("anthropic-ratelimit-unified-5h-utilization", "0.42"),
                ("anthropic-ratelimit-unified-status", "allowed"),
                ("x-primary-ordinary", "kept"),
            ],
            PRIMARY_BODY,
        ),
    )
    .await;
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(
            hyper::StatusCode::OK,
            &[
                ("anthropic-ratelimit-unified-5h-utilization", "0.9"),
                ("anthropic-ratelimit-unified-status", "rejected"),
                ("x-zai-ordinary", "kept"),
            ],
            ZAI_BODY,
        ),
    )
    .await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;

    let primary_response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"claude-sonnet-5","messages":[]}"#),
        ))
        .await;
    assert_eq!(primary_response.status(), hyper::StatusCode::OK);
    assert_eq!(
        primary_response.headers()["anthropic-ratelimit-unified-status"],
        "allowed"
    );
    assert_eq!(primary_response.headers()["x-primary-ordinary"], "kept");
    assert_eq!(
        &primary_response
            .into_body()
            .collect()
            .await
            .expect("primary body")
            .to_bytes()[..],
        PRIMARY_BODY
    );

    let zai_response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7","stream":true}"#),
        ))
        .await;
    assert_eq!(zai_response.status(), hyper::StatusCode::OK);
    assert_eq!(
        zai_response.headers()["anthropic-ratelimit-unified-5h-utilization"],
        "0.42"
    );
    assert_eq!(
        zai_response.headers()["anthropic-ratelimit-unified-status"],
        "allowed"
    );
    assert_eq!(zai_response.headers()["x-zai-ordinary"], "kept");
    assert!(zai_response.headers().get("retry-after").is_none());
    let zai_usage = zai_response
        .into_body()
        .collect()
        .await
        .expect("z.ai stream")
        .to_bytes();
    assert!(
        std::str::from_utf8(&zai_usage)
            .expect("UTF-8 stream")
            .contains(r#""output_tokens":7"#)
    );
    server.stop().await;
}

#[tokio::test]
async fn substituted_quota_headers_arrive_before_zai_body_completes() {
    let ca = TestCa::new();
    let primary = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(
            hyper::StatusCode::OK,
            &[("anthropic-ratelimit-unified-status", "allowed")],
            b"primary",
        ),
    )
    .await;
    let release_body = Arc::new(tokio::sync::Notify::new());
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::Quota(Arc::new(support::QuotaFixture {
            body: b"zai body",
            headers: vec![("anthropic-ratelimit-unified-status", "rejected")],
            release_body: Some(release_body.clone()),
            status: hyper::StatusCode::OK,
        })),
    )
    .await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let primary_response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"claude-sonnet-5"}"#),
        ))
        .await;
    primary_response
        .into_body()
        .collect()
        .await
        .expect("primary body");

    let response = timeout(
        Duration::from_secs(2),
        client.send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7"}"#),
        )),
    )
    .await
    .expect("headers before gated body");
    assert_eq!(
        response.headers()["anthropic-ratelimit-unified-status"],
        "allowed"
    );
    release_body.notify_one();
    assert_eq!(
        &response
            .into_body()
            .collect()
            .await
            .expect("released body")
            .to_bytes()[..],
        b"zai body"
    );
    server.stop().await;
}

#[tokio::test]
async fn cold_cache_omits_zai_quota_identity_without_changing_response() {
    const BODY: &[u8] = br#"{"usage":{"output_tokens":7}}"#;
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(
            hyper::StatusCode::OK,
            &[
                ("anthropic-ratelimit-unified-status", "rejected"),
                ("retry-after", "9"),
                ("x-zai-ordinary", "kept"),
            ],
            BODY,
        ),
    )
    .await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7"}"#),
        ))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::OK);
    assert!(
        response
            .headers()
            .keys()
            .all(|name| !name.as_str().starts_with("anthropic-ratelimit-"))
    );
    assert_eq!(response.headers()["retry-after"], "9");
    assert_eq!(response.headers()["x-zai-ordinary"], "kept");
    assert_eq!(
        &response
            .into_body()
            .collect()
            .await
            .expect("z.ai body")
            .to_bytes()[..],
        BODY
    );
    server.stop().await;
}

#[tokio::test]
async fn zai_429_keeps_its_retry_and_quota_headers() {
    const ZAI_BODY: &[u8] = br#"{"type":"error","error":{"type":"rate_limit_error"}}"#;
    let ca = TestCa::new();
    let primary = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(
            hyper::StatusCode::OK,
            &[("anthropic-ratelimit-unified-status", "allowed")],
            br#"{"usage":{"output_tokens":3}}"#,
        ),
    )
    .await;
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(
            hyper::StatusCode::TOO_MANY_REQUESTS,
            &[
                ("anthropic-ratelimit-unified-status", "rejected"),
                ("retry-after", "9"),
                ("x-zai-ordinary", "kept"),
            ],
            ZAI_BODY,
        ),
    )
    .await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let primary_response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"claude-sonnet-5"}"#),
        ))
        .await;
    assert_eq!(primary_response.status(), hyper::StatusCode::OK);
    let _ = primary_response
        .into_body()
        .collect()
        .await
        .expect("primary body");

    let response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7"}"#),
        ))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        response.headers()["anthropic-ratelimit-unified-status"],
        "rejected"
    );
    assert_eq!(response.headers()["retry-after"], "9");
    assert_eq!(response.headers()["x-zai-ordinary"], "kept");
    assert_eq!(
        &response
            .into_body()
            .collect()
            .await
            .expect("z.ai error body")
            .to_bytes()[..],
        ZAI_BODY
    );
    server.stop().await;
}

#[tokio::test]
async fn primary_429_retry_after_does_not_leak_into_later_zai_success() {
    let ca = TestCa::new();
    let primary = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(
            hyper::StatusCode::TOO_MANY_REQUESTS,
            &[
                ("anthropic-ratelimit-unified-status", "limited"),
                ("retry-after", "30"),
            ],
            b"primary limited",
        ),
    )
    .await;
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(
            hyper::StatusCode::OK,
            &[("anthropic-ratelimit-unified-status", "allowed")],
            b"zai success",
        ),
    )
    .await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let primary_response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"claude-sonnet-5"}"#),
        ))
        .await;
    assert_eq!(
        primary_response.status(),
        hyper::StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(primary_response.headers()["retry-after"], "30");
    primary_response
        .into_body()
        .collect()
        .await
        .expect("primary body");

    let zai_response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7"}"#),
        ))
        .await;
    assert_eq!(zai_response.status(), hyper::StatusCode::OK);
    assert_eq!(
        zai_response.headers()["anthropic-ratelimit-unified-status"],
        "limited"
    );
    assert!(zai_response.headers().get("retry-after").is_none());
    zai_response.into_body().collect().await.expect("z.ai body");
    server.stop().await;
}

#[tokio::test]
async fn model_list_pagination_and_errors_stay_on_primary() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Models).await;
    let zai = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;

    let expected = [
        (
            "/v1/models?limit=1",
            br#"{"data":[{"id":"claude-a"}],"first_id":null,"has_more":true,"last_id":"claude-a"}"#.as_slice(),
        ),
        (
            "/v1/models?after=claude-a&limit=1",
            br#"{"data":[{"id":"claude-b"}],"first_id":"claude-a","has_more":false,"last_id":"claude-b"}"#.as_slice(),
        ),
    ];
    for (target, body) in expected {
        let response = client
            .send(request("GET", target, &[], full_body(b"")))
            .await;
        assert_eq!(response.status(), hyper::StatusCode::OK);
        assert_eq!(response.headers()["anthropic-version"], "fake-pagination");
        assert_eq!(
            &response
                .into_body()
                .collect()
                .await
                .expect("model-list body")
                .to_bytes()[..],
            body
        );
    }
    let error = client
        .send(request("GET", "/v1/models?fail=1", &[], full_body(b"")))
        .await;
    assert_eq!(
        error.status(),
        hyper::StatusCode::from_u16(529).expect("status")
    );
    assert_eq!(
        &error
            .into_body()
            .collect()
            .await
            .expect("model-list error")
            .to_bytes()[..],
        br#"{"type":"error","error":{"type":"overloaded_error","message":"fake upstream busy"}}"#
    );

    let received = records(&primary);
    assert_eq!(received.len(), 3);
    assert!(received.iter().all(|record| record.method == "GET"));
    assert_eq!(
        received
            .iter()
            .map(|record| format!(
                "{}?{}",
                record.path,
                record.query.as_deref().unwrap_or_default()
            ))
            .collect::<Vec<_>>(),
        [
            "/v1/models?limit=1",
            "/v1/models?after=claude-a&limit=1",
            "/v1/models?fail=1"
        ]
    );
    assert!(
        received
            .iter()
            .all(|record| record.headers[AUTHORIZATION] == format!("Bearer {REAL_OAUTH_TOKEN}"))
    );
    assert!(records(&zai).is_empty());
    server.stop().await;
}

#[tokio::test]
async fn toolsearch_request_and_json_response_are_scoped_to_zai() {
    const BODY: &[u8] = br#"{"model":"glm-4.7","tools":[{"name":"ToolSearch"},{"name":"lookup"}],"tool_choice":{"type":"tool","name":"ToolSearch"},"messages":[{"content":[{"type":"tool_use","name":"ToolSearch","input":{"text":"ToolSearch"}},{"type":"tool_reference","tool_name":"ToolSearch"},{"type":"tool_result","content":[{"type":"tool_reference","tool_name":"ToolSearch"}]}]}]}"#;
    const RESPONSE: &[u8] = br#"{"content":[{"type":"tool_use","name":"ToolSearch_","input":{"text":"ToolSearch_"}},{"type":"text","text":"ToolSearch_"}],"usage":{"output_tokens":5}}"#;
    let ca = TestCa::new();
    let primary = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::Fixed {
            body: RESPONSE,
            content_type: "application/json",
            encoding: None,
        },
    )
    .await;
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::Fixed {
            body: RESPONSE,
            content_type: "application/json",
            encoding: None,
        },
    )
    .await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let zai_response = client
        .send(request("POST", "/v1/messages", &[], full_body(BODY)))
        .await;
    assert_eq!(zai_response.status(), hyper::StatusCode::OK);
    assert!(zai_response.headers().get("content-length").is_none());
    let zai_body = zai_response
        .into_body()
        .collect()
        .await
        .expect("z.ai body")
        .to_bytes();
    assert_eq!(
        &zai_body[..],
        br#"{"content":[{"type":"tool_use","name":"ToolSearch","input":{"text":"ToolSearch_"}},{"type":"text","text":"ToolSearch_"}],"usage":{"output_tokens":5}}"#
    );
    let sent = records(&zai);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].headers["accept-encoding"], "identity");
    let sent_body = std::str::from_utf8(&sent[0].body).expect("UTF-8");
    assert!(sent_body.contains(r#""name":"ToolSearch_""#));
    assert!(sent_body.contains(r#""tool_name":"ToolSearch_""#));
    assert!(sent_body.contains(r#""text":"ToolSearch""#));

    let primary_response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"claude-sonnet-5","tools":[{"name":"ToolSearch"}]}"#),
        ))
        .await;
    assert_eq!(
        &primary_response
            .into_body()
            .collect()
            .await
            .expect("primary body")
            .to_bytes()[..],
        RESPONSE
    );
    assert_eq!(
        &records(&primary)[0].body[..],
        br#"{"model":"claude-sonnet-5","tools":[{"name":"ToolSearch"}]}"#
    );
    server.stop().await;
}

#[tokio::test]
async fn toolsearch_collision_and_compression_fail_explicitly() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::Fixed {
            body: b"fake-compressed",
            content_type: "application/json",
            encoding: Some("gzip"),
        },
    )
    .await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let rejected = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7","tools":[{"name":"ToolSearch_"}]}"#),
        ))
        .await;
    assert_eq!(rejected.status(), hyper::StatusCode::BAD_REQUEST);
    assert!(records(&zai).is_empty());
    let compressed = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7","tools":[{"name":"ToolSearch"}]}"#),
        ))
        .await;
    assert_eq!(compressed.status(), hyper::StatusCode::BAD_GATEWAY);
    assert_eq!(
        &compressed
            .into_body()
            .collect()
            .await
            .expect("diagnostic")
            .to_bytes()[..],
        b"toolsearch_compressed_response"
    );
    assert_eq!(records(&zai).len(), 1);
    server.stop().await;
}

#[tokio::test]
async fn toolsearch_response_limits_fail_the_body() {
    for (content_type, size, succeeds) in [
        ("application/json", 32 << 20, true),
        ("application/json", (32 << 20) + 1, false),
        ("text/event-stream", (1 << 20) + 1, false),
    ] {
        let ca = TestCa::new();
        let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
        let bytes = if content_type == "application/json" {
            let mut json = br#"{"pad":""#.to_vec();
            json.resize(size - br#""}"#.len(), b'x');
            json.extend_from_slice(br#""}"#);
            assert_eq!(json.len(), size);
            serde_json::from_slice::<serde_json::Value>(&json).expect("valid JSON fixture");
            json
        } else {
            vec![b'x'; size]
        };
        let body: &'static [u8] = Box::leak(bytes.into_boxed_slice());
        let zai = http_upstream(
            &ca,
            HttpProtocol::Http1,
            UpstreamMode::Fixed {
                body,
                content_type,
                encoding: None,
            },
        )
        .await;
        let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
        let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
        let response = client
            .send(request(
                "POST",
                "/v1/messages",
                &[],
                full_body(br#"{"model":"glm-4.7","tools":[{"name":"ToolSearch"}]}"#),
            ))
            .await;
        assert_eq!(response.status(), hyper::StatusCode::OK);
        let result = response.into_body().collect().await;
        if succeeds {
            assert_eq!(&result.expect("at-limit JSON body").to_bytes()[..], body);
        } else {
            assert!(result.is_err(), "{content_type} size {size}");
        }
        server.stop().await;
    }
}

#[tokio::test]
async fn toolsearch_sse_flushes_first_event_and_keeps_usage() {
    for (content_type, cr_only) in [
        ("text/event-stream", false),
        ("Text/Event-Stream; charset=utf-8", false),
        ("text/event-stream", true),
    ] {
        let release = Arc::new(tokio::sync::Notify::new());
        let ca = TestCa::new();
        let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
        let zai = http_upstream(
            &ca,
            HttpProtocol::Http1,
            UpstreamMode::ToolSearchSse {
                release: release.clone(),
                content_type,
                cr_only,
            },
        )
        .await;
        let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
        let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
        let mut response = client
            .send(request(
                "POST",
                "/v1/messages",
                &[],
                full_body(br#"{"model":"glm-4.7","tools":[{"name":"ToolSearch"}],"stream":true}"#),
            ))
            .await;
        assert_eq!(response.status(), hyper::StatusCode::OK);
        let first = timeout(Duration::from_secs(2), response.body_mut().frame())
            .await
            .expect("first event before release")
            .expect("first event")
            .expect("first frame")
            .into_data()
            .expect("data");
        assert!(
            std::str::from_utf8(&first)
                .expect("UTF-8")
                .contains(r#""name":"ToolSearch""#)
        );
        assert!(first.ends_with(if cr_only { b"\r\r" } else { b"\r\n\r" }));
        let usage = timeout(Duration::from_secs(2), response.body_mut().frame())
            .await
            .expect("usage event before release")
            .expect("usage event")
            .expect("usage frame")
            .into_data()
            .expect("data");
        assert!(
            usage
                .windows(b"\"output_tokens\":7".len())
                .any(|window| window == b"\"output_tokens\":7")
        );
        release.notify_one();
        let done = response
            .into_body()
            .collect()
            .await
            .expect("done")
            .to_bytes();
        assert_eq!(&done[..], b"event: done\ndata: [DONE]\n\n");
        server.stop().await;
    }
}

#[tokio::test]
async fn cancelling_toolsearch_sse_closes_selected_upstream() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Echo).await;
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http2,
        UpstreamMode::ToolSearchSse {
            release: Arc::new(tokio::sync::Notify::new()),
            content_type: "text/event-stream",
            cr_only: false,
        },
    )
    .await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http2).await;
    let mut response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7","tools":[{"name":"ToolSearch"}],"stream":true}"#),
        ))
        .await;
    let first = timeout(Duration::from_secs(2), response.body_mut().frame())
        .await
        .expect("first event deadline")
        .expect("first event")
        .expect("first frame")
        .into_data()
        .expect("data");
    assert!(
        std::str::from_utf8(&first)
            .expect("UTF-8")
            .contains(r#""name":"ToolSearch""#)
    );
    drop(response);
    timeout(Duration::from_secs(2), zai.done)
        .await
        .expect("selected upstream closed")
        .expect("task")
        .expect("upstream service");
    assert!(records(&primary).is_empty());
    let primary_response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"claude-sonnet-5","messages":[]}"#),
        ))
        .await;
    assert_eq!(primary_response.status(), hyper::StatusCode::OK);
    assert_eq!(records(&primary).len(), 1);
    server.stop().await;
}

#[tokio::test]
async fn absent_model_and_token_path_keep_original_host_while_explicit_model_uses_endpoint() {
    let ca = TestCa::new();
    let original = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let primary_endpoint = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let zai = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_multiplex_with_primary(
        ca.roots(),
        zai.port,
        &format!("https://localhost:{}", primary_endpoint.port),
    )
    .await;
    let mut client = HttpClient::connect(&server, original.port, HttpProtocol::Http1).await;
    for body in [
        br#"{"messages":[]}"#.as_slice(),
        br#"{"model":"new-claude-model"}"#.as_slice(),
    ] {
        let response = client
            .send(request("POST", "/v1/messages", &[], full_body(body)))
            .await;
        assert_eq!(response.status(), hyper::StatusCode::OK);
        assert_eq!(
            &response
                .into_body()
                .collect()
                .await
                .expect("body")
                .to_bytes()[..],
            body
        );
    }
    let token_body = b"fake-CLIENT-token-request";
    let response = client
        .send(request(
            "POST",
            "/api/oauth/token",
            &[],
            full_body(token_body),
        ))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::OK);
    assert_eq!(
        &response
            .into_body()
            .collect()
            .await
            .expect("token response")
            .to_bytes()[..],
        token_body
    );
    let original_requests = records(&original);
    assert_eq!(original_requests.len(), 2);
    assert_eq!(original_requests[1].path, "/api/oauth/token");
    assert_eq!(original_requests[1].body.as_ref(), token_body);
    assert_eq!(
        original_requests[1].headers[AUTHORIZATION],
        format!("Bearer {REAL_OAUTH_TOKEN}")
    );
    assert_eq!(records(&primary_endpoint).len(), 1);
    assert!(records(&zai).is_empty());
    server.stop().await;
}

#[tokio::test]
async fn selected_upstream_failure_does_not_fall_back_to_primary() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let closed = sink().await;
    let zai_port = closed.local_addr().expect("closed port").port();
    drop(closed);
    let server = Running::start_multiplex(ca.roots(), primary.port, zai_port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7"}"#),
        ))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::BAD_GATEWAY);
    assert!(records(&primary).is_empty());
    server.stop().await;
}

#[tokio::test]
async fn cancelling_selected_stream_closes_its_upstream_connection() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Echo).await;
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http2,
        UpstreamMode::Sse(Arc::new(tokio::sync::Notify::new())),
    )
    .await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http2).await;
    let mut response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7"}"#),
        ))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::OK);
    let first = response
        .body_mut()
        .frame()
        .await
        .expect("first event")
        .expect("frame")
        .into_data()
        .expect("data");
    assert_eq!(&first[..], b"event:first\n\n");
    drop(response);
    drop(client);
    timeout(Duration::from_secs(2), zai.done)
        .await
        .expect("selected upstream closed")
        .expect("task")
        .expect("upstream service");
    assert!(records(&primary).is_empty());
    server.stop().await;
}

#[tokio::test]
async fn nested_and_malformed_models_cannot_select_zai() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let zai = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    for (body, status) in [
        (br#"["glm-4.7"]"#.as_slice(), hyper::StatusCode::BAD_REQUEST),
        (
            br#"{"messages":[{"model":"glm-4.7"}]}"#.as_slice(),
            hyper::StatusCode::OK,
        ),
        (br#"{"model":null}"#.as_slice(), hyper::StatusCode::OK),
        (
            br#"{"model":"glm-4.7",}"#.as_slice(),
            hyper::StatusCode::BAD_REQUEST,
        ),
        (
            br#"{"model":"glm-4.7","model":"claude-sonnet-5"}"#.as_slice(),
            hyper::StatusCode::BAD_REQUEST,
        ),
        (
            br#"{"model":{"value":"glm-4.7"}}"#.as_slice(),
            hyper::StatusCode::BAD_REQUEST,
        ),
        (
            br#"{"model":"glm@4.7"}"#.as_slice(),
            hyper::StatusCode::BAD_REQUEST,
        ),
    ] {
        let response = client
            .send(request("POST", "/v1/messages", &[], full_body(body)))
            .await;
        assert_eq!(
            response.status(),
            status,
            "{}",
            String::from_utf8_lossy(body)
        );
        let _ = response.into_body().collect().await.expect("response");
    }
    assert_eq!(records(&primary).len(), 2);
    assert!(records(&zai).is_empty());
    let oversized = format!(r#"{{"model":"{}"}}"#, "x".repeat(1 << 20));
    let (sender, body) = streaming_body(1);
    sender
        .try_send(Ok(Frame::data(hyper::body::Bytes::from(oversized))))
        .expect("queue oversized model");
    drop(sender);
    let response = client
        .send(request("POST", "/v1/messages", &[], body))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::BAD_REQUEST);
    assert_eq!(records(&primary).len(), 2);
    assert!(records(&zai).is_empty());
    server.stop().await;
}

#[tokio::test]
async fn inference_body_over_32_mib_returns_413_without_upstream_request() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let zai = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let (sender, body) = streaming_body(1);
    sender
        .try_send(Ok(Frame::data(hyper::body::Bytes::from(vec![
            b'x';
            (32 << 20)
                + 1
        ]))))
        .expect("queue oversized body");
    drop(sender);

    let response = client
        .send(request("POST", "/v1/messages", &[], body))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::PAYLOAD_TOO_LARGE);
    let response_body = response.into_body().collect().await.expect("response body");
    assert_eq!(&response_body.to_bytes()[..], b"request_too_large");
    assert!(records(&primary).is_empty());
    assert!(records(&zai).is_empty());
    let request_events = server.capture.request_events();
    assert_eq!(request_events[0]["fields"]["status"], 413);
    assert_eq!(request_events[0]["fields"]["outcome"], "request_too_large");
    server.stop().await;
}

#[tokio::test]
async fn inference_with_trailers_returns_400_without_upstream_request() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Echo).await;
    let zai = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Echo).await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http2).await;
    let (sender, body) = streaming_body(2);
    sender
        .try_send(Ok(Frame::data(hyper::body::Bytes::from_static(
            br#"{"model":"glm-4.7"}"#,
        ))))
        .expect("queue inference body");
    let mut trailers = hyper::HeaderMap::new();
    trailers.insert("x-test", "checksum".parse().expect("trailer value"));
    sender
        .try_send(Ok(Frame::trailers(trailers)))
        .expect("queue trailers");
    drop(sender);

    let response = client
        .send(request("POST", "/v1/messages", &[], body))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::BAD_REQUEST);
    let response_body = response.into_body().collect().await.expect("response body");
    assert_eq!(
        &response_body.to_bytes()[..],
        b"request_trailers_unsupported"
    );
    assert!(records(&primary).is_empty());
    assert!(records(&zai).is_empty());
    let request_events = server.capture.request_events();
    assert_eq!(request_events[0]["fields"]["status"], 400);
    assert_eq!(
        request_events[0]["fields"]["outcome"],
        "request_trailers_unsupported"
    );
    server.stop().await;
}

#[tokio::test]
async fn exact_limit_in_uneven_frames_reaches_selected_upstream() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::HashUpload).await;
    let zai = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::HashUpload).await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let mut bytes = br#"{"model":"glm-4.7","pad":""#.to_vec();
    bytes.resize(32 << 20, b'x');
    let last = bytes.len();
    bytes[last - 2..].copy_from_slice(b"\"}");
    let expected_hash = fnv1a_test(support::FNV_OFFSET, &bytes);
    let body_bytes = hyper::body::Bytes::from(bytes);
    let (sender, body) = streaming_body(1);
    tokio::spawn(async move {
        let mut start = 0;
        for end in [1003, 1_000_003, 2_000_003, 4_000_003, body_bytes.len()] {
            sender
                .send(Ok(Frame::data(body_bytes.slice(start..end))))
                .await
                .expect("send uneven frame");
            start = end;
        }
    });

    let response = client
        .send(request("POST", "/v1/messages", &[], body))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::OK);
    let response_body = response.into_body().collect().await.expect("response body");
    assert_eq!(
        &response_body.to_bytes()[..],
        expected_hash.to_string().as_bytes()
    );
    assert!(records(&primary).is_empty());
    let records = records(&zai);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].body_len, 32 << 20);
    assert_eq!(records[0].body_hash, expected_hash);
    server.stop().await;
}

#[tokio::test]
async fn concurrent_http2_streams_route_independently() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Echo).await;
    let zai = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Echo).await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let client = HttpClient::connect(&server, primary.port, HttpProtocol::Http2).await;
    let mut first = client.http2_sender();
    let mut second = client.http2_sender();
    let primary_body = br#"{"model":"claude-sonnet-5"}"#;
    let zai_body = br#"{"model":"glm-4.7"}"#;
    let (primary_result, zai_result) = tokio::join!(
        first.send_request(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(primary_body)
        )),
        second.send_request(request(
            "POST",
            "/v1/messages",
            &[(AUTHORIZATION, "Bearer fake-CLIENT-oauth")],
            full_body(zai_body)
        ))
    );
    for (result, expected) in [
        (primary_result, primary_body.as_slice()),
        (zai_result, zai_body.as_slice()),
    ] {
        let response = result.expect("response");
        assert_eq!(response.status(), hyper::StatusCode::OK);
        assert_eq!(
            &response
                .into_body()
                .collect()
                .await
                .expect("body")
                .to_bytes()[..],
            expected
        );
    }
    let primary_records = records(&primary);
    let zai_records = records(&zai);
    assert_eq!(primary_records.len(), 1);
    assert_eq!(zai_records.len(), 1);
    assert_eq!(primary_records[0].body.as_ref(), primary_body);
    assert_eq!(zai_records[0].body.as_ref(), zai_body);
    assert_eq!(primary_records[0].path, "/v1/messages");
    assert_eq!(zai_records[0].path, "/api/anthropic/v1/messages");
    assert_eq!(
        primary_records[0].authority.as_deref(),
        Some(format!("localhost:{}", primary.port).as_str())
    );
    assert_eq!(
        zai_records[0].authority.as_deref(),
        Some(format!("localhost:{}", zai.port).as_str())
    );
    assert_eq!(
        primary_records[0].headers[AUTHORIZATION],
        format!("Bearer {REAL_OAUTH_TOKEN}")
    );
    assert!(primary_records[0].headers.get("x-api-key").is_none());
    assert_eq!(zai_records[0].headers["x-api-key"], "fake-REAL-zai");
    assert!(zai_records[0].headers.get(AUTHORIZATION).is_none());
    server.stop().await;
}

#[tokio::test]
async fn selected_upstream_may_negotiate_http1_for_an_http2_client() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Echo).await;
    let zai = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http2).await;
    let response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"glm-4.7"}"#),
        ))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::OK);
    assert_eq!(&records(&zai)[0].body[..], br#"{"model":"glm-4.7"}"#);
    assert_eq!(
        &response
            .into_body()
            .collect()
            .await
            .expect("body")
            .to_bytes()[..],
        br#"{"model":"glm-4.7"}"#
    );
    assert!(records(&primary).is_empty());
    assert_eq!(records(&zai).len(), 1);
    let events = server.stop().await;
    assert!(
        fields(&events[0])["client_to_upstream"]
            .as_u64()
            .expect("upload bytes")
            > 0
    );
}

#[tokio::test]
async fn late_chunk_split_model_is_routed_without_changing_body_bytes() {
    let ca = TestCa::new();
    let primary = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let zai = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_multiplex(ca.roots(), primary.port, zai.port).await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let (sender, body) = streaming_body(2);
    let prefix = format!("{{\"padding\":\"{}\",\"model\":\"g", "x".repeat(1 << 20));
    let suffix = "lm-4.7\",\"messages\":[]}";
    let expected = format!("{prefix}{suffix}");
    tokio::spawn(async move {
        sender
            .send(Ok(Frame::data(hyper::body::Bytes::from(prefix))))
            .await
            .expect("prefix");
        sender
            .send(Ok(Frame::data(hyper::body::Bytes::from_static(
                suffix.as_bytes(),
            ))))
            .await
            .expect("suffix");
    });
    let response = client
        .send(request("POST", "/v1/messages", &[], body))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::OK);
    let _ = response.into_body().collect().await.expect("response body");
    assert!(records(&primary).is_empty());
    let records = records(&zai);
    assert_eq!(records.len(), 1);
    assert_eq!(&records[0].body[..], expected.as_bytes());
    server.stop().await;
}

#[tokio::test]
async fn http1_preserves_upstream_status_headers_and_body() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Metadata).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;

    let response = client
        .send(request("POST", "/limited", &[], full_body(b"")))
        .await;

    assert_eq!(response.status(), hyper::StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(response.version(), hyper::Version::HTTP_11);
    assert_eq!(response.headers()["retry-after"], "7");
    assert_eq!(response.headers()["x-upstream"], "metadata");
    assert!(response.headers().get(UPGRADE).is_none());
    let body = response
        .into_body()
        .collect()
        .await
        .expect("body")
        .to_bytes();
    assert_eq!(&body[..], b"quota");
    server.stop().await;
}

#[tokio::test]
async fn http2_swaps_oauth_on_the_same_protocol() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Echo).await;
    let server = Running::start_with_port(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http2).await;

    let response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[(AUTHORIZATION, "Bearer fake-CLIENT-oauth")],
            full_body(br#"{"model":"claude-sonnet-5","messages":[]}"#),
        ))
        .await;

    assert_eq!(response.status(), hyper::StatusCode::OK);
    let body = response
        .into_body()
        .collect()
        .await
        .expect("body")
        .to_bytes();
    assert_eq!(&body[..], br#"{"model":"claude-sonnet-5","messages":[]}"#);
    let received = records(&upstream);
    assert_eq!(
        received[0].headers[AUTHORIZATION],
        format!("Bearer {REAL_OAUTH_TOKEN}")
    );
    let events = server.stop().await;
    assert_eq!(fields(&events[0])["alpn"], "h2");
}

#[tokio::test]
async fn http2_requests_multiplex_while_response_headers_are_pending() {
    let release = Arc::new(tokio::sync::Notify::new());
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Gate(release)).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http2).await;
    let mut release_sender = client.http2_sender();

    let blocked = tokio::spawn(async move {
        timeout(
            Duration::from_secs(2),
            client.send(request("GET", "/blocked", &[], full_body(b""))),
        )
        .await
        .expect("blocked response deadline")
    });
    wait_for_request(&upstream, "/blocked").await;
    let released = timeout(
        Duration::from_secs(2),
        release_sender.send_request(request("GET", "/release", &[], full_body(b""))),
    )
    .await
    .expect("release response deadline")
    .expect("released response");
    assert_eq!(released.status(), hyper::StatusCode::OK);
    let blocked = blocked.await.expect("blocked task");
    assert_eq!(blocked.status(), hyper::StatusCode::OK);

    let received = records(&upstream);
    assert_eq!(received.len(), 2);
    let events = server.stop().await;
    assert_eq!(fields(&events[0])["requests"], 2);
}

#[tokio::test]
async fn api_key_credentials_replace_authorization_with_x_api_key() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_with_auth(
        "deny",
        &["localhost"],
        ca.roots(),
        None,
        FixtureAuth::ApiKey,
        Some(upstream.port),
    )
    .await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;

    let response = client
        .send(request(
            "POST",
            "/v1/messages",
            &[
                (AUTHORIZATION, "Bearer fake-CLIENT-oauth"),
                (HeaderName::from_static("x-api-key"), "fake-CLIENT-api-key"),
            ],
            full_body(br#"{"model":"claude-sonnet-5","messages":[]}"#),
        ))
        .await;

    assert_eq!(response.status(), hyper::StatusCode::OK);
    let body = response
        .into_body()
        .collect()
        .await
        .expect("body")
        .to_bytes();
    assert_eq!(&body[..], br#"{"model":"claude-sonnet-5","messages":[]}"#);
    let received = records(&upstream);
    assert_eq!(received[0].headers["x-api-key"], REAL_API_KEY);
    assert!(received[0].headers.get(AUTHORIZATION).is_none());
    server.stop().await;
}

#[tokio::test]
async fn keepalive_requests_are_each_swapped_and_counted() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;

    for index in 0..3 {
        let response = client
            .send(request(
                "POST",
                &format!("/v1/messages/{index}"),
                &[(AUTHORIZATION, "Bearer fake-CLIENT-oauth")],
                full_body(b"keepalive"),
            ))
            .await;
        let body = response
            .into_body()
            .collect()
            .await
            .expect("body")
            .to_bytes();
        assert_eq!(&body[..], b"keepalive");
    }

    let received = records(&upstream);
    assert_eq!(received.len(), 3);
    assert!(
        received.iter().all(|record| {
            record.headers[AUTHORIZATION] == format!("Bearer {REAL_OAUTH_TOKEN}")
        })
    );
    let events = server.stop().await;
    assert_eq!(fields(&events[0])["requests"], 3);
}

#[tokio::test]
async fn sse_first_event_reaches_client_before_upstream_sends_last() {
    let release = Arc::new(tokio::sync::Notify::new());
    let ca = TestCa::new();
    let upstream =
        http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Sse(release.clone())).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let mut response = client
        .send(request("GET", "/stream", &[], full_body(b"")))
        .await;
    let body = response.body_mut();

    let first = timeout(Duration::from_secs(2), body.frame())
        .await
        .expect("first event deadline")
        .expect("first event")
        .expect("first body frame")
        .into_data()
        .expect("first data");
    assert_eq!(&first[..], b"event:first\n\n");
    release.notify_one();
    let last = timeout(Duration::from_secs(2), body.frame())
        .await
        .expect("last event deadline")
        .expect("last event")
        .expect("last body frame")
        .into_data()
        .expect("last data");
    assert_eq!(&last[..], b"event:last\n\n");
    server.stop().await;
}

#[tokio::test]
async fn large_upload_streams_without_a_test_buffer() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::HashUpload).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let (sender, body) = streaming_body(2);
    let send = tokio::spawn(async move {
        let chunk_size = 64 << 10;
        let mut hash = support::FNV_OFFSET;
        for index in 0..LARGE_BODY / chunk_size {
            let mut chunk = vec![0; chunk_size];
            for (offset, byte) in chunk.iter_mut().enumerate() {
                *byte = (index.wrapping_mul(31) ^ offset).to_le_bytes()[0];
            }
            hash = fnv1a_test(hash, &chunk);
            sender
                .send(Ok(Frame::data(chunk.into())))
                .await
                .expect("upload chunk");
        }
        hash
    });
    let (_client, response) = client_send_large(&server, upstream.port, body).await;
    let body = response
        .into_body()
        .collect()
        .await
        .expect("body")
        .to_bytes();
    let expected = send.await.expect("upload task");
    assert_eq!(body, expected.to_string().as_bytes());
    let received = records(&upstream);
    assert_eq!(received[0].body_len, LARGE_BODY);
    assert_eq!(received[0].body_hash, expected);
    let events = server.stop().await;
    let audit = fields(&events[0]);
    assert!(
        audit["client_to_upstream"].as_u64().expect("upload audit") >= LARGE_BODY as u64,
        "large upload bytes were not audited"
    );
}

async fn client_send_large(
    server: &Running,
    port: u16,
    body: support::ReceiverBody,
) -> (HttpClient, hyper::Response<hyper::body::Incoming>) {
    let mut client = HttpClient::connect(server, port, HttpProtocol::Http1).await;
    let request = hyper::Request::builder()
        .method("POST")
        .uri("/upload")
        .header("content-length", LARGE_BODY.to_string())
        .body(body)
        .expect("upload request");
    let response = timeout(Duration::from_secs(120), client.send(request))
        .await
        .expect("upload deadline");
    (client, response)
}

#[tokio::test]
async fn http1_upgrade_returns_101_then_bridges_bytes() {
    let ca = TestCa::new();
    let upgrade_bytes = Arc::new(UpgradeBytes {
        client_to_upstream: std::sync::atomic::AtomicU64::new(0),
    });
    let upstream = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::UpgradeEcho(upgrade_bytes.clone()),
    )
    .await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = server
        .handshake(upstream.port, "localhost", &[b"http/1.1"], true)
        .await
        .expect("client handshake");

    client
        .write_all(
            b"GET /websocket HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: test\r\n\r\n",
        )
        .await
        .expect("upgrade request");
    let mut header = Vec::new();
    timeout(Duration::from_secs(2), async {
        while !header.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            assert!(client.read(&mut byte).await.expect("header byte") > 0);
            header.push(byte[0]);
            assert!(header.len() < 8192);
        }
    })
    .await
    .expect("101 deadline");
    let header = String::from_utf8(header).expect("header UTF-8");
    assert!(
        header.starts_with("HTTP/1.1 101 Switching Protocols\r\n"),
        "{header}"
    );
    assert!(
        header.to_ascii_lowercase().contains("upgrade: test\r\n"),
        "{header}"
    );

    client.write_all(b"client-up").await.expect("upgrade send");
    let mut echoed = [0; 9];
    timeout(Duration::from_secs(2), client.read_exact(&mut echoed))
        .await
        .expect("upgrade echo deadline")
        .expect("upgrade echo");
    assert_eq!(&echoed[..], b"client-up");
    client.shutdown().await.expect("upgrade half-close");
    timeout(Duration::from_secs(2), upstream.done)
        .await
        .expect("upstream deadline")
        .expect("upstream task")
        .expect("upstream serve");
    let event = server.closed_event().await;
    let audit = fields(&event);
    assert_eq!(audit["outcome"], "closed");
    assert_eq!(
        audit["client_to_upstream"].as_u64().expect("request audit"),
        upgrade_bytes.client_to_upstream.load(Ordering::Relaxed),
        "upgraded request bytes were counted more than once"
    );
    assert_eq!(
        audit["upstream_to_client"]
            .as_u64()
            .expect("response audit"),
        (header.len() + echoed.len()) as u64,
        "upgraded response bytes were counted more than once"
    );
    let events = server.stop().await;
    assert_eq!(events.len(), 1);
}

#[tokio::test]
async fn hop_by_hop_headers_do_not_reach_upstream_or_replace_real_auth() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let response = client
        .send(request(
            "GET",
            "/hop-by-hop",
            &[
                (CONNECTION, "authorization, Keep-Alive"),
                (HeaderName::from_static("keep-alive"), "timeout=1"),
                (PROXY_AUTHENTICATE, "Basic"),
                (PROXY_AUTHORIZATION, "Basic fake-CLIENT-proxy"),
                (TE, "trailers"),
                (TRAILER, "x-test"),
            ],
            full_body(b""),
        ))
        .await;

    assert_eq!(response.status(), hyper::StatusCode::OK);
    let received = records(&upstream);
    assert_eq!(
        received[0].headers[AUTHORIZATION],
        format!("Bearer {REAL_OAUTH_TOKEN}")
    );
    for header in [
        CONNECTION,
        HeaderName::from_static("keep-alive"),
        PROXY_AUTHENTICATE,
        PROXY_AUTHORIZATION,
        TRAILER,
    ] {
        assert!(received[0].headers.get(&header).is_none(), "{header:?}");
    }
    server.stop().await;
}

#[tokio::test]
async fn request_after_upstream_connection_death_receives_502() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::CloseAfterResponse).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;

    let first = client
        .send(request("GET", "/first", &[], full_body(b"")))
        .await;
    let first_body = first
        .into_body()
        .collect()
        .await
        .expect("first body")
        .to_bytes();
    assert_eq!(&first_body[..], b"upstream-closed");
    let record_count = records(&upstream).len();
    let _ = timeout(Duration::from_secs(2), upstream.done)
        .await
        .expect("upstream deadline")
        .expect("upstream task");

    let second = client
        .send(request("GET", "/second", &[], full_body(b"")))
        .await;
    assert_eq!(second.status(), hyper::StatusCode::BAD_GATEWAY);
    let body = second
        .into_body()
        .collect()
        .await
        .expect("second body")
        .to_bytes();
    assert_eq!(&body[..], b"upstream connection failed");
    assert_eq!(record_count, 1);
    let events = server.stop().await;
    assert_eq!(fields(&events[0])["requests"], 2);
}

#[tokio::test]
async fn upstream_drop_mid_response_closes_the_client_without_hanging() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::DropMidResponse).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let mut response = client
        .send(request("GET", "/drop", &[], full_body(b"")))
        .await;
    let body = response.body_mut();

    let first = timeout(Duration::from_secs(2), body.frame())
        .await
        .expect("first deadline")
        .expect("first frame")
        .expect("first data")
        .into_data()
        .expect("first bytes");
    assert_eq!(&first[..], b"first-event;");
    let tail = timeout(Duration::from_secs(2), body.frame())
        .await
        .expect("failure deadline");
    assert!(
        tail.is_some_and(|frame| frame.is_err()),
        "natural EOF is not an upstream transport failure"
    );
    let events = server.stop().await;
    let audit = fields(&events[0]);
    assert_eq!(audit["requests"], 1);
    assert!(
        audit["upstream_to_client"]
            .as_u64()
            .expect("response audit")
            > 0
    );
}

#[tokio::test]
async fn http2_client_drop_before_headers_cancels_upstream_and_audits_the_request() {
    let release = Arc::new(tokio::sync::Notify::new());
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Gate(release)).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http2).await;
    let mut sender = client.http2_sender();
    let pending = tokio::spawn(async move {
        timeout(
            Duration::from_secs(2),
            sender.send_request(request("GET", "/blocked", &[], full_body(b""))),
        )
        .await
        .expect("pending response deadline")
    });
    wait_for_request(&upstream, "/blocked").await;

    drop(client);
    pending.abort();
    let _ = timeout(Duration::from_secs(1), upstream.done)
        .await
        .expect("upstream cancellation deadline");
    let event = server.closed_event().await;
    let audit = fields(&event);
    assert_eq!(audit["requests"], 1);
    let request_events = server.capture.request_events();
    assert!(
        request_events
            .iter()
            .any(|event| event["fields"]["cancelled"] == true),
        "pending request was not logged as cancelled"
    );
}

#[tokio::test]
async fn http1_client_drop_mid_response_closes_the_upstream_within_a_second() {
    let release = Arc::new(tokio::sync::Notify::new());
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Sse(release)).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let mut response = client
        .send(request("GET", "/stream", &[], full_body(b"")))
        .await;
    let body = response.body_mut();
    let first = timeout(Duration::from_secs(2), body.frame())
        .await
        .expect("first event deadline")
        .expect("first event")
        .expect("first body frame")
        .into_data()
        .expect("first data");
    assert_eq!(&first[..], b"event:first\n\n");

    drop(client);
    let _ = timeout(Duration::from_secs(1), upstream.done)
        .await
        .expect("upstream close deadline");
    let event = server.closed_event().await;
    assert_eq!(fields(&event)["requests"], 1);
}

#[tokio::test]
async fn stalled_reader_close_notify_cannot_hold_a_live_socket_open() {
    let gates = Arc::new(StallGates {
        backpressure: tokio::sync::Notify::new(),
        response_started: tokio::sync::Notify::new(),
    });
    let ca = TestCa::new();
    let upstream =
        http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Stall(gates.clone())).await;
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut client = server
        .handshake(upstream.port, "localhost", &[b"http/1.1"], true)
        .await
        .expect("client handshake");
    client
        .write_all(b"GET /stalled HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")
        .await
        .expect("stalled request");
    client.flush().await.expect("request flush");
    timeout(Duration::from_secs(2), gates.response_started.notified())
        .await
        .expect("response start deadline");
    timeout(Duration::from_secs(2), gates.backpressure.notified())
        .await
        .expect("backpressure deadline");

    client.shutdown().await.expect("TLS close_notify");
    let upstream_result = timeout(Duration::from_secs(1), upstream.done)
        .await
        .expect("half-close upstream deadline")
        .expect("half-close upstream task");
    assert!(upstream_result.is_err(), "stalled upstream stopped writing");
    let event = server.closed_event().await;
    let audit = fields(&event);
    assert_eq!(audit["requests"], 1);
    assert!(
        audit["upstream_to_client"]
            .as_u64()
            .expect("response audit")
            > 0
    );
    drop(client);
    let events = server.stop().await;
    assert_eq!(events.len(), 1);
}

#[tokio::test]
async fn alpn_is_mirrored_from_the_upstream() {
    let ca = TestCa::new();
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    for (protocol, expected) in [
        (HttpProtocol::Http2, "h2"),
        (HttpProtocol::Http1, "http/1.1"),
    ] {
        let upstream = http_upstream(&ca, protocol, UpstreamMode::Echo).await;
        let client = server
            .handshake(upstream.port, "localhost", &[b"h2", b"http/1.1"], true)
            .await
            .expect("client handshake");
        assert_eq!(
            client.get_ref().1.alpn_protocol(),
            Some(expected.as_bytes())
        );
        drop(client);
        let _ = timeout(Duration::from_secs(2), upstream.done)
            .await
            .expect("upstream deadline")
            .expect("upstream task");
    }
    let events = server.stop().await;
    let alpn: Vec<_> = events
        .iter()
        .map(|event| fields(event)["alpn"].as_str().expect("alpn").to_owned())
        .collect();
    assert_eq!(alpn, ["h2", "http/1.1"]);
}

#[tokio::test]
async fn leaf_is_minted_once_for_the_host_and_chains_to_the_airlock_ca() {
    let ca = TestCa::new();
    let server = Running::start_with("deny", &["localhost"], ca.roots(), None).await;
    let mut leaves = Vec::new();
    for _ in 0..2 {
        let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Echo).await;
        let client = server
            .handshake(upstream.port, "localhost", &[], true)
            .await
            .expect("client handshake");
        let chain = client.get_ref().1.peer_certificates().expect("chain");
        assert_eq!(chain.len(), 1);
        leaves.push(chain[0].to_vec());
        drop(client);
        let _ = timeout(Duration::from_secs(2), upstream.done)
            .await
            .expect("upstream deadline")
            .expect("upstream task");
    }
    assert_eq!(leaves[0], leaves[1], "the cached leaf was re-minted");

    let ca_pem = fs::read(server.ca_directory.join("ca.pem")).expect("ca.pem");
    let ca_der = rustls::pki_types::pem::PemObject::from_pem_slice(&ca_pem)
        .map(|der: rustls::pki_types::CertificateDer<'static>| der.to_vec())
        .expect("CA DER");
    let (_, authority) =
        x509_parser::certificate::X509Certificate::from_der(&ca_der).expect("parse CA");
    let (_, leaf) =
        x509_parser::certificate::X509Certificate::from_der(&leaves[0]).expect("parse leaf");
    assert_eq!(leaf.issuer(), authority.subject());
    let names = &leaf
        .subject_alternative_name()
        .expect("SAN extension")
        .expect("SAN present")
        .value
        .general_names;
    assert!(matches!(
        names.as_slice(),
        [GeneralName::DNSName("localhost")]
    ));
    server.stop().await;
}

#[tokio::test]
async fn sni_mismatch_missing_sni_and_plaintext_never_reach_the_upstream() {
    let listener = sink().await;
    let port = listener.local_addr().expect("sink address").port();
    let server = Running::start_with("deny", &["localhost"], TestCa::new().roots(), None).await;
    assert!(
        server
            .handshake(port, "other.test", &[], true)
            .await
            .is_err()
    );
    assert!(
        server
            .handshake(port, "localhost", &[], false)
            .await
            .is_err()
    );
    let mut socket = server.connect(port).await;
    socket
        .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        .await
        .expect("plaintext");
    let mut reply = Vec::new();
    timeout(Duration::from_secs(2), socket.read_to_end(&mut reply))
        .await
        .expect("closed deadline")
        .expect("closed");
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    let events = server.stop().await;
    let outcomes = events
        .iter()
        .map(|event| {
            let audit = fields(event);
            assert_eq!(audit["decision"], "intercept");
            (
                audit["outcome"].as_str().expect("outcome").to_owned(),
                audit["sni"].as_str().expect("sni").to_owned(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        outcomes,
        [
            ("sni_mismatch".to_owned(), "other.test".to_owned()),
            ("sni_missing".to_owned(), String::new()),
            ("not_tls".to_owned(), String::new()),
        ]
    );
}

#[tokio::test]
async fn untrusted_upstream_fails_the_client_handshake_and_forwards_nothing() {
    let trusted = TestCa::new();
    let upstream = tls_upstream(TestCa::new().server_config(&[])).await;
    let server = Running::start_with("deny", &["localhost"], trusted.roots(), None).await;
    assert!(
        server
            .handshake(upstream.port, "localhost", &[], true)
            .await
            .is_err()
    );
    assert!(
        upstream.accepted.await.expect("upstream task").is_err(),
        "the upstream completed a handshake with an unverified gateway"
    );
    let events = server.stop().await;
    assert_eq!(fields(&events[0])["outcome"], "upstream_tls_error");
}

#[tokio::test]
async fn symlinked_ca_directory_or_files_are_refused() {
    let ca = TestCa::new();
    let directory = tempfile::tempdir().expect("tempdir");
    fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("token");
    for credential in ["claude", "backup"] {
        fs::write(directory.path().join(credential), "unused-by-this-test\n")
            .expect("write credential");
    }
    let bind = async |ca_directory: &std::path::Path| {
        Gateway::bind(
            config(&directory, "deny", &["localhost"]),
            ca_directory,
            ca.roots(),
        )
        .await
        .err()
        .expect("startup refused")
    };
    let elsewhere = directory.path().join("elsewhere");
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&elsewhere)
        .expect("private target");
    let linked = directory.path().join("airlock-8080");
    std::os::unix::fs::symlink(&elsewhere, &linked).expect("symlink directory");
    let error = bind(&linked).await;
    assert!(
        matches!(&error, Error::Authority(CaError::NotPrivate { path }) if *path == linked),
        "{error}"
    );
    assert_eq!(fs::read_dir(&elsewhere).expect("target").count(), 0);

    let ca_directory = directory.path().join("airlock-8081");
    let first = Running::start_with("deny", &["localhost"], ca.roots(), Some(&ca_directory)).await;
    first.stop().await;
    let key = ca_directory.join("ca.key");
    let moved = elsewhere.join("ca.key");
    fs::rename(&key, &moved).expect("move ca.key");
    std::os::unix::fs::symlink(&moved, &key).expect("symlink ca.key");
    let error = bind(&ca_directory).await;
    assert!(
        matches!(&error, Error::Authority(CaError::NotRegular { path }) if *path == key),
        "{error}"
    );
}

#[tokio::test]
async fn ca_is_reused_across_binds_and_refused_when_exposed_or_incomplete() {
    let ca = TestCa::new();
    let directory = tempfile::tempdir().expect("tempdir");
    let ca_directory = directory.path().join("airlock-8080");
    let cert = ca_directory.join("ca.pem");
    let key = ca_directory.join("ca.key");
    let mode =
        |path: &std::path::Path| fs::metadata(path).expect("metadata").permissions().mode() & 0o777;

    let first = Running::start_with("deny", &["localhost"], ca.roots(), Some(&ca_directory)).await;
    assert_eq!(mode(&ca_directory), 0o700);
    assert_eq!(mode(&key), 0o600);
    assert_eq!(mode(&cert), 0o644);
    let issued = fs::read(&cert).expect("ca.pem");
    first.stop().await;

    let second = Running::start_with("deny", &["localhost"], ca.roots(), Some(&ca_directory)).await;
    assert_eq!(
        fs::read(&cert).expect("ca.pem"),
        issued,
        "the CA was re-minted"
    );
    let upstream = tls_upstream(ca.server_config(&[])).await;
    second
        .handshake(upstream.port, "localhost", &[], true)
        .await
        .expect("leaf from the reused CA");
    second.stop().await;

    let bind = async || {
        fs::write(directory.path().join("token"), format!("{TOKEN}\n")).expect("token");
        fs::write(
            directory.path().join("claude"),
            format!("{REAL_OAUTH_TOKEN}\n"),
        )
        .expect("oauth credential");
        fs::write(directory.path().join("backup"), format!("{REAL_API_KEY}\n"))
            .expect("api-key credential");
        Gateway::bind(
            config(&directory, "deny", &["localhost"]),
            &ca_directory,
            ca.roots(),
        )
        .await
        .err()
        .expect("startup refused")
    };
    fs::set_permissions(&key, fs::Permissions::from_mode(0o644)).expect("chmod");
    let error = bind().await;
    assert!(
        matches!(&error, Error::Authority(CaError::KeyExposed { path, .. }) if *path == key),
        "{error}"
    );
    assert!(error.to_string().contains(key.to_str().expect("path")));

    fs::set_permissions(&key, fs::Permissions::from_mode(0o600)).expect("chmod");
    fs::remove_file(&cert).expect("remove ca.pem");
    let error = bind().await;
    assert!(
        matches!(&error, Error::Authority(CaError::Incomplete { present, .. }) if *present == key),
        "{error}"
    );
    assert!(error.to_string().contains(key.to_str().expect("path")));

    fs::write(&cert, &issued).expect("restore ca.pem");
    fs::remove_file(&key).expect("remove ca.key");
    let error = bind().await;
    assert!(
        matches!(&error, Error::Authority(CaError::Incomplete { present, .. }) if *present == cert),
        "{error}"
    );
    assert_eq!(
        fs::read(&cert).expect("ca.pem"),
        issued,
        "ca.pem was overwritten"
    );
}
