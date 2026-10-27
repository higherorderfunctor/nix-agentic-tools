//! Airlock's local CA: `init` creates it in a private directory, or validates
//! the pair already there, and never replaces existing material.

mod directory;
mod material;
mod storage;

use std::{
    io,
    path::{Path, PathBuf},
};

const CA_CERTIFICATE: &str = "ca.pem";
const CA_KEY: &str = "ca.key";

/// Creates Airlock's local CA in `directory`, or validates the pair already
/// there, and returns the public certificate path.
///
/// An existing pair is accepted only when it belongs together, is signed by its
/// own key, is a currently valid CA, and keeps its key private. Anything else is
/// refused, never overwritten or trusted.
pub fn init(directory: impl AsRef<Path>) -> Result<PathBuf, String> {
    // Held until `init` returns, so concurrent inits run one at a time.
    let (path, _lock) = directory::create_and_lock(directory.as_ref())?;

    let certificate_path = path.join(CA_CERTIFICATE);
    let key_path = path.join(CA_KEY);
    match (
        storage::open_existing(&certificate_path)?,
        storage::open_existing(&key_path)?,
    ) {
        (None, None) => material::create(&certificate_path, &key_path)?,
        (Some(mut certificate), Some(mut key)) => {
            material::validate(&mut certificate, &mut key, &certificate_path, &key_path)?
        }
        (Some(_), None) => return Err(material::unpaired(&certificate_path, &key_path)),
        (None, Some(_)) => return Err(material::unpaired(&key_path, &certificate_path)),
    }

    Ok(certificate_path)
}

fn path_error(path: &Path, error: impl Into<io::Error>) -> String {
    format!("{}: {}", path.display(), error.into())
}
