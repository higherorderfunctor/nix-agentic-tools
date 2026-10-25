//! HTTP interception: airlock's leaf to the client, verified TLS upstream, swapped auth.

mod support;

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::Write,
    num::NonZeroU64,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    sync::{Arc, atomic::Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use airlock_core::{
    ids::{ClientId, CredentialId, GroupId, ProviderId},
    storage::{
        RequestEvent, RequestOutcome, RequestUsageQuery, SqliteStorage, Storage, StorageError,
        StorageIdentities,
    },
};
use airlock_gateway::{CaError, Error, Gateway, RequestUsageSink};
use flate2::{Compression, write::GzEncoder};
use http_body_util::BodyExt;
use hyper::header::HeaderName;
use hyper::{
    body::{Bytes, Frame},
    header::{
        AUTHORIZATION, CONNECTION, PROXY_AUTHENTICATE, PROXY_AUTHORIZATION, TE, TRAILER, UPGRADE,
    },
};
use sqlx::{Connection, SqliteConnection, sqlite::SqliteConnectOptions};
use support::{
    FixtureAuth, HttpClient, HttpProtocol, REAL_API_KEY, REAL_OAUTH_TOKEN, Running, StallGates,
    TOKEN, TestCa, UpgradeBytes, UpstreamMode, config, fields, fnv1a_test, full_body,
    http_upstream, owned_body, records, request, sink, streaming_body, tls_upstream,
    wait_for_request,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    time::timeout,
};
use x509_parser::{extensions::GeneralName, prelude::FromDer};

const LARGE_BODY: usize = 64 << 20;

async fn managed_status(
    client: &mut HttpClient,
    request: hyper::Request<support::ReceiverBody>,
) -> hyper::StatusCode {
    let response = client.send(request).await;
    let status = response.status();
    response
        .into_body()
        .collect()
        .await
        .expect("managed response body");
    status
}

#[tokio::test]
async fn another_authenticated_client_cannot_replay_the_managed_primary() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Oauth).await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let mut owner = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let login = owner
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
        ))
        .await;
    assert_eq!(login.status(), hyper::StatusCode::OK);
    let (_, refused) = server
        .request(
            "CONNECT",
            &format!("localhost:{}", upstream.port),
            Some(&support::basic("stranger", "fake-STRANGER-token")),
        )
        .await;
    assert!(
        refused.starts_with("HTTP/1.1 403"),
        "other client reached primary"
    );
    assert_eq!(records(&upstream).len(), 1);
    server.stop().await;
}

#[tokio::test]
async fn stalled_oauth_body_times_out_and_releases_the_primary() {
    let gates = Arc::new(StallGates {
        backpressure: tokio::sync::Notify::new(),
        response_started: tokio::sync::Notify::new(),
    });
    let ca = TestCa::new();
    let upstream = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::OauthStall(gates.clone()),
    )
    .await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let pending = tokio::spawn(async move {
        let status = managed_status(
            &mut client,
            request(
                "POST",
                "/v1/oauth/token",
                &[],
                full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
            ),
        )
        .await;
        (client, status)
    });
    timeout(Duration::from_secs(2), gates.response_started.notified())
        .await
        .expect("upstream token response started");
    let (mut client, status) = timeout(Duration::from_secs(33), pending)
        .await
        .expect("bounded OAuth exchange")
        .expect("client task");
    assert_eq!(status, hyper::StatusCode::GATEWAY_TIMEOUT);
    let unknown = managed_status(
        &mut client,
        request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"refresh_token","refresh_token":"fake-UNKNOWN"}"#),
        ),
    );
    assert_eq!(
        timeout(Duration::from_secs(2), unknown)
            .await
            .expect("released primary lock"),
        hyper::StatusCode::UNAUTHORIZED
    );
    assert_eq!(records(&upstream).len(), 1);
    gates.backpressure.notify_one();
    server.stop().await;
}

#[tokio::test]
#[expect(
    clippy::too_many_lines,
    reason = "one fixture exercises the complete stateful OAuth lifecycle"
)]
async fn managed_oauth_exchanges_refreshes_and_revokes_without_exposing_real_tokens() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Oauth).await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let login_wire = br#"{"grant_type":"authorization_code","code":"fake-code","code_verifier":"fake-verifier","state":"fake-state","client_id":"fake-client"}"#;
    let login = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(login_wire),
        ))
        .await;
    assert_eq!(login.status(), hyper::StatusCode::OK);
    let login_body = login
        .into_body()
        .collect()
        .await
        .expect("login body")
        .to_bytes();
    let login: serde_json::Value = serde_json::from_slice(&login_body).expect("login JSON");
    let fake_access = login["access_token"].as_str().expect("fake access");
    let fake_refresh = login["refresh_token"].as_str().expect("fake refresh");
    assert!(fake_access.starts_with("sk-ant-oat01-airlock-"));
    assert_ne!(fake_access, "fake-REAL-access-one");
    assert_ne!(fake_refresh, "fake-REAL-refresh-one");
    assert_eq!(login["expires_in"], 3600);
    assert_eq!(login["scope"], "user:inference user:profile");
    assert_eq!(login["account"]["uuid"], "fake-account");

    let mut profile = request("GET", "/api/oauth/profile", &[], full_body(b""));
    profile.headers_mut().insert(
        AUTHORIZATION,
        format!("Bearer {fake_access}")
            .parse()
            .expect("fake header"),
    );
    assert_eq!(
        managed_status(&mut client, profile).await,
        hyper::StatusCode::OK
    );
    let mut unknown = request("GET", "/api/oauth/profile", &[], full_body(b""));
    unknown.headers_mut().insert(
        AUTHORIZATION,
        "Bearer fake-UNKNOWN-access".parse().expect("fake header"),
    );
    assert_eq!(
        managed_status(&mut client, unknown).await,
        hyper::StatusCode::UNAUTHORIZED
    );

    let refresh = serde_json::json!({"grant_type":"refresh_token","refresh_token":fake_refresh,"client_id":"fake-client"});
    let refreshed = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            owned_body(serde_json::to_vec(&refresh).expect("refresh JSON")),
        ))
        .await;
    assert_eq!(refreshed.status(), hyper::StatusCode::OK);
    let refreshed_body = refreshed
        .into_body()
        .collect()
        .await
        .expect("refresh body")
        .to_bytes();
    let refreshed: serde_json::Value =
        serde_json::from_slice(&refreshed_body).expect("refresh JSON");
    let new_access = refreshed["access_token"].as_str().expect("new access");
    let new_refresh = refreshed["refresh_token"].as_str().expect("new refresh");
    assert_ne!(new_access, fake_access);
    assert_ne!(new_refresh, fake_refresh);
    assert!(
        !refreshed_body
            .windows(b"fake-REAL".len())
            .any(|bytes| bytes == b"fake-REAL")
    );

    let mut old = request("GET", "/api/oauth/profile", &[], full_body(b""));
    old.headers_mut().insert(
        AUTHORIZATION,
        format!("Bearer {fake_access}")
            .parse()
            .expect("fake header"),
    );
    assert_eq!(
        managed_status(&mut client, old).await,
        hyper::StatusCode::UNAUTHORIZED
    );
    let mut latest = request("GET", "/api/oauth/profile", &[], full_body(b""));
    latest.headers_mut().insert(
        AUTHORIZATION,
        format!("Bearer {new_access}").parse().expect("fake header"),
    );
    assert_eq!(
        managed_status(&mut client, latest).await,
        hyper::StatusCode::OK
    );
    for path in [
        "/api/oauth/claude_cli/create_api_key",
        "/api/oauth/claude_cli/create_api_key/",
        "/api/oauth/claude_cli/%63reate_api_key", // cspell:ignore reate
    ] {
        let mut key_request = request("POST", path, &[], full_body(b""));
        key_request.headers_mut().insert(
            AUTHORIZATION,
            format!("Bearer {new_access}").parse().expect("fake header"),
        );
        assert_eq!(
            managed_status(&mut client, key_request).await,
            hyper::StatusCode::FORBIDDEN
        );
    }

    let revoke = serde_json::json!({"token":new_refresh,"token_type_hint":"refresh_token","client_id":"fake-client"});
    assert_eq!(
        managed_status(
            &mut client,
            request(
                "POST",
                "/v1/oauth/token/revoke",
                &[],
                owned_body(serde_json::to_vec(&revoke).expect("revoke JSON"))
            )
        )
        .await,
        hyper::StatusCode::OK
    );
    let mut retired = request("GET", "/api/oauth/profile", &[], full_body(b""));
    retired.headers_mut().insert(
        AUTHORIZATION,
        format!("Bearer {new_access}").parse().expect("fake header"),
    );
    assert_eq!(
        managed_status(&mut client, retired).await,
        hyper::StatusCode::UNAUTHORIZED
    );

    let received = records(&upstream);
    assert_eq!(received.len(), 5);
    assert_eq!(&received[0].body[..], login_wire);
    assert!(received[0].headers.get(AUTHORIZATION).is_none());
    assert_eq!(
        received[1].headers[AUTHORIZATION],
        "Bearer fake-REAL-access-one"
    );
    let sent_refresh: serde_json::Value =
        serde_json::from_slice(&received[2].body).expect("upstream refresh");
    assert_eq!(sent_refresh["refresh_token"], "fake-REAL-refresh-one");
    assert_eq!(
        received[3].headers[AUTHORIZATION],
        "Bearer fake-REAL-access-two"
    );
    let sent_revoke: serde_json::Value =
        serde_json::from_slice(&received[4].body).expect("upstream revoke");
    assert_eq!(sent_revoke["token"], "fake-REAL-refresh-two");
    server.capture.request_events();
    server.stop().await;
}

#[expect(
    clippy::too_many_lines,
    reason = "the malformed initial-exchange table verifies every rejection against a fresh gateway"
)]
#[tokio::test]
async fn managed_oauth_rejects_malformed_success_without_a_mapping() {
    let valid = serde_json::json!({
        "access_token": "fake-REAL-access",
        "expires_in": 3600,
        "refresh_token": "fake-REAL-refresh",
    });
    let mut cases = Vec::new();
    for (name, field, replacement) in [
        (
            "access array",
            "access_token",
            serde_json::json!(["fake-REAL"]),
        ),
        ("access empty", "access_token", serde_json::json!("")),
        (
            "access header invalid",
            "access_token",
            serde_json::json!("fake-REAL\r\nx"),
        ),
        ("access null", "access_token", serde_json::Value::Null),
        (
            "access object",
            "access_token",
            serde_json::json!({"value":"fake-REAL"}),
        ),
        (
            "access oversize",
            "access_token",
            serde_json::json!("x".repeat(8193)),
        ),
        ("expiry negative", "expires_in", serde_json::json!(-1)),
        ("expiry null", "expires_in", serde_json::Value::Null),
        ("expiry overflow", "expires_in", serde_json::json!(u64::MAX)),
        ("expiry string", "expires_in", serde_json::json!("3600")),
        ("expiry zero", "expires_in", serde_json::json!(0)),
        (
            "refresh array",
            "refresh_token",
            serde_json::json!(["fake-REAL"]),
        ),
        ("refresh empty", "refresh_token", serde_json::json!("")),
        ("refresh null", "refresh_token", serde_json::Value::Null),
        (
            "refresh object",
            "refresh_token",
            serde_json::json!({"value":"fake-REAL"}),
        ),
        (
            "refresh oversize",
            "refresh_token",
            serde_json::json!("x".repeat(8193)),
        ),
    ] {
        let mut response = valid.clone();
        response[field] = replacement;
        cases.push((name, response));
    }
    for (name, field) in [
        ("access missing", "access_token"),
        ("expiry missing", "expires_in"),
        ("refresh missing", "refresh_token"),
    ] {
        let mut response = valid.clone();
        response
            .as_object_mut()
            .expect("response object")
            .remove(field);
        cases.push((name, response));
    }
    for (name, reply) in cases {
        let ca = TestCa::new();
        let body = Box::leak(
            serde_json::to_vec(&reply)
                .expect("fixture JSON")
                .into_boxed_slice(),
        );
        let upstream = http_upstream(
            &ca,
            HttpProtocol::Http1,
            UpstreamMode::OauthReply {
                body,
                status: hyper::StatusCode::OK,
            },
        )
        .await;
        let server = Running::start_managed(ca.roots(), upstream.port).await;
        let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
        let response = client
            .send(request(
                "POST",
                "/v1/oauth/token",
                &[],
                full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
            ))
            .await;
        assert_eq!(response.status(), hyper::StatusCode::BAD_GATEWAY, "{name}");
        let body = response
            .into_body()
            .collect()
            .await
            .expect("rejection body")
            .to_bytes();
        assert!(
            !body
                .windows(b"fake-REAL".len())
                .any(|part| part == b"fake-REAL"),
            "{name}"
        );
        let mut profile = request("GET", "/api/oauth/profile", &[], full_body(b""));
        profile.headers_mut().insert(
            AUTHORIZATION,
            "Bearer fake-UNKNOWN-access".parse().expect("fake header"),
        );
        assert_eq!(
            managed_status(&mut client, profile).await,
            hyper::StatusCode::UNAUTHORIZED,
            "{name}"
        );
        assert_eq!(records(&upstream).len(), 1, "{name}");
        drop(client);
        server.stop().await;
    }
}

#[expect(
    clippy::too_many_lines,
    reason = "the malformed refresh table verifies every rejection preserves the prior mapping"
)]
#[tokio::test]
async fn managed_refresh_rejects_present_invalid_fields_without_changing_mapping() {
    let valid = serde_json::json!({
        "access_token": "fake-REAL-new",
        "expires_in": 3600,
        "refresh_token": "fake-REAL-new-refresh",
        "refresh_token_expires_in": 86400,
    });
    let mut cases = Vec::new();
    for (name, field, replacement) in [
        (
            "access array",
            "access_token",
            serde_json::json!(["fake-REAL"]),
        ),
        ("access empty", "access_token", serde_json::json!("")),
        (
            "access header invalid",
            "access_token",
            serde_json::json!("fake-REAL\r\nx"),
        ),
        ("access null", "access_token", serde_json::Value::Null),
        (
            "access object",
            "access_token",
            serde_json::json!({"value":"fake-REAL"}),
        ),
        (
            "access oversize",
            "access_token",
            serde_json::json!("x".repeat(8193)),
        ),
        ("expiry negative", "expires_in", serde_json::json!(-1)),
        ("expiry null", "expires_in", serde_json::Value::Null),
        ("expiry overflow", "expires_in", serde_json::json!(u64::MAX)),
        ("expiry string", "expires_in", serde_json::json!("3600")),
        ("expiry zero", "expires_in", serde_json::json!(0)),
        (
            "refresh array",
            "refresh_token",
            serde_json::json!(["fake-REAL"]),
        ),
        ("refresh empty", "refresh_token", serde_json::json!("")),
        ("refresh null", "refresh_token", serde_json::Value::Null),
        (
            "refresh object",
            "refresh_token",
            serde_json::json!({"value":"fake-REAL"}),
        ),
        (
            "refresh oversize",
            "refresh_token",
            serde_json::json!("x".repeat(8193)),
        ),
        (
            "refresh expiry negative",
            "refresh_token_expires_in",
            serde_json::json!(-1),
        ),
        (
            "refresh expiry null",
            "refresh_token_expires_in",
            serde_json::Value::Null,
        ),
        (
            "refresh expiry overflow",
            "refresh_token_expires_in",
            serde_json::json!(u64::MAX),
        ),
        (
            "refresh expiry string",
            "refresh_token_expires_in",
            serde_json::json!("86400"),
        ),
        (
            "refresh expiry zero",
            "refresh_token_expires_in",
            serde_json::json!(0),
        ),
    ] {
        let mut response = valid.clone();
        response[field] = replacement;
        cases.push((name, response));
    }
    for (name, field) in [
        ("access missing", "access_token"),
        ("expiry missing", "expires_in"),
    ] {
        let mut response = valid.clone();
        response
            .as_object_mut()
            .expect("response object")
            .remove(field);
        cases.push((name, response));
    }
    for (name, reply) in cases {
        let malformed = Box::leak(
            serde_json::to_vec(&reply)
                .expect("fixture JSON")
                .into_boxed_slice(),
        );
        let ca = TestCa::new();
        let upstream = http_upstream(
            &ca,
            HttpProtocol::Http1,
            UpstreamMode::OauthRefreshReply {
                initial: None,
                refresh: malformed,
            },
        )
        .await;
        let server = Running::start_managed(ca.roots(), upstream.port).await;
        let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
        let login = client
            .send(request(
                "POST",
                "/v1/oauth/token",
                &[],
                full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
            ))
            .await;
        let login = login
            .into_body()
            .collect()
            .await
            .expect("login body")
            .to_bytes();
        let login: serde_json::Value = serde_json::from_slice(&login).expect("login JSON");
        let refresh = serde_json::to_vec(&serde_json::json!({
            "grant_type": "refresh_token",
            "refresh_token": login["refresh_token"],
        }))
        .expect("refresh JSON");
        let response = client
            .send(request("POST", "/v1/oauth/token", &[], owned_body(refresh)))
            .await;
        assert_eq!(response.status(), hyper::StatusCode::BAD_GATEWAY, "{name}");
        let body = response
            .into_body()
            .collect()
            .await
            .expect("rejection body")
            .to_bytes();
        assert!(
            !body
                .windows(b"fake-REAL".len())
                .any(|part| part == b"fake-REAL"),
            "{name}"
        );
        let mut profile = request("GET", "/api/oauth/profile", &[], full_body(b""));
        profile.headers_mut().insert(
            AUTHORIZATION,
            format!(
                "Bearer {}",
                login["access_token"].as_str().expect("fake access")
            )
            .parse()
            .expect("fake header"),
        );
        assert_eq!(
            managed_status(&mut client, profile).await,
            hyper::StatusCode::OK,
            "{name}"
        );
        assert_eq!(records(&upstream).len(), 3, "{name}");
        server.stop().await;
    }
}

#[tokio::test]
async fn managed_refresh_without_new_token_caps_or_learns_its_expiry() {
    let known_initial = br#"{"access_token":"fake-REAL-initial","refresh_token":"fake-REAL-refresh","expires_in":3600,"refresh_token_expires_in":3600}"#;
    let unknown_initial = br#"{"access_token":"fake-REAL-initial","refresh_token":"fake-REAL-refresh","expires_in":3600}"#;
    for (name, initial, lifetime, preserves_old) in [
        ("longer supplied lifetime", &known_initial[..], 7200, true),
        ("shorter supplied lifetime", &known_initial[..], 60, false),
        ("unknown old lifetime", &unknown_initial[..], 60, false),
    ] {
        let reply = Box::leak(
            serde_json::to_vec(&serde_json::json!({
                "access_token": "fake-REAL-new",
                "expires_in": 3600,
                "refresh_token_expires_in": lifetime,
            }))
            .expect("refresh fixture")
            .into_boxed_slice(),
        );
        let ca = TestCa::new();
        let upstream = http_upstream(
            &ca,
            HttpProtocol::Http1,
            UpstreamMode::OauthRefreshReply {
                initial: Some(initial),
                refresh: reply,
            },
        )
        .await;
        let server = Running::start_managed(ca.roots(), upstream.port).await;
        let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
        let login = client
            .send(request(
                "POST",
                "/v1/oauth/token",
                &[],
                full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
            ))
            .await;
        assert_eq!(login.status(), hyper::StatusCode::OK, "{name}");
        let login = login
            .into_body()
            .collect()
            .await
            .expect("login body")
            .to_bytes();
        let login: serde_json::Value = serde_json::from_slice(&login).expect("login JSON");
        let path = server.directory.path().join("airlock.sqlite3");
        let mut database = SqliteConnection::connect_with(
            &SqliteConnectOptions::new()
                .filename(&path)
                .create_if_missing(false),
        )
        .await
        .expect("fixture database");
        let expiry_query = "SELECT refresh_token_expires_at_unix FROM oauth_tokens";
        let old_expiry: Option<i64> = sqlx::query_scalar(expiry_query)
            .fetch_one(&mut database)
            .await
            .expect("old expiry");
        let refresh = serde_json::to_vec(&serde_json::json!({
            "grant_type": "refresh_token",
            "refresh_token": login["refresh_token"],
        }))
        .expect("refresh request");
        let response = client
            .send(request("POST", "/v1/oauth/token", &[], owned_body(refresh)))
            .await;
        assert_eq!(response.status(), hyper::StatusCode::OK, "{name}");
        let body = response
            .into_body()
            .collect()
            .await
            .expect("refresh body")
            .to_bytes();
        let returned: serde_json::Value = serde_json::from_slice(&body).expect("refresh JSON");
        assert!(returned.get("refresh_token").is_none(), "{name}");
        let new_expiry: Option<i64> = sqlx::query_scalar(expiry_query)
            .fetch_one(&mut database)
            .await
            .expect("new expiry");
        let new_expiry = new_expiry.expect("known new expiry");
        if preserves_old {
            assert_eq!(Some(new_expiry), old_expiry, "{name}");
        } else {
            assert!(old_expiry.is_none_or(|old| new_expiry < old), "{name}");
        }
        let now: i64 = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("wall clock")
            .as_secs()
            .try_into()
            .expect("Unix time fits i64");
        let reported = returned["refresh_token_expires_in"]
            .as_i64()
            .expect("reported refresh lifetime");
        assert!((0..=1).contains(&(reported - (new_expiry - now))), "{name}");
        database.close().await.expect("close fixture database");
        server.stop().await;
    }
}

#[tokio::test]
async fn managed_oauth_counts_upstream_delay_against_persisted_and_reported_lifetimes() {
    let ca = TestCa::new();
    let upstream = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::OauthDelayedReply {
            body: br#"{"access_token":"fake-REAL-access","refresh_token":"fake-REAL-refresh","expires_in":4,"refresh_token_expires_in":8}"#,
            delay: Duration::from_millis(1_500),
        },
    )
    .await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let started_at: i64 = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("wall clock")
        .as_secs()
        .try_into()
        .expect("Unix time fits i64");
    let response = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
        ))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::OK);
    let body = response
        .into_body()
        .collect()
        .await
        .expect("login body")
        .to_bytes();
    let login: serde_json::Value = serde_json::from_slice(&body).expect("login JSON");
    let acknowledged_at: i64 = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("wall clock")
        .as_secs()
        .try_into()
        .expect("Unix time fits i64");
    let path = server.directory.path().join("airlock.sqlite3");
    let mut database = SqliteConnection::connect_with(
        &SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(false),
    )
    .await
    .expect("fixture database");
    let (fake_expiry, real_expiry, refresh_expiry): (i64, i64, i64) = sqlx::query_as(
        "SELECT mappings.fake_access_expires_at_unix, tokens.access_expires_at_unix, tokens.refresh_token_expires_at_unix FROM oauth_mappings AS mappings JOIN oauth_tokens AS tokens USING (credential_id)",
    )
    .fetch_one(&mut database)
    .await
    .expect("stored lifetimes");
    assert!(fake_expiry <= started_at + 5);
    assert_eq!(fake_expiry, real_expiry);
    assert!(fake_expiry <= acknowledged_at + 3);
    assert!(refresh_expiry <= acknowledged_at + 7);
    for (name, reported, persisted) in [
        ("access", login["expires_in"].as_i64(), fake_expiry),
        (
            "refresh",
            login["refresh_token_expires_in"].as_i64(),
            refresh_expiry,
        ),
    ] {
        let reported = reported.expect("reported lifetime");
        assert!(
            (0..=1).contains(&(reported - (persisted - acknowledged_at))),
            "{name} lifetime disagrees with storage"
        );
    }
    assert!(login["expires_in"].as_i64().expect("access lifetime") < 4);
    database.close().await.expect("close fixture database");
    server.stop().await;
}

#[tokio::test]
async fn managed_oauth_rejects_a_token_that_expires_during_upstream_response() {
    let ca = TestCa::new();
    let upstream = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::OauthDelayedReply {
            body: br#"{"access_token":"fake-REAL-access","refresh_token":"fake-REAL-refresh","expires_in":1}"#,
            delay: Duration::from_millis(1_200),
        },
    )
    .await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let response = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
        ))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::BAD_GATEWAY);
    let body = response
        .into_body()
        .collect()
        .await
        .expect("rejection body")
        .to_bytes();
    assert!(
        !body
            .windows(b"fake-REAL".len())
            .any(|part| part == b"fake-REAL")
    );
    let path = server.directory.path().join("airlock.sqlite3");
    let mut database = SqliteConnection::connect_with(
        &SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(false),
    )
    .await
    .expect("fixture database");
    let mappings: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM oauth_mappings")
        .fetch_one(&mut database)
        .await
        .expect("stored mapping count");
    assert_eq!(mappings, 0);
    database.close().await.expect("close fixture database");
    server.stop().await;
}

#[tokio::test]
async fn managed_oauth_does_not_acknowledge_a_failed_durable_store() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Oauth).await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let path = server.directory.path().join("airlock.sqlite3");
    let mut database = SqliteConnection::connect_with(
        &SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(false),
    )
    .await
    .expect("fixture database");
    sqlx::query(
        "CREATE TRIGGER deny_fake_insert BEFORE INSERT ON oauth_tokens BEGIN SELECT RAISE(FAIL, 'fake durable failure'); END",
    )
    .execute(&mut database)
    .await
    .expect("install fixture failure");
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let response = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
        ))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::SERVICE_UNAVAILABLE);
    let body = response
        .into_body()
        .collect()
        .await
        .expect("failed store body")
        .to_bytes();
    assert!(
        !body
            .windows(b"fake-REAL".len())
            .any(|bytes| bytes == b"fake-REAL")
    );
    let tokens: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM oauth_tokens")
        .fetch_one(&mut database)
        .await
        .expect("stored token count");
    let mappings: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM oauth_mappings")
        .fetch_one(&mut database)
        .await
        .expect("stored mapping count");
    assert_eq!((tokens, mappings), (0, 0));
    assert_eq!(records(&upstream).len(), 1);
    database.close().await.expect("close fixture database");
    server.stop().await;
}

#[tokio::test]
async fn managed_access_reports_storage_failure_as_unavailable() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Oauth).await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let login = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
        ))
        .await;
    let login = login
        .into_body()
        .collect()
        .await
        .expect("login body")
        .to_bytes();
    let login: serde_json::Value = serde_json::from_slice(&login).expect("login JSON");
    let path = server.directory.path().join("airlock.sqlite3");
    let mut database = SqliteConnection::connect_with(
        &SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(false),
    )
    .await
    .expect("fixture database");
    sqlx::query("DROP TABLE oauth_mappings")
        .execute(&mut database)
        .await
        .expect("break fixture lookup");
    let mut profile = request("GET", "/api/oauth/profile", &[], full_body(b""));
    profile.headers_mut().insert(
        AUTHORIZATION,
        format!(
            "Bearer {}",
            login["access_token"].as_str().expect("fake access")
        )
        .parse()
        .expect("fake header"),
    );
    assert_eq!(
        managed_status(&mut client, profile).await,
        hyper::StatusCode::SERVICE_UNAVAILABLE
    );
    assert_eq!(
        records(&upstream).len(),
        1,
        "no API request reached upstream"
    );
    database.close().await.expect("close fixture database");
    server.stop().await;
}

#[tokio::test]
async fn managed_access_rejects_expired_fake_without_forwarding() {
    let ca = TestCa::new();
    let upstream = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::OauthReply {
            body: br#"{"access_token":"fake-REAL-access","refresh_token":"fake-REAL-refresh","expires_in":1}"#,
            status: hyper::StatusCode::OK,
        },
    )
    .await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let login = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
        ))
        .await;
    let login = login
        .into_body()
        .collect()
        .await
        .expect("login body")
        .to_bytes();
    let login: serde_json::Value = serde_json::from_slice(&login).expect("login JSON");
    tokio::time::sleep(Duration::from_millis(1_100)).await;
    let mut profile = request("GET", "/api/oauth/profile", &[], full_body(b""));
    profile.headers_mut().insert(
        AUTHORIZATION,
        format!(
            "Bearer {}",
            login["access_token"].as_str().expect("fake access")
        )
        .parse()
        .expect("fake header"),
    );
    assert_eq!(
        managed_status(&mut client, profile).await,
        hyper::StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        records(&upstream).len(),
        1,
        "no expired API request reached upstream"
    );
    server.stop().await;
}

#[tokio::test]
async fn managed_access_survives_gateway_restart_with_the_same_fake_mapping() {
    let ca = TestCa::new();
    let first_upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Oauth).await;
    let server = Running::start_managed(ca.roots(), first_upstream.port).await;
    let mut client = HttpClient::connect(&server, first_upstream.port, HttpProtocol::Http1).await;
    let login = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
        ))
        .await;
    let login = login
        .into_body()
        .collect()
        .await
        .expect("login body")
        .to_bytes();
    let login: serde_json::Value = serde_json::from_slice(&login).expect("login JSON");
    let fake_access = login["access_token"].as_str().expect("fake access");
    drop(client);
    let (directory, _) = server.stop_with_directory().await;

    let second_upstream = http_upstream(&ca, HttpProtocol::Http1, UpstreamMode::Oauth).await;
    let server = Running::start_managed_in(directory, ca.roots(), second_upstream.port).await;
    let mut client = HttpClient::connect(&server, second_upstream.port, HttpProtocol::Http1).await;
    let mut profile = request("GET", "/api/oauth/profile", &[], full_body(b""));
    profile.headers_mut().insert(
        AUTHORIZATION,
        format!("Bearer {fake_access}")
            .parse()
            .expect("fake header"),
    );
    assert_eq!(
        managed_status(&mut client, profile).await,
        hyper::StatusCode::OK
    );
    let received = records(&second_upstream);
    assert_eq!(received.len(), 1);
    assert_eq!(
        received[0].headers[AUTHORIZATION],
        "Bearer fake-REAL-access-one"
    );
    server.stop().await;
}

#[tokio::test]
async fn managed_oauth_preserves_upstream_error_code_without_a_mapping() {
    let ca = TestCa::new();
    let upstream = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::OauthReply {
            body: br#"{"error":"invalid_grant","error_description":"fake code rejected"}"#,
            status: hyper::StatusCode::BAD_REQUEST,
        },
    )
    .await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let response = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
        ))
        .await;
    assert_eq!(response.status(), hyper::StatusCode::BAD_REQUEST);
    let body = response
        .into_body()
        .collect()
        .await
        .expect("upstream error body")
        .to_bytes();
    let error: serde_json::Value = serde_json::from_slice(&body).expect("OAuth error JSON");
    assert_eq!(error["error"], "invalid_grant");
    assert!(
        !body
            .windows(b"fake-REAL".len())
            .any(|bytes| bytes == b"fake-REAL")
    );
    server.stop().await;
}

#[tokio::test]
async fn concurrent_managed_refresh_uses_the_real_refresh_token_once() {
    let ca = TestCa::new();
    let upstream = http_upstream(&ca, HttpProtocol::Http2, UpstreamMode::Oauth).await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http2).await;
    let login = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
        ))
        .await;
    let login = login
        .into_body()
        .collect()
        .await
        .expect("login body")
        .to_bytes();
    let login: serde_json::Value = serde_json::from_slice(&login).expect("login JSON");
    let refresh = serde_json::to_vec(&serde_json::json!({
        "grant_type": "refresh_token",
        "refresh_token": login["refresh_token"],
    }))
    .expect("refresh JSON");
    let mut first = client.http2_sender();
    let mut second = client.http2_sender();
    let (first, second) = tokio::join!(
        first.send_request(request(
            "POST",
            "/v1/oauth/token",
            &[],
            owned_body(refresh.clone()),
        )),
        second.send_request(request("POST", "/v1/oauth/token", &[], owned_body(refresh),))
    );
    let statuses = [
        first.expect("first refresh").status(),
        second.expect("second refresh").status(),
    ];
    assert!(statuses.contains(&hyper::StatusCode::OK));
    assert!(statuses.contains(&hyper::StatusCode::UNAUTHORIZED));
    let received = records(&upstream);
    assert_eq!(received.len(), 2, "only one refresh may reach upstream");
    let forwarded: serde_json::Value =
        serde_json::from_slice(&received[1].body).expect("upstream refresh");
    assert_eq!(forwarded["refresh_token"], "fake-REAL-refresh-one");
    server.stop().await;
}

#[tokio::test]
async fn managed_refresh_without_new_refresh_keeps_the_old_fake_and_real_tokens() {
    let ca = TestCa::new();
    let upstream = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::OauthWithoutNewRefresh,
    )
    .await;
    let server = Running::start_managed(ca.roots(), upstream.port).await;
    let mut client = HttpClient::connect(&server, upstream.port, HttpProtocol::Http1).await;
    let login = client
        .send(request(
            "POST",
            "/v1/oauth/token",
            &[],
            full_body(br#"{"grant_type":"authorization_code","code":"fake-code"}"#),
        ))
        .await;
    let login = login
        .into_body()
        .collect()
        .await
        .expect("login body")
        .to_bytes();
    let login: serde_json::Value = serde_json::from_slice(&login).expect("login JSON");
    let old_fake = login["refresh_token"].as_str().expect("fake refresh");
    let mut previous_lifetime = login["refresh_token_expires_in"]
        .as_i64()
        .expect("refresh lifetime");
    let refresh = serde_json::to_vec(&serde_json::json!({
        "grant_type": "refresh_token",
        "refresh_token": old_fake,
    }))
    .expect("refresh JSON");
    for _ in 0..2 {
        let response = client
            .send(request(
                "POST",
                "/v1/oauth/token",
                &[],
                owned_body(refresh.clone()),
            ))
            .await;
        assert_eq!(response.status(), hyper::StatusCode::OK);
        let bytes = response
            .into_body()
            .collect()
            .await
            .expect("refresh body")
            .to_bytes();
        let returned: serde_json::Value = serde_json::from_slice(&bytes).expect("refresh JSON");
        assert!(returned.get("refresh_token").is_none());
        let remaining = returned["refresh_token_expires_in"]
            .as_i64()
            .expect("remaining lifetime");
        assert!(remaining > 0 && remaining <= previous_lifetime);
        previous_lifetime = remaining;
        assert!(
            !bytes
                .windows(b"fake-REAL".len())
                .any(|part| part == b"fake-REAL")
        );
    }
    let forwarded = records(&upstream);
    assert_eq!(forwarded.len(), 3);
    for record in &forwarded[1..] {
        let body: serde_json::Value = serde_json::from_slice(&record.body).expect("forwarded JSON");
        assert_eq!(body["refresh_token"], "fake-REAL-refresh-one");
    }
    server.stop().await;
}

#[derive(Default)]
struct UsageCapture(std::sync::Mutex<Vec<RequestEvent>>);

struct SlowUsageCapture {
    entered: tokio::sync::Semaphore,
    release: tokio::sync::Semaphore,
    blocked_once: std::sync::atomic::AtomicBool,
    events: std::sync::Mutex<Vec<RequestEvent>>,
}

struct FailOnceStorageSink {
    failed: tokio::sync::Semaphore,
    failed_once: std::sync::atomic::AtomicBool,
    storage: Arc<SqliteStorage>,
}

fn gzip_fixture(plain: &[u8]) -> Bytes {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(plain).expect("gzip fixture write");
    Bytes::from(encoder.finish().expect("gzip fixture finish"))
}

impl RequestUsageSink for FailOnceStorageSink {
    fn append_request_event<'a>(
        &'a self,
        event: RequestEvent,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), StorageError>> + Send + 'a>>
    {
        Box::pin(async move {
            if !self.failed_once.swap(true, Ordering::AcqRel) {
                self.failed.add_permits(1);
                return Err(StorageError::UsageUnavailable);
            }
            self.storage.try_append_request_event(event).await
        })
    }
}

impl RequestUsageSink for SlowUsageCapture {
    fn append_request_event<'a>(
        &'a self,
        event: RequestEvent,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), StorageError>> + Send + 'a>>
    {
        Box::pin(async move {
            if !self.blocked_once.swap(true, Ordering::AcqRel) {
                self.entered.add_permits(1);
                let permit = self.release.acquire().await.expect("release slow sink");
                permit.forget();
            }
            self.events.lock().expect("usage lock").push(event);
            Ok(())
        })
    }
}

impl RequestUsageSink for UsageCapture {
    fn append_request_event<'a>(
        &'a self,
        event: RequestEvent,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), StorageError>> + Send + 'a>>
    {
        Box::pin(async move {
            self.0.lock().expect("usage lock").push(event);
            Ok(())
        })
    }
}

#[tokio::test]
async fn primary_headers_do_not_change_zai_usage_attribution_or_body_bytes() {
    const PRIMARY: &[u8] = br#"{"usage":{"input_tokens":2,"output_tokens":3}}"#;
    const ZAI: &[u8] = b"data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":9,\"output_tokens\":1}}}\n\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
    let ca = TestCa::new();
    let primary = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(
            hyper::StatusCode::OK,
            &[("anthropic-ratelimit-unified-status", "allowed")],
            PRIMARY,
        ),
    )
    .await;
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(
            hyper::StatusCode::OK,
            &[
                ("anthropic-ratelimit-unified-status", "rejected"),
                ("content-type", "text/event-stream"),
            ],
            ZAI,
        ),
    )
    .await;
    let usage = Arc::new(UsageCapture::default());
    let server = Running::start_multiplex_with_usage(
        ca.roots(),
        zai.port,
        &format!("https://localhost:{}", primary.port),
        Some(usage.clone()),
    )
    .await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    for (body, expected) in [
        (
            br#"{"model":"claude-sonnet-5","messages":[{"content":"fake-SECRET-prompt"}]}"#
                .as_slice(),
            PRIMARY,
        ),
        (
            br#"{"model":"glm-4.7","messages":[{"content":"fake-SECRET-prompt"}]}"#.as_slice(),
            ZAI,
        ),
    ] {
        let response = client
            .send(request("POST", "/v1/messages", &[], full_body(body)))
            .await;
        assert_eq!(
            response.headers()["anthropic-ratelimit-unified-status"],
            "allowed"
        );
        assert_eq!(
            &response
                .into_body()
                .collect()
                .await
                .expect("response body")
                .to_bytes()[..],
            expected
        );
    }
    drop(client);
    let logs = server.capture.clone();
    server.stop().await;
    let events = usage.0.lock().expect("usage lock");
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].credential.as_ref(), "claude");
    assert_eq!(events[0].output_tokens, Some(3));
    assert_eq!(events[1].credential.as_ref(), "zai");
    assert_eq!(events[1].client.as_ref(), "harness");
    assert_eq!(events[1].model, "glm-4.7");
    assert_eq!(events[1].input_tokens, Some(9));
    assert_eq!(events[1].output_tokens, Some(7));
    assert!(events[1].usage_complete);
    assert!(!logs.text().contains("fake-SECRET-prompt"));
}

#[tokio::test]
async fn gzip_response_bytes_and_headers_survive_with_exact_usage() {
    const JSON: &[u8] = br#"{"usage":{"input_tokens":2,"output_tokens":3,"cache_read_input_tokens":4,"cache_creation_input_tokens":5}}"#;
    const SSE: &[u8] = b"data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":9,\"output_tokens\":1,\"cache_read_input_tokens\":6,\"cache_creation_input_tokens\":7}}}\n\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":11}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
    let json = gzip_fixture(JSON);
    let sse = gzip_fixture(SSE);
    let ca = TestCa::new();
    let primary = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::Encoded {
            body: json.clone(),
            content_type: "application/json",
        },
    )
    .await;
    let zai = http_upstream(
        &ca,
        HttpProtocol::Http1,
        UpstreamMode::Encoded {
            body: sse.clone(),
            content_type: "text/event-stream",
        },
    )
    .await;
    let usage = Arc::new(UsageCapture::default());
    let server = Running::start_multiplex_with_usage(
        ca.roots(),
        zai.port,
        &format!("https://localhost:{}", primary.port),
        Some(usage.clone()),
    )
    .await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    for (request_body, expected) in [
        (br#"{"model":"claude-sonnet-5"}"#.as_slice(), &json),
        (br#"{"model":"glm-4.7"}"#.as_slice(), &sse),
    ] {
        let response = client
            .send(request(
                "POST",
                "/v1/messages",
                &[],
                full_body(request_body),
            ))
            .await;
        assert_eq!(response.headers()["content-encoding"], "gzip");
        assert_eq!(
            response.headers()["content-length"],
            expected.len().to_string()
        );
        assert_eq!(
            response
                .into_body()
                .collect()
                .await
                .expect("encoded response")
                .to_bytes(),
            *expected
        );
    }
    drop(client);
    server.stop().await;
    let events = usage.0.lock().expect("usage lock");
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].credential.as_ref(), "claude");
    assert_eq!(events[0].input_tokens, Some(2));
    assert_eq!(events[0].output_tokens, Some(3));
    assert_eq!(events[0].cache_read_tokens, Some(4));
    assert_eq!(events[0].cache_write_tokens, Some(5));
    assert_eq!(events[0].response_bytes, json.len() as u64);
    assert!(events[0].usage_complete);
    assert_eq!(events[1].credential.as_ref(), "zai");
    assert_eq!(events[1].input_tokens, Some(9));
    assert_eq!(events[1].output_tokens, Some(11));
    assert_eq!(events[1].cache_read_tokens, Some(6));
    assert_eq!(events[1].cache_write_tokens, Some(7));
    assert_eq!(events[1].response_bytes, sse.len() as u64);
    assert!(events[1].usage_complete);
}

#[tokio::test]
async fn stalled_usage_sink_does_not_delay_first_or_last_response_bytes() {
    const BODY: &[u8] = br#"{"usage":{"input_tokens":2,"output_tokens":3}}"#;
    let ca = TestCa::new();
    let primary = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(hyper::StatusCode::OK, &[], BODY),
    )
    .await;
    let slow = Arc::new(SlowUsageCapture {
        entered: tokio::sync::Semaphore::new(0),
        release: tokio::sync::Semaphore::new(0),
        blocked_once: std::sync::atomic::AtomicBool::new(false),
        events: std::sync::Mutex::new(Vec::new()),
    });
    let server = Running::start_multiplex_with_usage(
        ca.roots(),
        primary.port,
        &format!("https://localhost:{}", primary.port),
        Some(slow.clone()),
    )
    .await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    let first = client
        .send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"claude-sonnet-5"}"#),
        ))
        .await;
    assert_eq!(
        &first
            .into_body()
            .collect()
            .await
            .expect("first body")
            .to_bytes()[..],
        BODY
    );
    let permit = timeout(Duration::from_secs(1), slow.entered.acquire())
        .await
        .expect("worker started")
        .expect("entered gate");
    permit.forget();
    let second = timeout(
        Duration::from_secs(1),
        client.send(request(
            "POST",
            "/v1/messages",
            &[],
            full_body(br#"{"model":"claude-sonnet-5"}"#),
        )),
    )
    .await
    .expect("response headers despite blocked sink");
    let mut body = second.into_body();
    let first_frame = timeout(Duration::from_secs(1), body.frame())
        .await
        .expect("first byte despite blocked sink")
        .expect("data frame")
        .expect("body frame")
        .into_data()
        .expect("data");
    assert!(!first_frame.is_empty());
    let rest = timeout(Duration::from_secs(1), body.collect())
        .await
        .expect("last byte and EOF despite blocked sink")
        .expect("body remainder")
        .to_bytes();
    let mut delivered = first_frame.to_vec();
    delivered.extend_from_slice(&rest);
    assert_eq!(delivered, BODY);
    slow.release.add_permits(1);
    drop(client);
    server.stop().await;
    assert_eq!(slow.events.lock().expect("usage lock").len(), 2);
}

#[tokio::test]
async fn failed_write_is_persisted_as_global_loss_on_next_request() {
    const BODY: &[u8] = br#"{"content":[{"text":"fake-SECRET-response"}],"usage":{"input_tokens":2,"output_tokens":3}}"#;
    let state = tempfile::tempdir().expect("private state");
    fs::set_permissions(state.path(), fs::Permissions::from_mode(0o700))
        .expect("private state mode");
    let storage = Arc::new(
        SqliteStorage::open(state.path(), usage_storage_identities())
            .await
            .expect("storage"),
    );
    let sink = Arc::new(FailOnceStorageSink {
        failed: tokio::sync::Semaphore::new(0),
        failed_once: std::sync::atomic::AtomicBool::new(false),
        storage: storage.clone(),
    });
    let ca = TestCa::new();
    let primary = http_upstream(
        &ca,
        HttpProtocol::Http1,
        quota_mode(hyper::StatusCode::OK, &[], BODY),
    )
    .await;
    let server = Running::start_multiplex_with_usage(
        ca.roots(),
        primary.port,
        &format!("https://localhost:{}", primary.port),
        Some(sink.clone()),
    )
    .await;
    let mut client = HttpClient::connect(&server, primary.port, HttpProtocol::Http1).await;
    for index in 0..2 {
        let response = client
            .send(request(
                "POST",
                "/v1/messages",
                &[],
                full_body(
                    br#"{"model":"claude-sonnet-5","messages":[{"content":"fake-SECRET-prompt","tool_args":"fake-SECRET-tool-args"}]}"#,
                ),
            ))
            .await;
        assert_eq!(
            &response
                .into_body()
                .collect()
                .await
                .expect("response body")
                .to_bytes()[..],
            BODY
        );
        if index == 0 {
            let permit = timeout(Duration::from_secs(1), sink.failed.acquire())
                .await
                .expect("injected failure observed")
                .expect("failure gate");
            permit.forget();
        }
    }
    drop(client);
    let logs = server.capture.clone();
    server.stop().await;
    assert_eq!(
        storage
            .request_usage_loss_total()
            .await
            .expect("global loss total"),
        1
    );
    let rows = storage
        .request_usage(RequestUsageQuery {
            bucket_seconds: NonZeroU64::new(60).expect("bucket"),
            group: GroupId::try_from("anthropic").expect("group"),
            since_unix: 1,
            until_unix: i64::MAX,
        })
        .await
        .expect("usage aggregate");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].events, 1);
    assert_eq!(rows[0].outcome, RequestOutcome::Completed);
    assert_eq!(rows[0].input_tokens, Some(2));
    for marker in [
        "fake-SECRET-prompt",
        "fake-SECRET-response",
        "fake-SECRET-tool-args",
    ] {
        assert!(!logs.text().contains(marker));
    }
    assert_no_content_in_state(state.path());
    drop(sink);
    Arc::try_unwrap(storage)
        .unwrap_or_else(|_| panic!("storage still shared"))
        .close()
        .await
        .expect("close storage");
}

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

fn usage_storage_identities() -> StorageIdentities {
    let client = ClientId::try_from("harness").expect("client");
    let credential = CredentialId::try_from("claude").expect("credential");
    let group = GroupId::try_from("anthropic").expect("group");
    let provider = ProviderId::try_from("claude").expect("provider");
    StorageIdentities {
        clients: BTreeSet::from([client]),
        credentials: BTreeMap::from([(credential.clone(), provider.clone())]),
        group_members: BTreeSet::from([(group.clone(), credential)]),
        groups: BTreeSet::from([group]),
        inserted_at_unix: 1,
        providers: BTreeSet::from([provider]),
    }
}

fn assert_no_content_in_state(directory: &std::path::Path) {
    for filename in [
        "airlock.sqlite3",
        "airlock.sqlite3-wal",
        "airlock.sqlite3-shm",
    ] {
        let path = directory.join(filename);
        if path.exists() {
            let bytes = fs::read(path).expect("state bytes");
            for marker in [
                b"fake-SECRET-prompt".as_slice(),
                b"fake-SECRET-response",
                b"fake-SECRET-tool-args",
            ] {
                assert!(!bytes.windows(marker.len()).any(|window| window == marker));
            }
        }
    }
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
    let usage = Arc::new(UsageCapture::default());
    let server = Running::start_multiplex_with_usage(
        ca.roots(),
        zai.port,
        &format!("https://localhost:{}", primary.port),
        Some(usage.clone()),
    )
    .await;
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
    let events = usage.0.lock().expect("usage lock");
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].credential.as_ref(), "zai");
    assert_eq!(events[0].input_tokens, None);
    assert_eq!(events[0].output_tokens, Some(5));
    assert!(events[0].usage_complete);
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
    let usage = Arc::new(UsageCapture::default());
    let server = Running::start_multiplex_with_usage(
        ca.roots(),
        zai.port,
        &format!("https://localhost:{}", primary.port),
        Some(usage.clone()),
    )
    .await;
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
    let tokens = timeout(Duration::from_secs(2), response.body_mut().frame())
        .await
        .expect("usage deadline")
        .expect("usage event")
        .expect("usage frame")
        .into_data()
        .expect("usage data");
    assert!(
        tokens
            .windows(b"\"output_tokens\":7".len())
            .any(|part| part == b"\"output_tokens\":7")
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
    primary_response
        .into_body()
        .collect()
        .await
        .expect("primary response");
    assert_eq!(records(&primary).len(), 1);
    drop(client);
    server.stop().await;
    let events = usage.0.lock().expect("usage lock");
    let cancelled = events
        .iter()
        .find(|event| event.credential.as_ref() == "zai")
        .expect("z.ai usage event");
    assert_eq!(cancelled.outcome, RequestOutcome::Cancelled);
    assert_eq!(cancelled.output_tokens, Some(7));
    assert!(!cancelled.usage_complete);
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
