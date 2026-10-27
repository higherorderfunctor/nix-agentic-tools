//! Airlock's local CA: `init` creates it in an instance's private runtime
//! directory, or validates the pair already there, and never replaces existing
//! material.

mod directory;
mod location;
mod material;
mod storage;

use std::{
    fs, io,
    path::{Path, PathBuf},
};

pub use location::{Instance, RuntimeBase};

const CA_CERTIFICATE: &str = "ca.pem";
const CA_KEY: &str = "ca.key";

/// Creates `instance`'s local CA in its runtime directory under `base`, or
/// validates the pair already there, and returns the public certificate path.
///
/// An existing pair is accepted only when it belongs together, is signed by its
/// own key, is a currently valid CA, and keeps its key private. Anything else is
/// refused, never overwritten or trusted. The one exception is a key with no
/// certificate, which an interrupted init left behind and which is replaced.
pub fn init(base: &RuntimeBase, instance: &Instance) -> Result<PathBuf, String> {
    // Held until `init` returns, so concurrent inits run one at a time.
    let (path, _lock) = directory::create_and_lock(base, instance)?;

    let certificate_path = path.join(CA_CERTIFICATE);
    let key_path = path.join(CA_KEY);
    match (
        storage::read_existing(&certificate_path)?,
        storage::read_existing(&key_path)?,
    ) {
        (None, None) => material::create(&path)?,
        // The key is published before the certificate, and no client can trust
        // a CA whose certificate never appeared, so this key is the leftover of
        // an interrupted init and discarding it loses nothing.
        (None, Some(_)) => {
            fs::remove_file(&key_path).map_err(|error| path_error(&key_path, error))?;
            material::create(&path)?;
        }
        (Some(certificate), Some(key)) => material::validate(
            &certificate.bytes,
            &key.bytes,
            key.mode,
            &certificate_path,
            &key_path,
        )?,
        (Some(_), None) => return Err(material::unpaired(&certificate_path, &key_path)),
    }

    Ok(certificate_path)
}

fn path_error(path: &Path, error: impl Into<io::Error>) -> String {
    format!("{}: {}", path.display(), error.into())
}
