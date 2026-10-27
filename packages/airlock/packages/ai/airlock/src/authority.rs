use std::net::{IpAddr, Ipv6Addr};

use hyper::http::uri::Authority;

/// Split `host:port` into a lowercase host and a nonzero port, using
/// `default_port` when the port is absent. IPv6 hosts come back without their
/// brackets.
pub(crate) fn parse(input: &str, default_port: Option<u16>) -> Option<(String, u16)> {
    let authority = input.parse::<Authority>().ok()?;
    // http drops the `user@` prefix from `host()`; refuse `user@host:443`
    // instead of silently discarding the credentials.
    if authority.as_str().contains('@') {
        return None;
    }
    let host = authority.host();
    // `port_u16()` accepts `host:+443` and reads `host:` as `host`, so read the
    // digits after the host here. An empty or overflowing port fails the `u16`
    // parse.
    let port = match &authority.as_str()[host.len()..] {
        "" => default_port?,
        port => {
            let port = port.strip_prefix(':')?;
            if !port.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            port.parse::<u16>().ok()?
        }
    };
    // `host()` keeps IPv6 brackets. Refuse anything else inside them, such as
    // `[127.0.0.1]:443` or a zone ID.
    let host = match host
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
    {
        Some(literal) => {
            literal.parse::<Ipv6Addr>().ok()?;
            literal
        }
        None => host,
    };
    if port == 0 || !valid_host(host) {
        return None;
    }
    Some((host.to_ascii_lowercase(), port))
}

fn valid_host(host: &str) -> bool {
    if host.parse::<IpAddr>().is_ok() {
        return true;
    }
    if host.len() > 253 {
        return false;
    }
    // Accept absolute DNS names as well as ordinary dotted names.
    host.strip_suffix('.')
        .unwrap_or(host)
        .split('.')
        .all(|label| {
            let length = label.len();
            length > 0
                && length <= 63
                && label
                    .as_bytes()
                    .first()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .as_bytes()
                    .last()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}
