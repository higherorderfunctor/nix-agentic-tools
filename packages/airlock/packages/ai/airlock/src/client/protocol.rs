//! Protocol detection on a new client connection. `detect` reads just enough
//! bytes to tell an HTTP/2 prior-knowledge preface from HTTP/1, and `Prefixed`
//! replays those bytes to whichever protocol driver takes the socket.
use std::{
    io,
    pin::Pin,
    task::{Context, Poll},
};

use hyper::body::Bytes;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, ReadBuf},
    net::TcpStream,
};

const H2_PREFACE: &[u8; 24] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// A client socket with the bytes `detect` already read put back in front.
pub(crate) struct Prefixed {
    prefix: Bytes,
    socket: TcpStream,
}

/// Read until the bytes differ from the HTTP/2 preface or complete it, and
/// report whether they completed it.
pub(crate) async fn detect(mut socket: TcpStream) -> io::Result<(Prefixed, bool)> {
    let mut bytes = [0; 24];
    let mut filled = 0;
    while filled < bytes.len() {
        let count = socket.read(&mut bytes[filled..]).await?;
        if count == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        filled += count;
        // Stop at the first byte that rules HTTP/2 out, so an HTTP/1 request
        // shorter than the preface is not left waiting for more bytes.
        if bytes[..filled] != H2_PREFACE[..filled] {
            break;
        }
    }
    let http2 = filled == bytes.len() && bytes == *H2_PREFACE;
    let socket = Prefixed {
        prefix: Bytes::copy_from_slice(&bytes[..filled]),
        socket,
    };
    Ok((socket, http2))
}

impl Prefixed {
    pub(crate) fn socket(&self) -> &TcpStream {
        &self.socket
    }
}

impl AsyncRead for Prefixed {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if !self.prefix.is_empty() {
            let count = self.prefix.len().min(buffer.remaining());
            buffer.put_slice(&self.prefix.split_to(count));
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut self.socket).poll_read(cx, buffer)
    }
}

impl AsyncWrite for Prefixed {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.socket).poll_write(cx, bytes)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_shutdown(cx)
    }
}
