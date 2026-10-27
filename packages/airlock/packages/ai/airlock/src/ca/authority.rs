// cspell:words Zeroizing
//! The loaded CA at run time: issue short-lived leaf certificates for the DNS
//! names selected at startup, and keep one cached leaf per name.

use std::{
    collections::BTreeMap,
    path::Path,
    sync::{Arc, Mutex},
};

use rcgen::{CertificateParams, ExtendedKeyUsagePurpose, Issuer, KeyPair, KeyUsagePurpose};
use rustls::pki_types::{CertificateDer, DnsName, PrivatePkcs8KeyDer};
use time::{Duration, OffsetDateTime};
use zeroize::Zeroizing;

use super::{
    CA_CERTIFICATE, CA_KEY, CLOCK_SKEW, directory,
    material::{self, Material, mint_error},
    storage,
};

const LEAF_VALIDITY: Duration = Duration::days(7);
const RENEW_BEFORE: Duration = Duration::days(1);

/// A leaf certificate issued for one selected DNS name, with its private key.
pub struct Leaf {
    pub certificate: CertificateDer<'static>,
    pub key: PrivatePkcs8KeyDer<'static>,
    not_after: OffsetDateTime,
}

/// A validated local CA with one in-memory leaf slot per selected DNS name.
/// Opening loads the CA `init` created; it never creates one or installs trust.
pub struct Authority {
    material: Material,
    leaves: Mutex<BTreeMap<String, Option<Arc<Leaf>>>>,
}

impl Authority {
    pub fn open(
        directory: impl AsRef<Path>,
        selected_names: impl IntoIterator<Item = impl AsRef<str>>,
    ) -> Result<Self, String> {
        let mut leaves = BTreeMap::new();
        for name in selected_names {
            let name = name.as_ref();
            DnsName::try_from(name).map_err(|_| format!("invalid selected DNS name: {name}"))?;
            leaves.insert(name.to_owned(), None);
        }
        Ok(Self {
            material: load(directory.as_ref())?,
            leaves: Mutex::new(leaves),
        })
    }

    /// Returns a leaf only for an exact name selected at startup.
    /// Leaves renew during the final day of their seven-day lifetime.
    pub fn leaf_for(&self, host: &str) -> Result<Arc<Leaf>, String> {
        self.leaf_at(host, OffsetDateTime::now_utc())
    }

    fn leaf_at(&self, host: &str, now: OffsetDateTime) -> Result<Arc<Leaf>, String> {
        let mut leaves = self
            .leaves
            .lock()
            .map_err(|_| "CA leaf cache lock poisoned")?;
        let slot = leaves
            .get_mut(host)
            .ok_or_else(|| format!("DNS name is not selected for interception: {host}"))?;
        let ca = &self.material;
        if now <= ca.not_before || now >= ca.not_after {
            return Err("CA certificate is not currently valid".to_owned());
        }
        if let Some(leaf) = slot
            && now < leaf.not_after - RENEW_BEFORE
        {
            return Ok(Arc::clone(leaf));
        }

        let key = Zeroizing::new(KeyPair::generate().map_err(mint_error)?);
        let mut parameters = CertificateParams::new(vec![host.to_owned()]).map_err(mint_error)?;
        parameters.not_before = now - CLOCK_SKEW;
        parameters.not_after = now + LEAF_VALIDITY;
        parameters.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        parameters.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        let issuer = Issuer::from_ca_cert_der(&ca.certificate, &*ca.key).map_err(mint_error)?;
        let certificate = parameters.signed_by(&*key, &issuer).map_err(mint_error)?;
        let leaf = Arc::new(Leaf {
            certificate: certificate.der().clone(),
            key: PrivatePkcs8KeyDer::from(key.serialize_der()),
            not_after: parameters.not_after,
        });
        *slot = Some(Arc::clone(&leaf));
        Ok(leaf)
    }
}

/// Loads the pair `init` created in `path`, refusing what `init` refuses
/// about the directory and the pair.
fn load(path: &Path) -> Result<Material, String> {
    directory::open_directory(path)?;
    let certificate_path = path.join(CA_CERTIFICATE);
    let key_path = path.join(CA_KEY);
    let (Some(mut certificate), Some(mut key)) = (
        storage::open_existing(&certificate_path)?,
        storage::open_existing(&key_path)?,
    ) else {
        return Err(format!(
            "{} must hold {CA_CERTIFICATE} and {CA_KEY}; create them with `airlock ca init`",
            path.display()
        ));
    };
    material::validate(&mut certificate, &mut key, &certificate_path, &key_path)
}

#[cfg(test)]
mod tests {
    use std::{fs, os::unix::fs::PermissionsExt as _};

    use super::*;
    use crate::ca::init;

    #[test]
    fn leaf_cache_renews_in_final_day_and_never_grows_for_unselected_names() {
        let root = tempfile::Builder::new()
            .permissions(fs::Permissions::from_mode(0o700))
            .tempdir()
            .expect("create private temporary root");
        let directory = root.path().join("ca");
        init(&directory).expect("create CA");
        let authority = Authority::open(&directory, ["api.example.test"]).expect("open authority");
        let now = OffsetDateTime::now_utc();
        let original = authority
            .leaf_at("api.example.test", now)
            .expect("mint leaf");
        let reused = authority
            .leaf_at("api.example.test", now + Duration::days(5))
            .expect("reuse leaf");
        assert!(Arc::ptr_eq(&original, &reused));
        assert_eq!(
            authority.leaves.lock().expect("cache lock")["api.example.test"]
                .as_ref()
                .expect("cached leaf")
                .not_after,
            now + Duration::days(7)
        );
        let renewed = authority
            .leaf_at("api.example.test", now + Duration::days(6))
            .expect("renew leaf");
        assert!(!Arc::ptr_eq(&original, &renewed));
        assert_eq!(
            authority.leaves.lock().expect("cache lock")["api.example.test"]
                .as_ref()
                .expect("renewed leaf")
                .not_after,
            now + Duration::days(13)
        );
        for index in 0..100 {
            assert!(
                authority
                    .leaf_at(&format!("{index}.example.test"), now)
                    .is_err()
            );
        }
        assert_eq!(authority.leaves.lock().expect("cache lock").len(), 1);
        assert!(
            authority
                .leaf_at("api.example.test", authority.material.not_after)
                .is_err()
        );
        assert!(
            authority
                .leaf_at("api.example.test", authority.material.not_before)
                .is_err()
        );
    }
}
