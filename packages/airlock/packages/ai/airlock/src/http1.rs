//! HTTP/1.1 connections. hyper reads each request and `handle` answers it.
//! Once a CONNECT is accepted, `serve` runs its tunnel on this connection's
//! task after hyper hands over the raw socket.
use std::{convert::Infallible, sync::Arc};

use http_body_util::Full;
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Bytes, Incoming},
    server::conn::http1,
    service::service_fn,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::{
    sync::{Notify, mpsc},
    time::{Instant, sleep_until},
};

use crate::{
    server::{HEADER_TIMEOUT, Prefixed, response, route},
    tunnel::{self, PendingTunnel},
    upstream::CONNECT_TIMEOUT,
};

pub(crate) async fn serve(socket: Prefixed, deadline: Instant) {
    // The service must return the `200` before the client socket is upgraded,
    // so it cannot run the relay itself. It sends the pending tunnel back here.
    let (sender, mut receiver) = mpsc::channel(1);
    let started = Arc::new(Notify::new());
    let observed = Arc::clone(&started);
    let service = service_fn(move |request| {
        observed.notify_one();
        handle(request, sender.clone())
    });
    let result = {
        let driver = http1::Builder::new()
            .timer(TokioTimer::new())
            .header_read_timeout(HEADER_TIMEOUT)
            .serve_connection(TokioIo::new(socket), service)
            .with_upgrades();
        tokio::pin!(driver);
        let result = tokio::select! {
            biased;
            _ = started.notified() => (&mut driver).await,
            result = &mut driver => result,
            _ = sleep_until(deadline) => return,
        };
        result
    };
    if result.is_ok()
        && let Some(pending) = receiver.recv().await
    {
        let _ = pending.relay().await;
    }
}

async fn handle(
    request: Request<Incoming>,
    sender: mpsc::Sender<PendingTunnel>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    if request.method() == Method::CONNECT {
        let deadline = Instant::now() + CONNECT_TIMEOUT;
        // The upstream is already connected when this returns, so the client
        // gets `200` only for a tunnel that can carry bytes.
        let pending = match tunnel::open_tunnel(request, deadline).await {
            Ok(pending) => pending,
            Err((status, body)) => return Ok(response(status, body)),
        };
        if sender.send(pending).await.is_err() {
            return Ok(response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "tunnel connection closed\n",
            ));
        }
        return Ok(response(StatusCode::OK, ""));
    }
    let (status, body) = route(request.method(), request.uri());
    Ok(response(status, body))
}
