//! HTTP/1.1 connections. hyper reads each request and `handle` answers it.
//! Once a CONNECT is accepted, `serve` runs its tunnel on this connection's
//! task after hyper hands over the raw socket.
use std::{convert::Infallible, io, os::fd::AsFd, sync::Arc, time::Duration};

use hyper::{
    Method, Request, StatusCode, body::Incoming, server::conn::http1, service::service_fn,
    upgrade::OnUpgrade,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::{
    io::Interest,
    net::TcpStream,
    sync::{Notify, mpsc},
    time::Instant,
};

use crate::{
    client::{
        protocol::Prefixed,
        replies::{response, route},
        until_first_request,
    },
    gateway::{self, Gateway, Reply},
    tunnel,
    upstream::CONNECT_TIMEOUT,
};

pub(crate) async fn serve(
    socket: Prefixed,
    deadline: Instant,
    header_timeout: Duration,
    gateway: Option<Arc<Gateway>>,
) {
    let Ok(monitor) = error_monitor(socket.socket()) else {
        return;
    };
    // The service must return the `200` before the client socket is upgraded,
    // so it cannot run the relay itself. It sends the pending tunnel back here.
    let (sender, mut receiver) = mpsc::channel(1);
    let started = Arc::new(Notify::new());
    let observed = Arc::clone(&started);
    let service = service_fn(move |request| {
        observed.notify_one();
        handle(request, sender.clone(), gateway.clone())
    });
    let connection = http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(header_timeout)
        .serve_connection(TokioIo::new(socket), service)
        .with_upgrades();
    let Some(result) = until_first_request(&started, deadline, connection).await else {
        return;
    };
    if result.is_ok()
        && let Some(pending) = receiver.recv().await
    {
        // A relay blocked writing to a slow upstream stops reading the client,
        // so a client reset must end it here too.
        tokio::select! {
            _ = pending.relay() => {},
            () = transport_error(&monitor) => {},
        }
    }
}

/// A second handle on the client socket that only watches for transport
/// errors while hyper owns the first.
fn error_monitor(socket: &TcpStream) -> io::Result<TcpStream> {
    let duplicate = socket.as_fd().try_clone_to_owned()?;
    TcpStream::from_std(std::net::TcpStream::from(duplicate))
}

// A plain FIN is not an error: it stays a half-close.
async fn transport_error(monitor: &TcpStream) {
    while monitor
        .ready(Interest::ERROR)
        .await
        .is_ok_and(|ready| !ready.is_error())
    {}
}

/// An accepted CONNECT waiting for hyper to hand over the client socket.
struct PendingTunnel {
    upgrade: OnUpgrade,
    prepared: tunnel::Prepared,
}

impl PendingTunnel {
    // `serve` awaits this future instead of spawning it, so a live tunnel
    // still counts against the connection limit and gets the same shutdown
    // grace, then abort, as any other connection.
    async fn relay(self) -> io::Result<()> {
        let upgraded = self.upgrade.await.map_err(io::Error::other)?;
        tunnel::relay(TokioIo::new(upgraded), self.prepared).await
    }
}

async fn open_tunnel(
    mut request: Request<Incoming>,
    gateway: Option<Arc<Gateway>>,
    deadline: Instant,
) -> Result<PendingTunnel, (StatusCode, &'static str)> {
    let prepared = tunnel::prepare(request.uri(), request.headers(), gateway, deadline).await?;
    Ok(PendingTunnel {
        upgrade: hyper::upgrade::on(&mut request),
        prepared,
    })
}

async fn handle(
    request: Request<Incoming>,
    sender: mpsc::Sender<PendingTunnel>,
    gateway: Option<Arc<Gateway>>,
) -> Result<Reply, Infallible> {
    if request.method() == Method::CONNECT {
        let deadline = Instant::now() + CONNECT_TIMEOUT;
        let pending = match open_tunnel(request, gateway, deadline).await {
            Ok(pending) => pending,
            Err((status, body)) => return gateway::reply(status, body),
        };
        if sender.send(pending).await.is_err() {
            return gateway::reply(
                StatusCode::INTERNAL_SERVER_ERROR,
                "tunnel connection closed\n",
            );
        }
        return gateway::reply(StatusCode::OK, "");
    }
    if let Some(gateway) = gateway
        && matches!(request.uri().path(), "/v1/messages" | "/v1/passthrough")
    {
        return gateway.explicit(request).await;
    }
    let (status, body) = route(request.method(), request.uri());
    Ok(gateway::local(response(status, body)))
}
