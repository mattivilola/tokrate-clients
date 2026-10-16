use futures_util::StreamExt;
use semver::Version;
use serde::Deserialize;
use std::time::Duration;
use tauri::Url;

use crate::updater_state::UpdateSummary;

const FEED_URL: &str = "https://tokrate.dev/updates/desktop/alpha.json";
const MAX_FEED_BYTES: usize = 256 * 1024;
const MAX_NOTES_BYTES: usize = 16 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const RELEASE_HOST: &str = "github.com";
const RELEASE_OWNER: &str = "mattivilola";
const RELEASE_REPOSITORY: &str = "tokrate-clients";

#[derive(Deserialize)]
struct UpdateFeed {
    version: String,
    #[serde(default)]
    notes: Option<String>,
    platforms: Platforms,
}

#[derive(Deserialize)]
struct Platforms {
    #[serde(rename = "linux-x86_64-deb")]
    linux_x86_64_deb: Option<DebPlatform>,
}

#[derive(Deserialize)]
struct DebPlatform {
    url: String,
    signature: String,
}

/// Check the fixed public feed for a Debian package. The client has no cookie store or credentials,
/// follows no redirects, and bounds both response time and memory used by the response body.
pub async fn check() -> Result<Option<UpdateSummary>, String> {
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|_| "Could not prepare the Debian update check".to_owned())?;

    let response = client
        .get(FEED_URL)
        .send()
        .await
        .map_err(|_| "Could not check the Debian update feed".to_owned())?;
    if !response.status().is_success()
        || response
            .content_length()
            .is_some_and(|length| length > MAX_FEED_BYTES as u64)
    {
        return Err("The Debian update feed could not be read".into());
    }

    let mut stream = response.bytes_stream();
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| "The Debian update feed could not be read".to_owned())?;
        if bytes.len().saturating_add(chunk.len()) > MAX_FEED_BYTES {
            return Err("The Debian update feed is too large".into());
        }
        bytes.extend_from_slice(&chunk);
    }

    parse_feed(&bytes, env!("CARGO_PKG_VERSION"))
}

/// Parse and validate the Debian platform record before exposing any version or download URL.
/// `None` means the feed is valid but does not offer a version newer than the installed build.
fn parse_feed(bytes: &[u8], current_version: &str) -> Result<Option<UpdateSummary>, String> {
    if bytes.len() > MAX_FEED_BYTES {
        return Err("The Debian update feed is too large".into());
    }
    let feed: UpdateFeed = serde_json::from_slice(bytes)
        .map_err(|_| "The Debian update feed is invalid".to_owned())?;
    let current = Version::parse(current_version)
        .map_err(|_| "The installed version is invalid".to_owned())?;
    let version = Version::parse(&feed.version)
        .map_err(|_| "The Debian update version is invalid".to_owned())?;
    let platform = feed
        .platforms
        .linux_x86_64_deb
        .ok_or_else(|| "The Debian package is missing from the update feed".to_owned())?;

    if platform.signature.trim().is_empty() || platform.signature.len() > 4096 {
        return Err("The Debian package signature metadata is invalid".into());
    }
    validate_deb_url(&platform.url, &feed.version)?;
    if feed
        .notes
        .as_ref()
        .is_some_and(|notes| notes.len() > MAX_NOTES_BYTES)
    {
        return Err("The Debian update notes are too large".into());
    }

    if !version.cmp_precedence(&current).is_gt() {
        return Ok(None);
    }

    Ok(Some(UpdateSummary {
        version: feed.version,
        body: feed.notes.filter(|notes| !notes.trim().is_empty()),
    }))
}

fn validate_deb_url(value: &str, version: &str) -> Result<(), String> {
    let url = Url::parse(value).map_err(|_| "The Debian package URL is invalid".to_owned())?;
    let segments: Vec<_> = url
        .path_segments()
        .ok_or_else(|| "The Debian package URL is invalid".to_owned())?
        .collect();
    let expected_asset = format!("Tokrate_{version}_amd64.deb");
    let valid_tag = segments
        .get(4)
        .is_some_and(|tag| release_tag_matches(tag, version));

    let trusted = url.scheme() == "https"
        && url.host_str() == Some(RELEASE_HOST)
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && segments.len() == 6
        && segments[0] == RELEASE_OWNER
        && segments[1] == RELEASE_REPOSITORY
        && segments[2] == "releases"
        && segments[3] == "download"
        && valid_tag
        && segments[5] == expected_asset.as_str();

    if !trusted {
        return Err(
            "The Debian package is not offered from Tokrate's trusted release location".into(),
        );
    }
    Ok(())
}

fn release_tag_matches(tag: &str, version: &str) -> bool {
    let stable_tag = format!("v{version}");
    if tag == stable_tag {
        return true;
    }

    let alpha_prefix = format!("{stable_tag}-desktop-alpha.");
    let Some(alpha_number) = tag.strip_prefix(&alpha_prefix) else {
        return false;
    };
    !alpha_number.is_empty()
        && alpha_number.bytes().all(|byte| byte.is_ascii_digit())
        && !alpha_number.starts_with('0')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(version: &str, url: &str, signature: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "version": version,
            "notes": "Debian update notes",
            "platforms": {
                "linux-x86_64-deb": { "url": url, "signature": signature }
            }
        }))
        .unwrap()
    }

    fn release_url(tag: &str, version: &str) -> String {
        format!(
            "https://github.com/mattivilola/tokrate-clients/releases/download/{tag}/Tokrate_{version}_amd64.deb"
        )
    }

    #[test]
    fn reports_a_newer_deb_with_notes_and_a_validated_download_url() {
        let bytes = feed(
            "0.1.28",
            &release_url("v0.1.28-desktop-alpha.2", "0.1.28"),
            "signed package metadata",
        );
        let update = parse_feed(&bytes, "0.1.27").unwrap().unwrap();
        assert_eq!(update.version, "0.1.28");
        assert_eq!(update.body.as_deref(), Some("Debian update notes"));
    }

    #[test]
    fn semantic_version_ordering_handles_equal_old_and_prerelease_versions() {
        let stable = feed(
            "0.1.27",
            &release_url("v0.1.27-desktop-alpha.1", "0.1.27"),
            "signature",
        );
        assert!(parse_feed(&stable, "0.1.27").unwrap().is_none());
        assert!(parse_feed(&stable, "0.1.28").unwrap().is_none());
        assert!(parse_feed(&stable, "0.1.27-rc.3").unwrap().is_some());

        let prerelease = feed(
            "0.1.28-alpha.2",
            &release_url("v0.1.28-alpha.2-desktop-alpha.1", "0.1.28-alpha.2"),
            "signature",
        );
        assert!(parse_feed(&prerelease, "0.1.28-alpha.1").unwrap().is_some());
        assert!(parse_feed(&prerelease, "0.1.28").unwrap().is_none());

        let build_metadata = feed(
            "0.1.27+build.2",
            &release_url("v0.1.27+build.2", "0.1.27+build.2"),
            "signature",
        );
        assert!(parse_feed(&build_metadata, "0.1.27+build.1")
            .unwrap()
            .is_none());
    }

    #[test]
    fn rejects_invalid_semver_and_non_project_or_wrong_version_asset_urls() {
        let valid = release_url("v0.1.28-desktop-alpha.1", "0.1.28");
        for bad_version in ["0.1", "v0.1.28", "0.1.028", "0.1.28+", "0.1.28-01"] {
            let bytes = feed(bad_version, &valid, "signature");
            assert!(parse_feed(&bytes, "0.1.27").is_err(), "{bad_version}");
        }

        let other_urls = [
            "https://evil.example/mattivilola/tokrate-clients/releases/download/v0.1.28/Tokrate_0.1.28_amd64.deb",
            "https://github.com/other/tokrate-clients/releases/download/v0.1.28/Tokrate_0.1.28_amd64.deb",
            "https://github.com/mattivilola/tokrate-headless/releases/download/v0.1.28/Tokrate_0.1.28_amd64.deb",
            "https://github.com/mattivilola/tokrate-clients/releases/download/v0.1.27/Tokrate_0.1.28_amd64.deb",
            "https://github.com/mattivilola/tokrate-clients/releases/download/v0.1.28/Tokrate_0.1.27_amd64.deb",
            "https://github.com/mattivilola/tokrate-clients/releases/download/v0.1.28/Tokrate_0.1.28_amd64.deb?mirror=evil",
        ];
        for bad_url in other_urls {
            let bytes = feed("0.1.28", bad_url, "signature");
            assert!(parse_feed(&bytes, "0.1.27").is_err(), "{bad_url}");
        }
    }

    #[test]
    fn requires_signature_metadata_and_rejects_oversized_feed() {
        let url = release_url("v0.1.28", "0.1.28");
        assert!(parse_feed(&feed("0.1.28", &url, " "), "0.1.27").is_err());
        assert!(parse_feed(&vec![b' '; MAX_FEED_BYTES + 1], "0.1.27").is_err());
    }
}
