use base64::{engine::general_purpose::STANDARD, Engine as _};
use chrono::{DateTime, Duration, Utc};
use minisign_verify::{PublicKey, Signature};
use reqwest::{redirect::Policy, Client, Url};
use semver::Version;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{str::FromStr, time::Duration as StdDuration};

pub const FEED_URL: &str = "https://tokrate.dev/updates/headless/alpha.json";
pub const MAX_FEED_BYTES: usize = 64 * 1024;
pub const MAX_PACKAGE_BYTES: u64 = 128 * 1024 * 1024;
const RELEASE_BASE: &str = "https://github.com/mattivilola/tokrate-clients/releases/download";

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    #[serde(rename = "signedPayload")]
    signed_payload: String,
    signature: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Manifest {
    pub schema_version: u8,
    pub product: String,
    pub channel: String,
    pub version: String,
    pub release_sequence: u64,
    pub released_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub minimum_debian: u16,
    pub platforms: Platforms,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Platforms {
    #[serde(rename = "linux-x86_64-deb")]
    pub linux_x86_64_deb: Artifact,
    #[serde(rename = "linux-aarch64-deb")]
    pub linux_aarch64_deb: Artifact,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    pub url: String,
    pub size: u64,
    pub sha256: String,
}

impl Manifest {
    pub fn artifact_for_current_arch(&self) -> Result<&Artifact, String> {
        match std::env::consts::ARCH {
            "x86_64" => Ok(&self.platforms.linux_x86_64_deb),
            "aarch64" => Ok(&self.platforms.linux_aarch64_deb),
            _ => Err("This Linux architecture is not supported by the update feed.".into()),
        }
    }
}

pub fn parse_version(value: &str) -> Result<Version, String> {
    let version = Version::parse(value).map_err(|_| "Invalid release version.".to_owned())?;
    if version.to_string() != value || !version.pre.is_empty() || !version.build.is_empty() {
        return Err("Release versions must be canonical numeric major.minor.patch values.".into());
    }
    Ok(version)
}

pub fn validate_manifest(
    manifest: &Manifest,
    installed_version: &str,
    arch: &str,
    now: DateTime<Utc>,
) -> Result<(), String> {
    if manifest.schema_version != 1
        || manifest.product != "tokrate-headless"
        || manifest.channel != "alpha"
    {
        return Err(
            "The signed update feed has an unsupported product, channel, or schema.".into(),
        );
    }
    if manifest.release_sequence == 0 {
        return Err("The signed update feed has an invalid release sequence.".into());
    }
    let release = parse_version(&manifest.version)?;
    let installed = parse_version(installed_version)?;
    if release < installed {
        return Err("The signed update feed is older than the installed binary.".into());
    }
    if manifest.released_at > now + Duration::minutes(5)
        || manifest.expires_at <= now
        || manifest.expires_at <= manifest.released_at
        || manifest.expires_at - manifest.released_at > Duration::days(180)
    {
        return Err("The signed update feed has invalid or expired dates.".into());
    }
    if manifest.minimum_debian < 12 {
        return Err("The signed update feed declares an unsupported Debian minimum.".into());
    }
    if !matches!(arch, "x86_64" | "aarch64") {
        return Err("This Linux architecture is not supported by the update feed.".into());
    }
    validate_artifact(
        &manifest.platforms.linux_x86_64_deb,
        &manifest.version,
        "amd64",
    )?;
    validate_artifact(
        &manifest.platforms.linux_aarch64_deb,
        &manifest.version,
        "arm64",
    )?;
    Ok(())
}

fn validate_artifact(artifact: &Artifact, version: &str, suffix: &str) -> Result<(), String> {
    if artifact.size == 0 || artifact.size > MAX_PACKAGE_BYTES {
        return Err("The signed update feed declares an invalid package size.".into());
    }
    if artifact.sha256.len() != 64 || !artifact.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err("The signed update feed declares an invalid package digest.".into());
    }
    let expected = format!(
        "{RELEASE_BASE}/v{version}-headless-alpha.1/tokrate-headless_{version}_{suffix}.deb"
    );
    let parsed = Url::parse(&artifact.url).map_err(|_| "The signed update feed URL is invalid.")?;
    if artifact.url != expected
        || parsed.scheme() != "https"
        || parsed.host_str() != Some("github.com")
        || parsed.username() != ""
        || parsed.password().is_some()
        || parsed.port().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err("The signed update feed points to an unexpected package URL.".into());
    }
    Ok(())
}

fn public_key() -> Result<PublicKey, String> {
    // Tauri stores this same minisign public-key file as base64 text. Decode its one outer
    // layer, then hand the standard two-line minisign key to the verifier.
    let encoded = include_str!("../../../../desktop/updater-public-key.txt").trim();
    let key_text = STANDARD
        .decode(encoded)
        .map_err(|_| "The built-in update verification key is invalid.")?;
    let key_text = std::str::from_utf8(&key_text)
        .map_err(|_| "The built-in update verification key is invalid.")?;
    PublicKey::decode(key_text)
        .map_err(|_| "The built-in update verification key is invalid.".into())
}

pub fn verify_envelope(bytes: &[u8]) -> Result<(Manifest, Vec<u8>), String> {
    if bytes.is_empty() || bytes.len() > MAX_FEED_BYTES {
        return Err("The signed update feed is empty or too large.".into());
    }
    let envelope: Envelope = serde_json::from_slice(bytes)
        .map_err(|_| "The signed update feed envelope is malformed.")?;
    let payload = STANDARD
        .decode(envelope.signed_payload)
        .map_err(|_| "The signed update payload is malformed.")?;
    if payload.is_empty() || payload.len() > MAX_FEED_BYTES {
        return Err("The signed update payload is empty or too large.".into());
    }
    let signature = STANDARD
        .decode(envelope.signature)
        .map_err(|_| "The update signature is malformed.")?;
    if signature.len() > 8 * 1024 {
        return Err("The update signature is too large.".into());
    }
    let signature =
        std::str::from_utf8(&signature).map_err(|_| "The update signature is malformed.")?;
    let signature =
        Signature::decode(signature).map_err(|_| "The update signature is malformed.")?;
    public_key()?
        .verify(&payload, &signature, false)
        .map_err(|_| "The signed update feed did not verify.")?;
    let manifest = serde_json::from_slice::<Manifest>(&payload)
        .map_err(|_| "The signed update manifest is malformed.")?;
    Ok((manifest, payload))
}

pub async fn fetch_manifest(installed_version: &str) -> Result<Manifest, String> {
    let client = Client::builder()
        .redirect(Policy::none())
        .connect_timeout(StdDuration::from_secs(10))
        .timeout(StdDuration::from_secs(20))
        .user_agent("Tokrate-Headless updater")
        .build()
        .map_err(|_| "Could not prepare the secure update connection.")?;
    let url = Url::from_str(FEED_URL).expect("compile-time update feed URL");
    let response = client
        .get(url)
        .send()
        .await
        .map_err(|_| "Could not reach the Tokrate update service.")?;
    if response.status().is_redirection() {
        return Err("The Tokrate update service redirected the feed request.".into());
    }
    if !response.status().is_success() {
        return Err("The Tokrate update service returned an unsuccessful response.".into());
    }
    if response
        .content_length()
        .is_some_and(|length| length > MAX_FEED_BYTES as u64)
    {
        return Err("The signed update feed is too large.".into());
    }
    let mut response = response;
    let mut bytes = Vec::with_capacity(MAX_FEED_BYTES.min(16 * 1024));
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "Could not read the signed update feed.")?
    {
        if bytes.len().saturating_add(chunk.len()) > MAX_FEED_BYTES {
            return Err("The signed update feed is too large.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let (manifest, _) = verify_envelope(&bytes)?;
    validate_manifest(
        &manifest,
        installed_version,
        std::env::consts::ARCH,
        Utc::now(),
    )?;
    Ok(manifest)
}

pub async fn download_artifact(manifest: &Manifest) -> Result<Vec<u8>, String> {
    let artifact = manifest.artifact_for_current_arch()?;
    let client = Client::builder()
        .redirect(Policy::custom(|attempt| {
            if attempt.previous().len() >= 5 {
                return attempt.error("too many redirects");
            }
            let url = attempt.url();
            if url.scheme() == "https"
                && url.username().is_empty()
                && url.password().is_none()
                && url.port().is_none()
                && matches!(
                    url.host_str(),
                    Some("github.com")
                        | Some("release-assets.githubusercontent.com")
                        | Some("objects.githubusercontent.com")
                )
            {
                attempt.follow()
            } else {
                attempt.error("unexpected artifact redirect")
            }
        }))
        .connect_timeout(StdDuration::from_secs(10))
        .timeout(StdDuration::from_secs(120))
        .user_agent("Tokrate-Headless updater")
        .build()
        .map_err(|_| "Could not prepare the secure package download.")?;
    let response = client
        .get(&artifact.url)
        .send()
        .await
        .map_err(|_| "Could not download the verified Tokrate package.")?;
    if !response.status().is_success() {
        return Err("The Tokrate package download returned an unsuccessful response.".into());
    }
    if response
        .content_length()
        .is_some_and(|length| length != artifact.size)
    {
        return Err("The downloaded package size did not match the signed feed.".into());
    }
    let mut response = response;
    let mut bytes = Vec::with_capacity(artifact.size as usize);
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "Could not read the downloaded Tokrate package.")?
    {
        if bytes.len() as u64 + chunk.len() as u64 > artifact.size
            || bytes.len() as u64 + chunk.len() as u64 > MAX_PACKAGE_BYTES
        {
            return Err("The downloaded package exceeded the signed size.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.len() as u64 != artifact.size {
        return Err("The downloaded package size did not match the signed feed.".into());
    }
    let digest = hex::encode(Sha256::digest(&bytes));
    if !digest.eq_ignore_ascii_case(&artifact.sha256) {
        return Err("The downloaded package digest did not match the signed feed.".into());
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest() -> Manifest {
        let now = Utc::now();
        Manifest {
            schema_version: 1,
            product: "tokrate-headless".into(),
            channel: "alpha".into(),
            version: "0.1.28".into(),
            release_sequence: 1_797_000_000,
            released_at: now - Duration::minutes(5),
            expires_at: now + Duration::days(7),
            minimum_debian: 12,
            platforms: Platforms {
                linux_x86_64_deb: Artifact {
                    url: format!(
                        "{RELEASE_BASE}/v0.1.28-headless-alpha.1/tokrate-headless_0.1.28_amd64.deb"
                    ),
                    size: 1024,
                    sha256: "a".repeat(64),
                },
                linux_aarch64_deb: Artifact {
                    url: format!(
                        "{RELEASE_BASE}/v0.1.28-headless-alpha.1/tokrate-headless_0.1.28_arm64.deb"
                    ),
                    size: 1024,
                    sha256: "b".repeat(64),
                },
            },
        }
    }

    #[test]
    fn rejects_unsigned_or_changed_envelopes() {
        let raw = br#"{"signedPayload":"dGVzdA==","signature":""}"#;
        assert!(verify_envelope(raw).is_err());
        assert!(verify_envelope(br#"{"signedPayload":"dGVzdA==","signature":"%%%%"}"#).is_err());
        assert!(
            verify_envelope(br#"{"signedPayload":"dGVzdA==","signature":"","extra":true}"#)
                .is_err()
        );
    }

    #[test]
    fn manifest_requires_correct_identity_version_dates_and_artifact() {
        let now = Utc::now();
        let good = manifest();
        assert!(validate_manifest(&good, "0.1.27", "x86_64", now).is_ok());
        assert!(validate_manifest(&good, "0.1.28", "x86_64", now).is_ok());
        assert!(validate_manifest(&good, "0.1.29", "x86_64", now).is_err());
        assert!(validate_manifest(&good, "0.1.27-alpha.1", "x86_64", now).is_err());
        let mut invalid = good.clone();
        invalid.channel = "stable".into();
        assert!(validate_manifest(&invalid, "0.1.27", "x86_64", now).is_err());
        let mut invalid = good.clone();
        invalid.released_at = now + Duration::hours(1);
        assert!(validate_manifest(&invalid, "0.1.27", "x86_64", now).is_err());
        let mut invalid = good.clone();
        invalid.expires_at = now - Duration::seconds(1);
        assert!(validate_manifest(&invalid, "0.1.27", "x86_64", now).is_err());
        let mut invalid = good.clone();
        invalid.platforms.linux_x86_64_deb.url = "https://example.com/tokrate.deb".into();
        assert!(validate_manifest(&invalid, "0.1.27", "x86_64", now).is_err());
        let mut invalid = good.clone();
        invalid.platforms.linux_x86_64_deb.sha256 = "not-a-digest".into();
        assert!(validate_manifest(&invalid, "0.1.27", "x86_64", now).is_err());
        assert!(validate_manifest(&good, "0.1.27", "mips", now).is_err());
    }
}
