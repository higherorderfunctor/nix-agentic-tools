#[cfg(test)]
use std::path::Path;
use std::{fmt, path::PathBuf};

use zeroize::Zeroizing;

use crate::error::{SecretError, SecretFileError};

pub struct Secret {
    #[cfg_attr(not(test), allow(dead_code))]
    value: Zeroizing<String>,
}

impl Secret {
    #[cfg(test)]
    fn expose(&self) -> &str {
        &self.value
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
        let mut value = Zeroizing::new(std::fs::read_to_string(&self.0).map_err(|source| {
            SecretError::Read {
                path: self.0.clone(),
                source,
            }
        })?);
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
}
