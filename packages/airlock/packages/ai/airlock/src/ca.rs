//! Airlock's local CA: `init` creates it in an instance's private runtime
//! directory, or validates the pair already there, and `Authority` loads it to
//! issue short-lived leaf certificates for selected DNS names.

mod authority;
mod directory;
mod location;
mod material;
mod storage;

use std::{
    io,
    path::{Path, PathBuf},
};

use time::Duration;

pub use authority::{Authority, Leaf};
pub use location::{Instance, RuntimeBase};

const CA_CERTIFICATE: &str = "ca.pem";
const CA_KEY: &str = "ca.key";
const CLOCK_SKEW: Duration = Duration::hours(1);

/// Creates `instance`'s local CA in its runtime directory under `base`, or
/// validates the pair already there, and returns the public certificate path.
///
/// An existing pair is accepted only when it belongs together, is signed by its
/// own key, is a currently valid CA, and keeps its key private. Anything else is
/// refused, never overwritten or trusted.
pub fn init(base: &RuntimeBase, instance: &Instance) -> Result<PathBuf, String> {
    // Held until `init` returns, so concurrent inits run one at a time.
    let (path, _lock) = directory::create_and_lock(base, instance)?;

    let certificate_path = path.join(CA_CERTIFICATE);
    let key_path = path.join(CA_KEY);
    match (
        storage::open_existing(&certificate_path)?,
        storage::open_existing(&key_path)?,
    ) {
        (None, None) => material::create(&certificate_path, &key_path)?,
        (Some(mut certificate), Some(mut key)) => {
            material::validate(&mut certificate, &mut key, &certificate_path, &key_path)?;
        }
        (Some(_), None) => return Err(material::unpaired(&certificate_path, &key_path)),
        (None, Some(_)) => return Err(material::unpaired(&key_path, &certificate_path)),
    }

    Ok(certificate_path)
}

/// `instance`'s CA directory under `base` as `init` resolves and checks it,
/// whether or not it exists yet; nothing is created. Client trust reads the
/// CA through this path, so it refuses what `init` refuses.
pub fn directory(base: &RuntimeBase, instance: &Instance) -> Result<PathBuf, String> {
    directory::resolve(base, instance).map(|(_, path)| path)
}

fn path_error(path: &Path, error: impl Into<io::Error>) -> String {
    format!("{}: {}", path.display(), error.into())
}
