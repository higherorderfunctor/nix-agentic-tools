// cspell:words CLOEXEC fstat geteuid mkfifoat NONBLOCK RDONLY replacen RUSR rustix WUSR Zeroizing
// cspell:ignore Zm9vOmJhcg Zm9vOmJhch
use std::{
    collections::BTreeMap,
    fs::File,
    io::{self, Read},
    path::Path,
};

use base64::{Engine, engine::general_purpose::STANDARD};
use hyper::{Request, header::PROXY_AUTHORIZATION};
use rustix::fs::{FileType, Mode, OFlags, fstat, open};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use crate::config::Client;

const MAX_TOKEN_BYTES: usize = 4096;
const MAX_NAME_BYTES: usize = 64;
const MAX_HEADER_BYTES: usize = 6 + (MAX_NAME_BYTES + 1 + MAX_TOKEN_BYTES).div_ceil(3) * 4;

// Deliberately no Debug: tokens and decoded credentials never belong in logs.
pub(crate) struct Clients(Option<BTreeMap<String, Zeroizing<Vec<u8>>>>);

impl Clients {
    pub(crate) fn load(config: Option<&BTreeMap<String, Client>>) -> io::Result<Self> {
        let Some(config) = config else {
            return Ok(Self(None));
        };
        if config.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "clients must not be empty",
            ));
        }
        let mut clients = BTreeMap::new();
        for (name, client) in config {
            if name.is_empty()
                || name.len() > MAX_NAME_BYTES
                || !name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "invalid client name",
                ));
            }
            let token = read_token(&client.token_file).map_err(|error| {
                io::Error::new(
                    error.kind(),
                    format!(
                        "client {name} token file {}: {error}",
                        client.token_file.display()
                    ),
                )
            })?;
            clients.insert(name.clone(), token);
        }
        Ok(Self(Some(clients)))
    }

    pub(crate) fn admit<B>(&self, request: &mut Request<B>) -> Result<(), ()> {
        if let Some(clients) = &self.0 {
            let mut values = request.headers().get_all(PROXY_AUTHORIZATION).iter();
            let value = values.next().ok_or(())?.as_bytes();
            if values.next().is_some() || value.len() > MAX_HEADER_BYTES {
                return Err(());
            }
            let separator = value.iter().position(|b| *b == b' ').ok_or(())?;
            let (scheme, encoded) = (&value[..separator], &value[separator + 1..]);
            if !scheme.eq_ignore_ascii_case(b"Basic") {
                return Err(());
            }
            // STANDARD requires canonical padding and rejects whitespace/trailing bits.
            let mut decoded = Zeroizing::new(Vec::new());
            STANDARD.decode_vec(encoded, &mut decoded).map_err(|_| ())?;
            let separator = decoded.iter().position(|b| *b == b':').ok_or(())?;
            let (name, password) = (&decoded[..separator], &decoded[separator + 1..]);
            let expected = clients
                .get(std::str::from_utf8(name).map_err(|_| ())?)
                .ok_or(())?;
            if !bool::from(expected.as_slice().ct_eq(password)) {
                return Err(());
            }
        }
        request.headers_mut().remove(PROXY_AUTHORIZATION);
        Ok(())
    }
}

fn read_token(path: &Path) -> io::Result<Zeroizing<Vec<u8>>> {
    let file = open(
        path,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
        Mode::empty(),
    )?;
    let metadata = fstat(&file)?;
    if FileType::from_raw_mode(metadata.st_mode) != FileType::RegularFile
        || metadata.st_uid != rustix::process::geteuid().as_raw()
        || !matches!(metadata.st_mode & 0o7777, 0o400 | 0o600)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "must be a regular file owned by this user with mode 0400 or 0600",
        ));
    }
    let mut token = Zeroizing::new(Vec::new());
    File::from(file)
        .take((MAX_TOKEN_BYTES + 2) as u64)
        .read_to_end(&mut token)?;
    if token.last() == Some(&b'\n') {
        token.pop();
    }
    if token.is_empty()
        || token.len() > MAX_TOKEN_BYTES
        || !token.iter().all(|byte| (b'!'..=b'~').contains(byte))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "must contain 1 to 4096 graphic ASCII bytes with an optional single LF",
        ));
    }
    Ok(token)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{PermissionsExt, symlink},
    };
    use tempfile::tempdir;

    fn configured(path: &Path) -> BTreeMap<String, Client> {
        BTreeMap::from([(
            "fixture".into(),
            Client {
                token_file: path.into(),
            },
        )])
    }

    #[test]
    fn private_bounded_regular_files_and_exact_token_grammar() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("token");
        for (bytes, accepted) in [
            (b"!:@%#/?~".to_vec(), true),
            (b"token\n".to_vec(), true),
            (vec![b'x'; MAX_TOKEN_BYTES], true),
            ([vec![b'x'; MAX_TOKEN_BYTES], vec![b'\n']].concat(), true),
            (vec![b'x'; MAX_TOKEN_BYTES + 1], false),
            (vec![b'x'; MAX_TOKEN_BYTES + 2], false),
            (vec![], false),
            (b"\n".to_vec(), false),
            (b" token".to_vec(), false),
            (b"token ".to_vec(), false),
            (b"token\t".to_vec(), false),
            (b"token\r\n".to_vec(), false),
            (b"token\n\n".to_vec(), false),
            (b"to\nken".to_vec(), false),
            (b"to\0ken".to_vec(), false),
            (vec![127], false),
            (vec![128], false),
        ] {
            fs::write(&path, bytes).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            assert_eq!(Clients::load(Some(&configured(&path))).is_ok(), accepted);
        }
        fs::write(&path, b"token").unwrap();
        for (mode, accepted) in [
            (0o400, true),
            (0o600, true),
            (0o000, false),
            (0o644, false),
            (0o640, false),
            (0o700, false),
            (0o4600, false),
        ] {
            fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
            assert_eq!(
                Clients::load(Some(&configured(&path))).is_ok(),
                accepted,
                "{mode:o}"
            );
        }
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let link = directory.path().join("link");
        symlink(&path, &link).unwrap();
        assert!(Clients::load(Some(&configured(&link))).is_err());
        assert!(Clients::load(Some(&configured(directory.path()))).is_err());
        let fifo = directory.path().join("fifo");
        rustix::fs::mkfifoat(rustix::fs::CWD, &fifo, Mode::RUSR | Mode::WUSR).unwrap();
        assert!(Clients::load(Some(&configured(&fifo))).is_err());
        fs::remove_file(&path).unwrap();
        assert!(Clients::load(Some(&configured(&path))).is_err());
        assert!(Clients::load(Some(&BTreeMap::new())).is_err());
        for name in ["", "a:b", "a/b", "a@b", "a b", &"a".repeat(65)] {
            let map = BTreeMap::from([(
                name.into(),
                Client {
                    token_file: path.clone(),
                },
            )]);
            assert_eq!(
                Clients::load(Some(&map)).err().unwrap().to_string(),
                "invalid client name"
            );
        }
    }

    #[test]
    fn admission_is_strict_and_loaded_tokens_survive_rotation() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("token");
        fs::write(&path, b"token:punctuation!\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let clients = Clients::load(Some(&configured(&path))).unwrap();
        fs::write(&path, b"replacement").unwrap();
        fs::remove_file(&path).unwrap();
        let good = format!("Basic {}", STANDARD.encode(b"fixture:token:punctuation!"));
        for (headers, accepted) in [
            (vec![], false),
            (vec![good.clone()], true),
            (vec![good.replacen("Basic", "bAsIc", 1)], true),
            (vec![good.clone(), good.clone()], false),
            (vec![format!("{good}, {good}")], false),
            (vec!["Bearer token".into()], false),
            (vec!["Basic !!!!".into()], false),
            (
                vec![format!(
                    "Basic  {}",
                    STANDARD.encode(b"fixture:token:punctuation!")
                )],
                false,
            ),
            (
                vec![format!("Basic {}", STANDARD.encode(b"fixture:wrong"))],
                false,
            ),
            (
                vec![format!(
                    "Basic {}",
                    STANDARD.encode(b"unknown:token:punctuation!")
                )],
                false,
            ),
            (
                vec![format!("Basic {}", STANDARD.encode(b"fixture"))],
                false,
            ),
            (vec!["Basic Zm9vOmJhcg".into()], false),
            (vec!["Basic Zm9vOmJhch==".into()], false),
            (vec!["x".repeat(MAX_HEADER_BYTES + 1)], false),
        ] {
            let mut request = Request::new(());
            request.headers_mut().insert(
                hyper::header::AUTHORIZATION,
                "Bearer native".parse().unwrap(),
            );
            for value in headers {
                request
                    .headers_mut()
                    .append(PROXY_AUTHORIZATION, value.parse().unwrap());
            }
            assert_eq!(clients.admit(&mut request).is_ok(), accepted);
            assert_eq!(
                request.headers()[hyper::header::AUTHORIZATION],
                "Bearer native"
            );
            if accepted {
                assert!(!request.headers().contains_key(PROXY_AUTHORIZATION));
            }
        }
        let disabled = Clients::load(None).unwrap();
        let mut request = Request::builder()
            .header(PROXY_AUTHORIZATION, "anything")
            .body(())
            .unwrap();
        disabled.admit(&mut request).unwrap();
        assert!(!request.headers().contains_key(PROXY_AUTHORIZATION));
    }
}
