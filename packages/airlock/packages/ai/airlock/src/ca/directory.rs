// cspell:words CLOEXEC Errno geteuid NOTDIR RDONLY rustix
//! The instance's private CA directory and who may replace it: find it under
//! its base, check an `AIRLOCK_HOME` path, create what is missing, and open and
//! lock the directory.

use std::{
    fs::{self, DirBuilder, File},
    io,
    os::unix::fs::{DirBuilderExt as _, MetadataExt as _},
    path::{self, Component, Path, PathBuf},
};

use rustix::{
    fs::{Mode, OFlags, open},
    io::Errno,
    process::geteuid,
};

use super::{
    location::{Instance, RuntimeBase},
    path_error,
};

/// Creates `instance`'s private CA directory under `base` if it is missing,
/// and returns its path with the open directory locked. Dropping the directory
/// releases the lock.
pub(super) fn create_and_lock(
    base: &RuntimeBase,
    instance: &Instance,
) -> Result<(PathBuf, File), String> {
    let (trusted, path) = resolve(base, instance)?;
    let missing: Vec<_> = path
        .ancestors()
        .take_while(|directory| *directory != trusted)
        .collect();
    for directory in missing.into_iter().rev() {
        match DirBuilder::new().mode(0o700).create(directory) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(path_error(directory, error)),
        }
    }
    let directory = open_directory(&path)?;
    directory.lock().map_err(|error| path_error(&path, error))?;
    Ok((path, directory))
}

/// A directory no other user can replace, and the instance directory below
/// it. `XDG_RUNTIME_DIR` is the user's own, so its path is used as given; an
/// `AIRLOCK_HOME` path is canonicalized once, so a symlink swapped later cannot
/// redirect it, and every directory on it is checked.
fn resolve(base: &RuntimeBase, instance: &Instance) -> Result<(PathBuf, PathBuf), String> {
    let (root, path) = base.directory(instance);
    match base {
        RuntimeBase::Xdg(_) => Ok((root.clone(), path)),
        RuntimeBase::Home(_) => canonical(&path),
    }
}

/// The canonical form of the deepest existing directory on `path`, checked,
/// and `path` rebuilt on it.
fn canonical(path: &Path) -> Result<(PathBuf, PathBuf), String> {
    let path = path::absolute(path).map_err(|error| path_error(path, error))?;
    let mut existing = path.as_path();
    let trusted = loop {
        match fs::canonicalize(existing) {
            Ok(canonical) => break canonical,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                existing = existing
                    .parent()
                    .ok_or_else(|| path_error(existing, error))?;
            }
            Err(error) => return Err(path_error(existing, error)),
        }
    };
    let missing = path
        .strip_prefix(existing)
        .expect("an ancestor is a prefix of its path");
    // `..` below a missing directory would climb back out of the checked one.
    if !missing
        .components()
        .all(|component| matches!(component, Component::Normal(_)))
    {
        return Err(format!(
            "{} cannot hold the CA: `..` follows a missing directory",
            path.display()
        ));
    }
    let path = trusted.join(missing);
    check_ancestors(&trusted, &path)?;
    Ok((trusted, path))
}

/// Refuses `existing` or the nearest directory above it that another user
/// could replace an entry of.
fn check_ancestors(existing: &Path, path: &Path) -> Result<(), String> {
    for directory in existing.ancestors() {
        let metadata =
            fs::symlink_metadata(directory).map_err(|error| path_error(directory, error))?;
        if let Some(problem) = ancestor_problem(metadata.uid(), metadata.mode(), user()) {
            return Err(format!(
                "{} cannot hold {}: it {problem}",
                directory.display(),
                path.display()
            ));
        }
    }
    Ok(())
}

/// Why a directory with this owner and mode lets another user replace what it
/// holds, if it does. Sticky directories such as /tmp are refused too.
fn ancestor_problem(owner: u32, mode: u32, user: u32) -> Option<&'static str> {
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
            ancestor_problem(user + 1, 0o755, user),
            Some("is owned by neither this user nor root")
        );
        assert_eq!(ancestor_problem(0, 0o755, user), None);
        assert_eq!(ancestor_problem(user, 0o700, user), None);
    }
}
