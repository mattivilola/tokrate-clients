use crate::config::{Paths, Result};
use rand::{rngs::OsRng, RngCore};
use std::{
    env, fs,
    io::Write,
    path::Path,
    process::{Command, Stdio},
};
use tokrate_core::{read_private_file, write_private_file};
use zeroize::Zeroizing;

pub fn load(paths: &Paths) -> Result<Zeroizing<[u8; 32]>> {
    // This check precedes even looking up the credential directory.
    if !paths.consent_valid() {
        return Err("Current sharing consent is required".into());
    }
    let dir = env::var_os("CREDENTIALS_DIRECTORY")
        .ok_or("Signing credential unavailable; use the Debian systemd installer")?;
    let bytes = Zeroizing::new(
        read_private_file(Path::new(&dir).join("signing-key"), 32).map_err(|_| {
            "Signing credential unreadable; repair it without resetting the identity"
        })?,
    );
    let mut seed = Zeroizing::new([0u8; 32]);
    if bytes.len() != seed.len() {
        return Err("Invalid signing credential length; identity was not replaced".into());
    }
    seed.copy_from_slice(&bytes);
    Ok(seed)
}

pub fn provision(paths: &Paths, output: &Path) -> Result<()> {
    if !paths.consent_valid() {
        return Err("Accept sharing before provisioning a signing identity".into());
    }
    #[cfg(unix)]
    if unsafe { libc::geteuid() } != 0 {
        return Err(
            "Encrypted host credentials must be provisioned as root by the installer".into(),
        );
    }
    if let Ok(metadata) = fs::symlink_metadata(output) {
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err("Credential output must be a regular file".into());
        }
        println!("Existing encrypted identity preserved.");
        write_private_file(paths.config.join("identity-provisioned"), b"1\n")?;
        return Ok(());
    }
    if paths.config.join("identity-provisioned").try_exists()? {
        return Err("Signing identity was previously provisioned; restore the missing encrypted credential instead of replacing it".into());
    }
    let parent = output
        .parent()
        .ok_or("Credential output needs a parent directory")?;
    fs::create_dir_all(parent)?;
    let mut seed = Zeroizing::new([0u8; 32]);
    OsRng.fill_bytes(seed.as_mut());
    let mut child = Command::new("systemd-creds")
        .args(["encrypt", "--name=signing-key", "--with-key=host", "-", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "systemd-creds unavailable (Debian 12+ is required)")?;
    child
        .stdin
        .take()
        .ok_or("Credential pipe unavailable")?
        .write_all(seed.as_ref())?;
    let result = child.wait_with_output()?;
    if !result.status.success() || result.stdout.is_empty() || result.stdout.len() > 65_536 {
        return Err("Could not encrypt signing identity; no plaintext fallback was used".into());
    }
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.write_all(&result.stdout)?;
    file.as_file().sync_all()?;
    file.persist_noclobber(output)
        .map_err(|_| "Could not store encrypted identity without overwriting a file")?;
    write_private_file(paths.config.join("identity-provisioned"), b"1\n")?;
    println!("Encrypted signing identity created.");
    Ok(())
}
