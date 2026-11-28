// cspell:words geteuid rustix
//! The instance's CA directory: create it, check that only this user can use
//! it, and lock it. Called by `ca::init`.
//!
//! The sandbox, not this module, guards against other processes of the same
//! user. These checks stop other users: a private directory under ancestors
//! they cannot write to.

use std::{
    fs::{self, DirBuilder, File},
    io,
    os::unix::fs::{DirBuilderExt as _, MetadataExt as _},
    path::{Path, PathBuf},
};

use rustix::process::geteuid;

use super::{
    location::{Instance, RuntimeBase},
    path_error,
};

/// Creates `instance`'s CA directory under `base` (mode 0700) if it is missing,
/// and returns its canonical path with the directory open and locked. Dropping
/// the directory releases the lock. `AIRLOCK_HOME` must already exist, and it
/// and everything above it are checked before anything is created.
pub(super) fn create_and_lock(
    base: &RuntimeBase,
    instance: &Instance,
) -> Result<(PathBuf, File), String> {
    let user = geteuid().as_raw();
    let requested = match base {
        RuntimeBase::Home(home) => {
            let home = fs::canonicalize(home).map_err(|error| match error.kind() {
                io::ErrorKind::NotFound => format!(
                    "{} does not exist: create it, or point AIRLOCK_HOME elsewhere",
                    home.display()
                ),
                _ => path_error(home, error),
            })?;
            let requested = RuntimeBase::Home(home.clone()).instance_directory(instance);
            // `XDG_RUNTIME_DIR` is the user's own; only `AIRLOCK_HOME` can be
            // anywhere.
            for ancestor in home.ancestors() {
                check_ancestor(ancestor, &requested, user)?;
            }
            requested
        }
        RuntimeBase::Xdg(_) => base.instance_directory(instance),
    };
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&requested)
        .map_err(|error| path_error(&requested, error))?;
    let path = fs::canonicalize(&requested).map_err(|error| path_error(&requested, error))?;
    // `runtime/` may already exist inside the home with looser modes; another
    // user who can write it could swap the instance directory after the check.
    if let (RuntimeBase::Home(_), Some(runtime)) = (base, path.parent()) {
        check_ancestor(runtime, &path, user)?;
    }

    let metadata = fs::metadata(&path).map_err(|error| path_error(&path, error))?;
    if let Some(problem) = directory_problem(metadata.uid(), metadata.mode(), user) {
        return Err(refusal(&path, &path, problem));
    }

    let directory = File::open(&path).map_err(|error| path_error(&path, error))?;
    directory.lock().map_err(|error| path_error(&path, error))?;
    Ok((path, directory))
}

/// Refuses `directory`, an ancestor of `requested`, when another user could
/// replace what it holds.
fn check_ancestor(directory: &Path, requested: &Path, user: u32) -> Result<(), String> {
    let metadata = fs::metadata(directory).map_err(|error| path_error(directory, error))?;
    match ancestor_problem(metadata.uid(), metadata.mode(), user) {
        Some(problem) => Err(refusal(directory, requested, problem)),
        None => Ok(()),
    }
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

/// Why the CA directory with this owner and mode is not private to `user`, if
/// it is not. Stricter modes than 0700 stay private.
fn directory_problem(owner: u32, mode: u32, user: u32) -> Option<&'static str> {
    if owner != user {
        Some("is not owned by this user")
    } else if mode & 0o077 != 0 {
        Some("grants group or other permissions")
    } else {
        None
    }
}

/// Why `directory` cannot hold the CA directory `path`, or the CA when it is
/// that directory.
fn refusal(directory: &Path, path: &Path, problem: &str) -> String {
    if directory == path {
        format!("{} cannot hold the CA: it {problem}", path.display())
    } else {
        format!(
            "{} cannot hold {}: it {problem}",
            directory.display(),
            path.display()
        )
    }
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
