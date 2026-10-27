// cspell:words CLOEXEC Errno NONBLOCK RDONLY rustix
//! The CA's key and certificate files: open one that exists only as a regular
//! file reached without a symlink, create one that does not exist with its
//! final mode from the first byte, and read its bytes.

use std::{
    fs::{self, File, OpenOptions, Permissions},
    io::{self, Read as _, Write as _},
    os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _},
    path::Path,
};

use rustix::{
    fs::{Mode, OFlags, open},
    io::Errno,
};

use super::path_error;

/// The regular file at `path`, or `None` when nothing is there.
pub(super) fn open_existing(path: &Path) -> Result<Option<File>, String> {
    match open_regular(path) {
        Ok(file) => Ok(Some(file)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(path_error(path, error)),
    }
}

/// Open `path` as a regular file. A symlink is refused rather than followed,
/// and `NONBLOCK` keeps a FIFO from stalling the open; the file-type check
/// then refuses it.
fn open_regular(path: &Path) -> io::Result<File> {
    let file = File::from(
        open(
            path,
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|error| match error {
            Errno::LOOP => not_regular(),
            error => error.into(),
        })?,
    );
    if !file.metadata()?.is_file() {
        return Err(not_regular());
    }
    Ok(file)
}

/// Create `path`, which must not exist, with `mode` and `contents`. The mode
/// is given at open and set again past the umask; a failed write removes the
/// file.
pub(super) fn create(path: &Path, mode: u32, contents: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(path)?;
    let written = file
        .set_permissions(Permissions::from_mode(mode))
        .and_then(|()| file.write_all(contents))
        .and_then(|()| file.sync_all());
    if written.is_err() {
        let _ = fs::remove_file(path);
    }
    written
}

pub(super) fn read_file(file: &mut File, path: &Path) -> Result<Vec<u8>, String> {
    let mut contents = Vec::new();
    file.read_to_end(&mut contents)
        .map_err(|error| path_error(path, error))?;
    Ok(contents)
}

fn not_regular() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "must be a regular file, not a symlink",
    )
}
