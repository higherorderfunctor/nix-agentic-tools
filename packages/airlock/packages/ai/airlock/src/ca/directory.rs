// cspell:words CLOEXEC Errno geteuid mkdirat NOENT NOTDIR openat RDONLY RWXU rustix
//! The instance's private CA directory and who may replace it: trust the base,
//! open each directory below it without following a link, create what is
//! missing, and lock the instance directory.

use std::{
    ffi::{OsStr, OsString},
    fs::{self, File},
    io,
    os::unix::fs::MetadataExt as _,
    path::{self, Component, Path, PathBuf},
};

use rustix::{
    fs::{Mode, OFlags, mkdirat, open, openat},
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
    let walk = Walk::new(base, instance)?;
    let directory = walk.create()?;
    directory
        .lock()
        .map_err(|error| path_error(&walk.path, error))?;
    Ok((walk.path, directory))
}

/// The way from a directory no other user can replace to `instance`'s CA
/// directory. `XDG_RUNTIME_DIR` is the user's own, so its path is used as
/// given. An `AIRLOCK_HOME` path is canonicalized once, so a symlink swapped
/// later cannot redirect it, and every existing directory on it is checked.
/// Each directory below either is opened from its parent without following a
/// link, so none can be redirected after it is checked.
struct Walk {
    /// The directory the walk opens first.
    start: PathBuf,
    /// The names below `start`, the instance directory's last.
    components: Vec<OsString>,
    /// `start` joined with `components`: the CA directory.
    path: PathBuf,
}

impl Walk {
    fn new(base: &RuntimeBase, instance: &Instance) -> Result<Self, String> {
        let (root, below) = base.components(instance);
        let (start, mut components) = match base {
            RuntimeBase::Xdg(_) => (root.to_owned(), Vec::new()),
            RuntimeBase::Home(_) => canonical(root)?,
        };
        components.extend(below.into_iter().map(OsString::from));
        let path = components
            .iter()
            .fold(start.clone(), |path, name| path.join(name));
        if let RuntimeBase::Home(_) = base {
            check_ancestors(&start, &path)?;
        }
        Ok(Self {
            start,
            components,
            path,
        })
    }

    /// Opens each directory on the walk, creating it 0700 when it is missing,
    /// and returns the CA directory.
    fn create(&self) -> Result<File, String> {
        let mut directory = open(
            &self.start,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map(File::from)
        .map_err(|error| path_error(&self.start, error))?;
        let mut reached = self.start.clone();
        for name in &self.components {
            reached.push(name);
            directory = self.open_or_create(&directory, name, &reached)?;
        }
        Ok(directory)
    }

    /// `name` in `parent`, at `reached`, created 0700 when it is missing and
    /// refused unless it is a directory, not a link, private to this user.
    fn open_or_create(&self, parent: &File, name: &OsStr, reached: &Path) -> Result<File, String> {
        let opened = match open_below(parent, name) {
            Err(Errno::NOENT) => match mkdirat(parent, name, Mode::RWXU) {
                Ok(()) | Err(Errno::EXIST) => open_below(parent, name),
                Err(error) => return Err(path_error(reached, error)),
            },
            opened => opened,
        };
        let directory = match opened {
            Ok(directory) => directory,
            Err(Errno::LOOP | Errno::NOTDIR) => {
                return Err(refusal(reached, &self.path, "is not a directory"));
            }
            Err(error) => return Err(path_error(reached, error)),
        };
        let metadata = directory
            .metadata()
            .map_err(|error| path_error(reached, error))?;
        match directory_problem(metadata.uid(), metadata.mode(), user()) {
            Some(problem) => Err(refusal(reached, &self.path, problem)),
            None => Ok(directory),
        }
    }
}

/// The canonical form of the deepest existing directory on `home`, and the
/// names of the missing directories below it.
fn canonical(home: &Path) -> Result<(PathBuf, Vec<OsString>), String> {
    let home = path::absolute(home).map_err(|error| path_error(home, error))?;
    let mut existing = home.as_path();
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
    let missing = home
        .strip_prefix(existing)
        .expect("an ancestor is a prefix of its path")
        .components()
        .map(|component| match component {
            Component::Normal(name) => Ok(name.to_owned()),
            // `..` below a missing directory would climb back out of the
            // checked one.
            _ => Err(format!(
                "{} cannot hold the CA: `..` follows a missing directory",
                home.display()
            )),
        })
        .collect::<Result<_, _>>()?;
    Ok((trusted, missing))
}

/// Refuses `existing` or the nearest directory above it that another user
/// could replace an entry of.
fn check_ancestors(existing: &Path, path: &Path) -> Result<(), String> {
    for directory in existing.ancestors() {
        let metadata =
            fs::symlink_metadata(directory).map_err(|error| path_error(directory, error))?;
        if let Some(problem) = ancestor_problem(metadata.uid(), metadata.mode(), user()) {
            return Err(refusal(directory, path, problem));
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

/// `name` in `parent` as a directory, refused if it is a link.
fn open_below(parent: &File, name: &OsStr) -> rustix::io::Result<File> {
    openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map(File::from)
}

/// Why a directory on the walk with this owner and mode is not private to
/// `user`, if it is not. Stricter modes than 0700 stay private.
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
