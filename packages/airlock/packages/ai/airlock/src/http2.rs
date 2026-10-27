//! Cleartext HTTP/2 connections. `serve` accepts streams up to a limit and
//! runs each as a job: a CONNECT stream becomes a tunnel carried by
//! `TunnelIo`, and any other request gets Airlock's own reply.
use std::{
    future::poll_fn,
    io,
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll},
};

use h2::{
    RecvStream, SendStream,
    server::{Connection, SendResponse},
};
use hyper::{Method, Request, Response, StatusCode, body::Bytes};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    sync::Notify,
    task::JoinSet,
    time::{Instant, timeout_at},
};

use crate::{
    detect::Prefixed,
    first_request::until_first_request,
    local::{response, route},
    proxy::Proxy,
    tunnel,
    upstream::CONNECT_TIMEOUT,
};

const MAX_STREAMS: usize = 32;
// Bytes sent to the client per DATA frame; bounds each copy and the window
// reserved for it.
const MAX_FRAME_CHUNK: usize = 8192;

pub(crate) async fn serve(socket: Prefixed, deadline: Instant, proxy: Arc<Proxy>) {
    let handshake = h2::server::Builder::new()
        .max_concurrent_streams(MAX_STREAMS as u32)
        .handshake::<_, Bytes>(socket);
    let Ok(Ok(connection)) = timeout_at(deadline, handshake).await else {
        return;
    };
    let started = Notify::new();
    until_first_request(
        &started,
        deadline,
        accept_streams(connection, proxy, &started),
    )
    .await;
}

/// Run each accepted stream as a job until the client closes the connection.
async fn accept_streams(
    mut connection: Connection<Prefixed, Bytes>,
    proxy: Arc<Proxy>,
    started: &Notify,
) {
    let mut jobs = JoinSet::new();
    loop {
        let available = jobs.len() < MAX_STREAMS;
        tokio::select! {
            biased;
            _ = jobs.join_next(), if !jobs.is_empty() => {}
            accepted = poll_fn(|cx| {
                if available { connection.poll_accept(cx) } else {
                    // Continue driving reset/flow-control frames while every
                    // owned job slot is occupied; defer only accepting jobs.
                    match connection.poll_closed(cx) {
                        Poll::Ready(Ok(())) => Poll::Ready(None),
                        Poll::Ready(Err(error)) => Poll::Ready(Some(Err(error))),
                        Poll::Pending => Poll::Pending,
                    }
                }
            }) => match accepted {
                Some(Ok((request, respond))) => {
                    started.notify_one();
                    jobs.spawn(handle(request, respond, Arc::clone(&proxy)));
                }
                _ => break,
            }
        }
    }
    jobs.shutdown().await;
}

async fn handle(request: Request<RecvStream>, mut respond: SendResponse<Bytes>, proxy: Arc<Proxy>) {
    if request.method() != Method::CONNECT {
        let (status, body) = route(request.method(), request.uri());
        let _ = reply(&mut respond, status, body);
        return;
    }
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    let prepared = tokio::select! {
        biased;
        _ = poll_fn(|cx| respond.poll_reset(cx)) => return,
        result = tunnel::prepare(request.uri(), deadline, proxy.interceptor.as_ref()) => result,
    };
    let action = match prepared {
        Ok(action) => action,
        Err((status, body)) => {
            let _ = reply(&mut respond, status, body);
            return;
        }
    };
    let Ok(send) = respond.send_response(Response::new(()), false) else {
        return;
    };
    let send = Arc::new(Mutex::new(send));
    let reset = Arc::clone(&send);
    // Watch for a client reset even after the relay ends our side with
    // END_STREAM, or while either copy is blocked.
    tokio::select! {
        biased;
        _ = poll_fn(|cx| reset.lock().unwrap().poll_reset(cx)) => {}
        _ = action.relay(TunnelIo::new(request.into_body(), send)) => {}
    }
}

fn reply(
    respond: &mut SendResponse<Bytes>,
    status: StatusCode,
    body: &'static str,
) -> Result<(), h2::Error> {
    let (head, _) = response(status, body).into_parts();
    let mut send = respond.send_response(Response::from_parts(head, ()), body.is_empty())?;
    if !body.is_empty() {
        send.send_data(Bytes::from_static(body.as_bytes()), true)?;
    }
    Ok(())
}

/// One CONNECT stream as a byte stream: reads take the client's DATA frames,
/// and writes send DATA frames back within the stream's flow-control window.
struct TunnelIo {
    recv: RecvStream,
    // Shared with `handle`, which watches the same stream for a reset.
    send: Arc<Mutex<SendStream<Bytes>>>,
    buffered: Bytes,
    ended: bool,
}

impl TunnelIo {
    fn new(recv: RecvStream, send: Arc<Mutex<SendStream<Bytes>>>) -> Self {
        Self {
            recv,
            send,
            buffered: Bytes::new(),
            ended: false,
        }
    }
}

impl AsyncRead for TunnelIo {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        output: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if output.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        loop {
            if !self.buffered.is_empty() {
                let count = output.remaining().min(self.buffered.len());
                output.put_slice(&self.buffered.split_to(count));
                // Open the client's window only for bytes handed on, so a slow
                // upstream slows the client instead of growing this buffer.
                self.recv
                    .flow_control()
                    .release_capacity(count)
                    .map_err(io::Error::other)?;
                return Poll::Ready(Ok(()));
            }
            match self.recv.poll_data(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(None) => return Poll::Ready(Ok(())),
                Poll::Ready(Some(Err(error))) => return Poll::Ready(Err(io::Error::other(error))),
                Poll::Ready(Some(Ok(bytes))) => self.buffered = bytes,
            }
        }
    }
}

impl AsyncWrite for TunnelIo {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        if bytes.is_empty() {
            return Poll::Ready(Ok(0));
        }
        let mut send = self.send.lock().unwrap();
        send.reserve_capacity(bytes.len().min(MAX_FRAME_CHUNK));
        match send.poll_capacity(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(None) => Poll::Ready(Err(io::ErrorKind::BrokenPipe.into())),
            Poll::Ready(Some(Err(error))) => Poll::Ready(Err(io::Error::other(error))),
            Poll::Ready(Some(Ok(capacity))) => {
                let count = capacity.min(bytes.len()).min(MAX_FRAME_CHUNK);
                send.send_data(Bytes::copy_from_slice(&bytes[..count]), false)
                    .map_err(io::Error::other)?;
                Poll::Ready(Ok(count))
            }
        }
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    // The upstream's FIN becomes END_STREAM; the client can keep sending.
    fn poll_shutdown(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        if !self.ended {
            self.send
                .lock()
                .unwrap()
                .send_data(Bytes::new(), true)
                .map_err(io::Error::other)?;
            self.ended = true;
        }
        Poll::Ready(Ok(()))
    }
}
