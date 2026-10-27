//! TCP connections from airlock to upstream servers. `connect_upstream`
//! connects to an IP address directly and looks a name up through `resolver`
//! first. It sets no deadline of its own; callers bound it with
//! `CONNECT_TIMEOUT`.
use std::{io, net::IpAddr, time::Duration};

use tokio::net::TcpStream;

pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

pub(crate) async fn connect_upstream(host: String, port: u16) -> io::Result<TcpStream> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return TcpStream::connect((ip, port)).await;
    }
    let addresses = crate::resolver::lookup(host, port).await?;
    TcpStream::connect(addresses.as_slice()).await
}
