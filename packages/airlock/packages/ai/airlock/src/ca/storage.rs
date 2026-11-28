// cspell:words Zeroizing
//! The CA's files: read one that may not exist, and publish a new one under
//! its final name only once it is complete. `read_existing` is called by
//! `ca::init`, `publish` by `material::create`.

use std::{
    fs::{File, Permissions},
    io::{self, Read as _, Write as _},
    os::unix::fs::{MetadataExt as _, PermissionsExt as _},
    path::Path,
};

use tempfile::NamedTempFile;
use zeroize::Zeroizing;

use super::path_error;

/// A file already on disk: its bytes and permission bits, read through one
/// open handle so the two describe the same file.
pub(super) struct Existing {
    pub(super) bytes: Zeroizing<Vec<u8>>,
    pub(super) mode: u32,
}

/// The file at `path`, or `None` when nothing is there.
pub(super) fn read_existing(path: &Path) -> Result<Option<Existing>, String> {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(path_error(path, error)),
    };
    let metadata = file.metadata().map_err(|error| path_error(path, error))?;
    let mode = metadata.mode() & 0o777;
    // Sized up front: a growing buffer would leave copies of the key that are never zeroed.
    let capacity = usize::try_from(metadata.len())
        .unwrap_or(0)
        .saturating_add(1);
    let mut bytes = Zeroizing::new(Vec::with_capacity(capacity));
    file.read_to_end(&mut bytes)
        .map_err(|error| path_error(path, error))?;
    Ok(Some(Existing { bytes, mode }))
}

/// Writes `contents` to a temporary file in `directory`, then links it to
/// `name` with `mode`. A crash or failure leaves no partial file under `name`,
/// and an existing `name` is never replaced.
pub(super) fn publish(
    directory: &Path,
    name: &str,
    mode: u32,
    contents: &[u8],
) -> Result<(), String> {
    let path = directory.join(name);
    let mut file = NamedTempFile::new_in(directory).map_err(|error| path_error(&path, error))?;
    file.as_file()
        .set_permissions(Permissions::from_mode(mode))
        .and_then(|()| file.write_all(contents))
        .and_then(|()| file.as_file().sync_all())
        .map_err(|error| path_error(&path, error))?;
    file.persist_noclobber(&path)
        .map(drop)
        .map_err(|error| path_error(&path, error.error))
}
