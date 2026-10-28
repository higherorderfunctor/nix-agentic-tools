//! HTTP/1.1 connections. hyper reads each request and `handle` answers it.
//! Once a CONNECT is accepted, `serve` runs its tunnel on this connection's
//! task after hyper hands over the raw socket.
use std::{convert::Infallible, io, os::fd::AsFd, time::Duration};

use http_body_util::Full;
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Bytes, Incoming},
    server::conn::http1,
    service::service_fn,
    upgrade::OnUpgrade,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::{io::Interest, net::TcpStream, sync::mpsc, time::Instant};

use crate::{
    client::replies::{response, route},
    tunnel,
    upstream::CONNECT_TIMEOUT,
};

pub(crate) async fn serve(socket: TcpStream, header_timeout: Duration) {
    let Ok(monitor) = error_monitor(&socket) else {
        return;
    };
    // The service must return the `200` before the client socket is upgraded,
    // so it cannot run the relay itself. It sends the pending tunnel back here.
    let (sender, mut receiver) = mpsc::channel(1);
    let service = service_fn(move |request| handle(request, sender.clone()));
    let result = http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(header_timeout)
        .serve_connection(TokioIo::new(socket), service)
        .with_upgrades()
        .await;
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
    upstream: TcpStream,
}

impl PendingTunnel {
    // `serve` awaits this future instead of spawning it, so a live tunnel
    // still counts against the connection limit and gets the same shutdown
    // grace, then abort, as any other connection.
    async fn relay(self) -> io::Result<()> {
        let upgraded = self.upgrade.await.map_err(io::Error::other)?;
        tunnel::relay(TokioIo::new(upgraded), self.upstream).await
    }
}

async fn open_tunnel(
    mut request: Request<Incoming>,
    deadline: Instant,
) -> Result<PendingTunnel, (StatusCode, &'static str)> {
    let upstream = tunnel::prepare(request.uri(), deadline).await?;
    Ok(PendingTunnel {
        upgrade: hyper::upgrade::on(&mut request),
        upstream,
    })
}

async fn handle(
    request: Request<Incoming>,
    sender: mpsc::Sender<PendingTunnel>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    if request.method() == Method::CONNECT {
        let deadline = Instant::now() + CONNECT_TIMEOUT;
        let pending = match open_tunnel(request, deadline).await {
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
