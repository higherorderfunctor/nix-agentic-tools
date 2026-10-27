// cspell:words CLOEXEC Errno geteuid NOTDIR RDONLY rustix
//! Where the CA lives and who may write it: the parent that decides who can
//! replace the CA directory, and the private directory itself.

use std::{
    fs::{self, DirBuilder, File},
    io,
    os::unix::fs::{DirBuilderExt as _, MetadataExt as _},
    path::{Path, PathBuf},
};

use rustix::{
    fs::{Mode, OFlags, open},
    io::Errno,
    process::geteuid,
};

use super::path_error;

/// Creates the private CA directory `requested` names if it is missing, and
/// returns its path with the open directory locked. Dropping the directory
/// releases the lock.
pub(super) fn create_and_lock(requested: &Path) -> Result<(PathBuf, File), String> {
    let (parent, path) = locate(requested)?;
    check_parent(parent, &path)?;
    match DirBuilder::new().mode(0o700).create(&path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(path_error(&path, error)),
    }
    let directory = open_directory(&path)?;
    directory.lock().map_err(|error| path_error(&path, error))?;
    Ok((path, directory))
}

/// The parent that decides who can replace the CA directory, and the directory
/// named without a trailing `/` or `.`, so opening it refuses a symlink rather
/// than following it.
fn locate(requested: &Path) -> Result<(&Path, PathBuf), String> {
    let name = requested
        .file_name()
        .ok_or_else(|| format!("{} must name a CA directory", requested.display()))?;
    Ok(
        match requested
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            Some(parent) => (parent, parent.join(name)),
            None => (Path::new("."), PathBuf::from(name)),
        },
    )
}

fn check_parent(parent: &Path, path: &Path) -> Result<(), String> {
    let metadata = fs::metadata(parent).map_err(|error| path_error(parent, error))?;
    match parent_problem(metadata.uid(), metadata.mode(), user()) {
        Some(problem) => Err(format!(
            "{} cannot hold the CA directory {}: it {problem}",
            parent.display(),
            path.display()
        )),
        None => Ok(()),
    }
}

/// Why a parent with this owner and mode lets another user replace the CA
/// directory, if it does. Sticky directories such as /tmp are refused too.
fn parent_problem(owner: u32, mode: u32, user: u32) -> Option<&'static str> {
    if owner != user && owner != 0 {
        Some("is owned by neither this user nor root")
    } else if mode & 0o022 != 0 {
        Some("is writable by group or others")
    } else {
        None
    }
}

fn open_directory(path: &Path) -> Result<File, String> {
    let directory = match open(
        path,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    ) {
        Ok(directory) => File::from(directory),
        Err(Errno::LOOP | Errno::NOTDIR) => {
            return Err(unusable_directory(path, "is not a directory"));
        }
        Err(error) => return Err(path_error(path, error)),
    };
    let metadata = directory
        .metadata()
        .map_err(|error| path_error(path, error))?;
    match directory_problem(metadata.uid(), metadata.mode(), user()) {
        Some(problem) => Err(unusable_directory(path, problem)),
        None => Ok(directory),
    }
}

/// Why a CA directory with this owner and mode is not private to `user`, if it
/// is not. Stricter modes than 0700 stay private.
fn directory_problem(owner: u32, mode: u32, user: u32) -> Option<&'static str> {
    if owner != user {
        Some("is not owned by this user")
    } else if mode & 0o077 != 0 {
        Some("grants group or other permissions")
    } else {
        None
    }
}

fn unusable_directory(path: &Path, problem: &str) -> String {
    format!("{} cannot hold the CA: it {problem}", path.display())
}

fn user() -> u32 {
    geteuid().as_raw()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Making a directory another user owns needs root, so these check the
    // judgement `init` applies to the owner it reads from the real directory.
    #[test]
    fn directories_owned_by_another_user_are_refused() {
        let user = 1000;
        assert_eq!(
            directory_problem(user + 1, 0o700, user),
            Some("is not owned by this user")
        );
        assert_eq!(directory_problem(user, 0o700, user), None);
        assert_eq!(
            parent_problem(user + 1, 0o755, user),
            Some("is owned by neither this user nor root")
        );
        assert_eq!(parent_problem(0, 0o755, user), None);
        assert_eq!(parent_problem(user, 0o700, user), None);
    }
}
