#[cfg(test)]
use std::path::Path;
use std::{fmt, io::Read, path::PathBuf};

use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use crate::error::{SecretError, SecretFileError};

pub struct Secret {
    value: Zeroizing<String>,
}

impl Secret {
    /// Compares a presented token without exposing the stored value.
    #[must_use]
    pub fn matches(&self, candidate: &[u8]) -> bool {
        bool::from(self.value.as_bytes().ct_eq(candidate))
    }

    /// Returns the loaded value for a caller that must transmit it.
    ///
    /// Callers must not debug, display, or log the returned string.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.value
    }

    /// Transfers ownership to a caller that must send this token without making another copy.
    #[must_use]
    pub fn into_value(self) -> Zeroizing<String> {
        self.value
    }

    #[cfg(test)]
    fn expose(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("[redacted]")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SecretFile(PathBuf);

impl TryFrom<PathBuf> for SecretFile {
    type Error = SecretFileError;

    fn try_from(path: PathBuf) -> Result<Self, Self::Error> {
        if path.is_absolute() {
            Ok(Self(path))
        } else {
            Err(SecretFileError::RelativePath { path })
        }
    }
}

impl SecretFile {
    #[cfg(test)]
    pub(crate) fn path(&self) -> &Path {
        &self.0
    }

    /// Reads and returns the secret.
    ///
    /// # Errors
    ///
    /// Returns an error when the file cannot be read, or is empty after trimming one trailing newline.
    pub fn load(&self) -> Result<Secret, SecretError> {
        let value = Zeroizing::new(std::fs::read_to_string(&self.0).map_err(|source| {
            SecretError::Read {
                path: self.0.clone(),
                source,
            }
        })?);
        self.finish(value)
    }

    /// Reads at most `limit` bytes from a regular file without blocking on a FIFO.
    ///
    /// # Errors
    /// Rejects special files, symlinks, oversized contents, empty tokens, and invalid UTF-8.
    pub fn load_bounded_regular(&self, limit: usize) -> Result<Secret, SecretError> {
        let descriptor = rustix::fs::openat(
            rustix::fs::CWD,
            &self.0,
            rustix::fs::OFlags::RDONLY
                | rustix::fs::OFlags::NONBLOCK
                | rustix::fs::OFlags::NOFOLLOW
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .map_err(|source| SecretError::Read {
            path: self.0.clone(),
            source: source.into(),
        })?;
        let file = std::fs::File::from(descriptor);
        let metadata = file.metadata().map_err(|source| SecretError::Read {
            path: self.0.clone(),
            source,
        })?;
        if !metadata.is_file() {
            return Err(SecretError::UnsupportedType {
                path: self.0.clone(),
            });
        }
        if metadata.len() > limit as u64 {
            return Err(SecretError::TooLarge {
                limit,
                path: self.0.clone(),
            });
        }
        let mut bytes = Zeroizing::new(Vec::new());
        file.take(limit as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|source| SecretError::Read {
                path: self.0.clone(),
                source,
            })?;
        if bytes.len() > limit {
            return Err(SecretError::TooLarge {
                limit,
                path: self.0.clone(),
            });
        }
        let text = std::str::from_utf8(&bytes).map_err(|_| SecretError::Read {
            path: self.0.clone(),
            source: std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid UTF-8"),
        })?;
        self.finish(Zeroizing::new(text.to_owned()))
    }

    fn finish(&self, mut value: Zeroizing<String>) -> Result<Secret, SecretError> {
        if let Some(trimmed) = value.strip_suffix("\r\n") {
            let trimmed_length = trimmed.len();
            value.truncate(trimmed_length);
        } else if let Some(trimmed) = value.strip_suffix('\n') {
            let trimmed_length = trimmed.len();
            value.truncate(trimmed_length);
        }

        if value.is_empty() {
            return Err(SecretError::Empty {
                path: self.0.clone(),
            });
        }

        Ok(Secret { value })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_debug_redacts_its_value() {
        let secret = Secret {
            value: Zeroizing::new("fake-SECRET-token".to_owned()),
        };
        assert_eq!(format!("{secret:?}"), "[redacted]");
        assert_eq!(secret.expose(), "fake-SECRET-token");
    }

    #[test]
    fn secret_file_load_trims_exactly_one_trailing_newline_and_rejects_zero_bytes() {
        let directory = tempfile::tempdir().expect("tempdir");
        let path = directory.path().join("token");

        for (input, expected) in [
            ("", None),
            ("fake-SECRET-token", Some("fake-SECRET-token")),
            ("fake-SECRET-token\r\n", Some("fake-SECRET-token")),
            ("fake-SECRET-token\n\n", Some("fake-SECRET-token\n")),
            ("\n", None),
        ] {
            std::fs::write(&path, input).expect("write token");
            let file = SecretFile(path.clone());

            match expected {
                Some(expected) => {
                    let loaded = file.load().expect("load token");
                    assert_eq!(loaded.expose(), expected);
                }
                None => assert!(matches!(
                    file.load().expect_err("zero-byte token was accepted"),
                    SecretError::Empty { .. }
                )),
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn bounded_loader_rejects_fifo_symlink_and_oversized_file() {
        let directory = tempfile::tempdir().expect("tempdir");
        let token = directory.path().join("token");
        std::fs::write(&token, b"fake-token").expect("regular token");
        assert_eq!(
            SecretFile(token.clone())
                .load_bounded_regular(10)
                .expect("bounded token")
                .expose(),
            "fake-token"
        );
        assert!(matches!(
            SecretFile(token.clone()).load_bounded_regular(3),
            Err(SecretError::TooLarge { .. })
        ));
        let link = directory.path().join("link");
        std::os::unix::fs::symlink(&token, &link).expect("symlink");
        assert!(SecretFile(link).load_bounded_regular(10).is_err());
        let fifo = directory.path().join("fifo");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&fifo)
                .status()
                .expect("mkfifo")
                .success()
        );
        assert!(matches!(
            SecretFile(fifo).load_bounded_regular(10),
            Err(SecretError::UnsupportedType { .. })
        ));
    }
}
