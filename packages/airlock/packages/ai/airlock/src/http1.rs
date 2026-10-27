//! HTTP/1.1 connections. hyper reads each request and `handle` answers it.
//! Once a CONNECT is accepted, `serve` runs its tunnel on this connection's
//! task after hyper hands over the raw socket.
use std::{convert::Infallible, sync::Arc};

use http_body_util::Either;
use hyper::{
    Method, Request, StatusCode, body::Incoming, server::conn::http1, service::service_fn,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::{
    io::Interest,
    net::TcpStream,
    sync::{Notify, mpsc},
    time::{Instant, sleep_until},
};

use crate::{
    server::{HEADER_TIMEOUT, Prefixed, response, route},
    tunnel::{self, PendingTunnel},
    upstream::CONNECT_TIMEOUT,
};

pub(crate) async fn serve(
    socket: Prefixed,
    deadline: Instant,
    interception: Option<Arc<crate::tls::Interception>>,
    clients: Arc<crate::auth::Clients>,
) {
    let Prefixed { prefix, socket } = socket;
    let Ok(socket) = socket.into_std() else {
        return;
    };
    let Ok(monitor) = socket.try_clone().and_then(TcpStream::from_std) else {
        return;
    };
    let Ok(socket) = TcpStream::from_std(socket) else {
        return;
    };
    let socket = Prefixed { prefix, socket };
    // The service must return the `200` before the client socket is upgraded,
    // so it cannot run the relay itself. It sends the pending tunnel back here.
    let (sender, mut receiver) = mpsc::channel(1);
    let forwarder = crate::forward::Forwarder::new();
    let started = Arc::new(Notify::new());
    let observed = Arc::clone(&started);
    let service = service_fn(move |request| {
        observed.notify_one();
        handle(
            request,
            sender.clone(),
            forwarder.clone(),
            interception.clone(),
            clients.clone(),
        )
    });
    let result = {
        let driver = http1::Builder::new()
            .timer(TokioTimer::new())
            .header_read_timeout(HEADER_TIMEOUT)
            .serve_connection(TokioIo::new(socket), service)
            .with_upgrades();
        tokio::pin!(driver);
        let initial = async {
            Some(tokio::select! {
                biased;
                _ = started.notified() => (&mut driver).await,
                result = &mut driver => result,
                _ = sleep_until(deadline) => return None,
            })
        };
        // Hyper can stop reading while a pipelined request is buffered. Watch
        // transport errors independently; a plain FIN remains a half-close.
        tokio::select! {
            result = initial => result,
            () = transport_error(&monitor) => return,
        }
    };

    let Some(result) = result else {
        return;
    };
    if result.is_ok()
        && let Some(pending) = receiver.recv().await
    {
        tokio::select! {
            _ = pending.relay() => {},
            _ = transport_error(&monitor) => {},
        }
    }
}

async fn transport_error(monitor: &TcpStream) {
    loop {
        match monitor.ready(Interest::ERROR).await {
            Ok(ready) if !ready.is_error() => continue,
            _ => break,
        }
    }
}

async fn handle(
    mut request: Request<Incoming>,
    sender: mpsc::Sender<PendingTunnel>,
    forwarder: crate::forward::Forwarder,
    interception: Option<Arc<crate::tls::Interception>>,
    clients: Arc<crate::auth::Clients>,
) -> Result<crate::forward::ProxyResponse, Infallible> {
    let proxy = request.method() == Method::CONNECT
        || request.uri().scheme().is_some()
        || request.uri().authority().is_some();
    if proxy && clients.admit(&mut request).is_err() {
        return Ok(response(
            StatusCode::PROXY_AUTHENTICATION_REQUIRED,
            "proxy authentication required\n",
        )
        .map(Either::Left));
    }
    if request.method() == Method::CONNECT {
        let deadline = Instant::now() + CONNECT_TIMEOUT;
        // An opaque tunnel's upstream is already connected when this returns,
        // so the client gets `200` only for a tunnel that can carry bytes.
        let pending = match tunnel::open_tunnel(request, deadline, interception).await {
            Ok(pending) => pending,
            Err((status, body)) => return Ok(response(status, body).map(Either::Left)),
        };
        if sender.send(pending).await.is_err() {
            return Ok(response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "tunnel connection closed\n",
            )
            .map(Either::Left));
        }
        return Ok(response(StatusCode::OK, "").map(Either::Left));
    }
    if request.uri().scheme().is_some() || request.uri().authority().is_some() {
        return Ok(forwarder.forward(request).await);
    }
    let (status, body) = route(request.method(), request.uri());
    Ok(response(status, body).map(Either::Left))
}
