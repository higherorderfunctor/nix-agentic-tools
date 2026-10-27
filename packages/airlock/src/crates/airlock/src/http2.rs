use std::{
    future::poll_fn,
    io,
    sync::{Arc, Mutex},
    task::Poll,
};

use h2::{RecvStream, SendStream, server::SendResponse};
use hyper::{Method, Request, Response, StatusCode, body::Bytes};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    task::JoinSet,
    time::{Instant, sleep_until, timeout_at},
};

use crate::{
    server::{self, Prefixed},
    tunnel,
};

const MAX_STREAMS: usize = 32;

pub(crate) async fn serve(socket: Prefixed, deadline: Instant) {
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
                    jobs.spawn(handle(request, respond));
                }
                _ => break,
            }
        }
    }
    jobs.shutdown().await;
}

async fn handle(request: Request<RecvStream>, mut respond: SendResponse<Bytes>) {
    if request.method() != Method::CONNECT {
        let (status, body) = server::route(request.method(), request.uri());
        let _ = reply(&mut respond, status, body);
        return;
    }
    let deadline = Instant::now() + tunnel::CONNECT_TIMEOUT;
    let opened = tokio::select! {
        biased;
        _ = poll_fn(|cx| respond.poll_reset(cx)) => return,
        result = tunnel::open(request.uri(), deadline) => result,
    };
    let upstream = match opened {
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
        _ = relay(request.into_body(), send, upstream) => {}
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

async fn relay(
    mut recv: RecvStream,
    send: Arc<Mutex<SendStream<Bytes>>>,
    upstream: TcpStream,
) -> io::Result<()> {
    let (mut read, mut write) = upstream.into_split();
    let upload = async {
        while let Some(data) = recv.data().await {
            let data = data.map_err(io::Error::other)?;
            write.write_all(&data).await?;
            recv.flow_control()
                .release_capacity(data.len())
                .map_err(io::Error::other)?;
        }
        write.shutdown().await
    };
    let download = async {
        let mut buffer = [0; 8192];
        loop {
            let count = read.read(&mut buffer).await?;
            if count == 0 {
                send.lock()
                    .unwrap()
                    .send_data(Bytes::new(), true)
                    .map_err(io::Error::other)?;
                return Ok::<(), io::Error>(());
            }
            let mut bytes = Bytes::copy_from_slice(&buffer[..count]);
            while !bytes.is_empty() {
                send.lock().unwrap().reserve_capacity(bytes.len());
                let capacity = poll_fn(|cx| send.lock().unwrap().poll_capacity(cx))
                    .await
                    .ok_or(io::ErrorKind::BrokenPipe)?
                    .map_err(io::Error::other)?;
                let count = capacity.min(bytes.len());
                send.lock()
                    .unwrap()
                    .send_data(bytes.split_to(count), false)
                    .map_err(io::Error::other)?;
            }
        }
    };
    tokio::try_join!(upload, download)?;
    Ok(())
}
