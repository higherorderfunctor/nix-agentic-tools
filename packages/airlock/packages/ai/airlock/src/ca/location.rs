//! Where an instance keeps its CA: the instance name, and the runtime base the
//! environment selects for it.

use std::{
    env, fmt,
    path::{Path, PathBuf},
    str::FromStr,
};

/// An instance name: one path component of ASCII letters, digits, `_` and `-`,
/// so it can never leave its base.
#[derive(Clone)]
pub struct Instance(String);

impl Default for Instance {
    fn default() -> Self {
        Self("default".to_owned())
    }
}

impl FromStr for Instance {
    type Err = String;

    fn from_str(name: &str) -> Result<Self, String> {
        let allowed = |byte: u8| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-';
        if !name.is_empty() && name.bytes().all(allowed) {
            Ok(Self(name.to_owned()))
        } else {
            Err("an instance name is one or more ASCII letters, digits, `_` or `-`".to_owned())
        }
    }
}

impl fmt::Display for Instance {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// The directory an instance's runtime files go under.
pub enum RuntimeBase {
    /// `AIRLOCK_HOME`: any directory, so its ancestors are checked before use.
    Home(PathBuf),
    /// `XDG_RUNTIME_DIR`: the user's own runtime directory, trusted as it is.
    Xdg(PathBuf),
}

impl RuntimeBase {
    /// `AIRLOCK_HOME` when it is set and non-empty, otherwise
    /// `XDG_RUNTIME_DIR`. Without either there is no base: a shared fallback
    /// such as `/tmp` would let another user claim the directory first.
    pub fn from_environment() -> Result<Self, String> {
        let set = |name| env::var_os(name).filter(|value| !value.is_empty());
        match (set("AIRLOCK_HOME"), set("XDG_RUNTIME_DIR")) {
            (Some(home), _) => Ok(Self::Home(home.into())),
            // The XDG spec makes a relative value invalid: each process would
            // resolve it against its own working directory and find another CA.
            (None, Some(runtime)) if Path::new(&runtime).is_absolute() => {
                Ok(Self::Xdg(runtime.into()))
            }
            (None, Some(_)) => Err("XDG_RUNTIME_DIR must be an absolute path".to_owned()),
            (None, None) => Err(
                "XDG_RUNTIME_DIR is unset or empty; set it, or AIRLOCK_HOME, to choose where \
                 Airlock keeps its runtime files"
                    .to_owned(),
            ),
        }
    }

    /// The base directory, and `instance`'s runtime directory under it.
    pub(super) fn directory(&self, instance: &Instance) -> (&PathBuf, PathBuf) {
        match self {
            Self::Home(home) => (home, home.join("runtime").join(&instance.0)),
            Self::Xdg(runtime) => (runtime, runtime.join("airlock").join(&instance.0)),
        }
    }
}
