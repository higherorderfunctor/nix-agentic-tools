use std::{
    future::poll_fn,
    io,
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll},
};

use h2::{RecvStream, SendStream, server::SendResponse};
use hyper::{Method, Request, Response, StatusCode, body::Bytes};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    task::JoinSet,
    time::{Instant, sleep_until, timeout_at},
};

use crate::{
    server::{self, Prefixed},
    tunnel,
};

const MAX_STREAMS: usize = 32;

pub(crate) async fn serve(
    socket: Prefixed,
    deadline: Instant,
    interception: Option<Arc<crate::tls::Interception>>,
    clients: Arc<crate::auth::Clients>,
) {
    let handshake = h2::server::Builder::new()
        .max_concurrent_streams(MAX_STREAMS as u32)
        .handshake::<_, Bytes>(socket);
    let Ok(Ok(mut connection)) = timeout_at(deadline, handshake).await else {
        return;
    };
    let mut jobs = JoinSet::new();
    let mut initializing = true;
    let initial_deadline = sleep_until(deadline);
    tokio::pin!(initial_deadline);
    loop {
        let available = jobs.len() < MAX_STREAMS;
        tokio::select! {
            biased;
            _ = &mut initial_deadline, if initializing => break,
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
                    initializing = false;
                    jobs.spawn(handle(request, respond, interception.clone(), clients.clone()));
                }
                _ => break,
            }
        }
    }
    jobs.shutdown().await;
}

async fn handle(
    mut request: Request<RecvStream>,
    mut respond: SendResponse<Bytes>,
    interception: Option<Arc<crate::tls::Interception>>,
    clients: Arc<crate::auth::Clients>,
) {
    if request.method() != Method::CONNECT {
        let (status, body) = server::route(request.method(), request.uri());
        let _ = reply(&mut respond, status, body);
        return;
    }
    if clients.admit(&mut request).is_err() {
        let _ = reply(
            &mut respond,
            StatusCode::PROXY_AUTHENTICATION_REQUIRED,
            "proxy authentication required\n",
        );
        return;
    }
    let deadline = Instant::now() + tunnel::CONNECT_TIMEOUT;
    let opened = tokio::select! {
        biased;
        _ = poll_fn(|cx| respond.poll_reset(cx)) => return,
        result = tunnel::prepare(request.uri(), deadline, interception) => result,
    };
    let action = match opened {
        Ok(upstream) => upstream,
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
    // Keep the send handle after response END_STREAM. poll_reset remains an
    // independent cancellation source even when either copy is blocked.
    tokio::select! {
        biased;
        _ = poll_fn(|cx| reset.lock().unwrap().poll_reset(cx)) => {}
        _ = action.relay(TunnelIo { recv: request.into_body(), send, buffered: Bytes::new(), ended: false }) => {}
    }
}

fn reply(
    respond: &mut SendResponse<Bytes>,
    status: StatusCode,
    body: &'static str,
) -> Result<(), h2::Error> {
    let (head, _) = server::response(status, body).into_parts();
    let mut send = respond.send_response(Response::from_parts(head, ()), body.is_empty())?;
    if !body.is_empty() {
        send.send_data(Bytes::from_static(body.as_bytes()), true)?;
    }
    Ok(())
}

struct TunnelIo {
    recv: RecvStream,
    send: Arc<Mutex<SendStream<Bytes>>>,
    buffered: Bytes,
    ended: bool,
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
        send.reserve_capacity(bytes.len().min(8192));
        match send.poll_capacity(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(None) => Poll::Ready(Err(io::ErrorKind::BrokenPipe.into())),
            Poll::Ready(Some(Err(error))) => Poll::Ready(Err(io::Error::other(error))),
            Poll::Ready(Some(Ok(capacity))) => {
                let count = capacity.min(bytes.len()).min(8192);
                send.send_data(Bytes::copy_from_slice(&bytes[..count]), false)
                    .map_err(io::Error::other)?;
                Poll::Ready(Ok(count))
            }
        }
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
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
