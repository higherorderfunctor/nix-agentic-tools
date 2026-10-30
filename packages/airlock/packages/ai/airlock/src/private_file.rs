//! Opening files that hold private material: reach a regular file by its own
//! name, never through a symlink, and check who owns what was opened.
// cspell:words CLOEXEC Errno fstat geteuid NONBLOCK RDONLY rustix
use std::{fs::File, io, path::Path};

use rustix::{
    fd::AsFd,
    fs::{FileType, Mode, OFlags, Stat, fstat, openat},
    process::geteuid,
};

/// Open `path`, relative to `directory`, as a regular file. A symlink is
/// refused rather than followed, and `NONBLOCK` keeps a FIFO from stalling
/// the open; the file-type check then refuses it.
pub(crate) fn open_regular(directory: impl AsFd, path: &Path) -> io::Result<File> {
    let file = openat(
        directory,
        path,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|error| match error {
        rustix::io::Errno::LOOP => not_regular(),
        error => error.into(),
    })?;
    if FileType::from_raw_mode(fstat(&file)?.st_mode) != FileType::RegularFile {
        return Err(not_regular());
    }
    Ok(file.into())
}

/// Whether the effective user owns the file or directory `metadata` describes.
pub(crate) fn owned_by_user(metadata: &Stat) -> bool {
    metadata.st_uid == geteuid().as_raw()
}

fn not_regular() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "must be a regular file, not a symlink",
    )
}
