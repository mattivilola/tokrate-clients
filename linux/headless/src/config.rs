use chrono::{DateTime, Utc};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    env, fs,
    fs::File,
    io,
    path::{Path, PathBuf},
};
use tokrate_core::{read_private_file, write_private_file, SourceMonitor, MAX_SMALL_FILE_BYTES};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
pub const NOTICE_VERSION: &str = "2026-10-14-v6";
pub const CONSENT_FILE: &str = "consent-v6.json";
pub const NOTICE: &str = "Tokrate community sharing (notice 2026-10-14-v6)\n\
Reads supported coding-tool logs locally. Sends only derived measurements: coding tool and\n\
versions, model/provider/effort, primary/subagent category, token counts (including delegated\n\
and prompt-cache counts), turn/response/first-token timing where available, tool surface\n\
category, five-minute time buckets and random sample IDs. Model names are sent as the tool\n\
reports them; unusual characters become unknown. Custom deployment names may be shared.\n\
Also sends five-minute counts of successful, overloaded, server-error and throttled requests;\n\
never error messages or plan usage. No prompts, answers, code, paths, raw session IDs or logs\n\
are uploaded. A persistent pseudonymous signing identity links this installation's reports.\n\
The server derives a continent from the connection through Cloudflare; it stores neither the\n\
country nor IP in measurements. Public regional data requires at least three contributors;\n\
other early aggregates may have one. Hosting/network providers still process connection data.\n\
Only new observations after sharing starts are eligible; no historical backfill. Uploads are\n\
delayed to five-minute slots with random jitter. Pending reports stay in bounded memory.\n\
Local normalized history lasts seven days (up to 50,000 turns); server samples expire after\n\
30 days via asynchronous TTL. Stopping sharing clears pending reports, not received reports\n\
or backups. No automatic updates. Privacy: https://tokrate.dev/privacy\n\
Terms: https://tokrate.dev/terms\n\
Use `tokrate-headless example` to inspect the exact allowlisted payload with fake values.\n";

#[derive(Clone, Debug)]
pub struct Paths {
    pub config: PathBuf,
    pub data: PathBuf,
}

fn env_path(name: &str, fallback: PathBuf) -> PathBuf {
    env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or(fallback)
}

pub fn home() -> Result<PathBuf> {
    let path = env::var_os("HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .ok_or("HOME must identify the coding-agent user's home")?;
    if !path.is_absolute() {
        return Err("HOME must be absolute".into());
    }
    Ok(path)
}

impl Paths {
    pub fn defaults() -> Result<Self> {
        let home = home()?;
        // Installed services use the login account's system-managed configuration. Detect it
        // using the effective UID, never a caller-controlled USER or SUDO_USER value.
        if let Some(name) = account_name() {
            let config = PathBuf::from("/etc/tokrate-headless").join(&name);
            if config.join("settings.json").is_file() {
                return Ok(Self {
                    config,
                    data: PathBuf::from("/var/lib/tokrate-headless").join(name),
                });
            }
        }
        Ok(Self {
            config: env_path("XDG_CONFIG_HOME", home.join(".config")).join("tokrate-headless"),
            data: env_path("XDG_STATE_HOME", home.join(".local/state")).join("tokrate-headless"),
        })
    }
    pub fn consent(&self) -> PathBuf {
        self.config.join(CONSENT_FILE)
    }
    pub fn consent_valid(&self) -> bool {
        read_private_file(self.consent(), MAX_SMALL_FILE_BYTES)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Consent>(&bytes).ok())
            .is_some_and(|c| c.notice_version == NOTICE_VERSION && c.accepted_at <= Utc::now())
    }
    pub fn load(&self) -> Result<Settings> {
        let bytes = read_private_file(self.config.join("settings.json"), MAX_SMALL_FILE_BYTES)
            .map_err(|_| "Settings unavailable; run setup first")?;
        let settings: Settings =
            serde_json::from_slice(&bytes).map_err(|_| "Invalid settings; run setup again")?;
        if settings.schema_version != 1
            || settings.roots().iter().any(|(_, root)| !root.is_absolute())
        {
            return Err("Unsupported settings or non-absolute source path".into());
        }
        Ok(settings)
    }
    pub fn lock(&self) -> Result<File> {
        private_dir(&self.data)?;
        #[cfg(unix)]
        use std::os::unix::fs::OpenOptionsExt;
        let mut options = fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        let file = options.open(self.data.join("daemon.lock"))?;
        if !file.metadata()?.is_file() {
            return Err("Invalid daemon lock".into());
        }
        file.try_lock_exclusive().map_err(|_| {
            "Tokrate is running; stop its systemd service before setup or starting another instance"
        })?;
        Ok(file)
    }
}

fn account_name() -> Option<String> {
    let mut buffer = vec![0u8; 16_384];
    let mut record = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    // getpwuid_r writes the record and its strings into the supplied live buffer.
    let code = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            record.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if code != 0 || result.is_null() {
        return None;
    }
    let record = unsafe { record.assume_init() };
    if record.pw_name.is_null() {
        return None;
    }
    let name = unsafe { std::ffi::CStr::from_ptr(record.pw_name) }
        .to_str()
        .ok()?;
    if name.is_empty() || name.contains('/') || name == "." || name == ".." {
        return None;
    }
    Some(name.to_owned())
}

pub fn private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    if fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err("State/config directory must not be a symlink".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Consent {
    notice_version: String,
    accepted_at: DateTime<Utc>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    schema_version: u8,
    pub codex: PathBuf,
    pub claude: PathBuf,
    pub grok: PathBuf,
    pub antigravity: PathBuf,
    pub opencode: PathBuf,
    pub kimi: PathBuf,
    pub kimi_desktop: PathBuf,
    pub t3: PathBuf,
}
impl Settings {
    pub fn defaults() -> Result<Self> {
        let home = home()?;
        Ok(Self {
            schema_version: 1,
            codex: env_path("CODEX_HOME", home.join(".codex")).join("sessions"),
            claude: env_path("CLAUDE_CONFIG_DIR", home.join(".claude")).join("projects"),
            grok: env_path("GROK_HOME", home.join(".grok")).join("sessions"),
            antigravity: home.join(".gemini"),
            opencode: env_path("XDG_DATA_HOME", home.join(".local/share")).join("opencode"),
            kimi: env_path("KIMI_CODE_HOME", home.join(".kimi-code")),
            kimi_desktop: env_path("XDG_CONFIG_HOME", home.join(".config"))
                .join("kimi-desktop/daimon-share/daimon/runtime/kimi-code/home"),
            t3: home.join(".t3/userdata"),
        })
    }
    pub fn roots(&self) -> Vec<(&str, &Path)> {
        vec![
            ("codex", &self.codex),
            ("claude-code", &self.claude),
            ("grok-build", &self.grok),
            ("antigravity", &self.antigravity),
            ("opencode", &self.opencode),
            ("kimi-code", &self.kimi),
            ("kimi-desktop", &self.kimi_desktop),
            ("t3-code", &self.t3),
        ]
    }
    pub fn monitor(&self) -> SourceMonitor {
        SourceMonitor::new_with_t3_roots(
            self.codex.clone(),
            self.claude.clone(),
            self.grok.clone(),
            self.antigravity.clone(),
            self.opencode.clone(),
            self.kimi.clone(),
            self.kimi_desktop.clone(),
            Some(self.t3.clone()),
            Some(self.t3.join("providers/antigravity")),
        )
    }
}

pub fn setup(paths: &Paths, choice: Option<bool>) -> Result<()> {
    use std::io::{IsTerminal, Write};
    let _lock = paths.lock()?;
    if choice.is_none() && paths.config.join("setup-complete").is_file() {
        paths.load()?;
        println!(
            "Setup already complete. Sharing {}. Use --share or --local-only to change it.",
            if paths.consent_valid() { "on" } else { "off" }
        );
        return Ok(());
    }
    println!("{NOTICE}");
    let share = match choice {
        Some(value) => value,
        None => {
            if !io::stdin().is_terminal() {
                return Err(
                    "Interactive setup needs a terminal; use --share or --local-only explicitly"
                        .into(),
                );
            }
            print!("Share new measurements with the Tokrate community? [y/N] ");
            io::stdout().flush()?;
            let mut answer = String::new();
            io::stdin().read_line(&mut answer)?;
            matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes")
        }
    };
    private_dir(&paths.config)?;
    // Preserve configured custom roots on reconfiguration; corrupt settings are not overwritten.
    let settings = if paths.config.join("settings.json").try_exists()? {
        paths.load()?
    } else {
        Settings::defaults()?
    };
    write_private_file(
        paths.config.join("settings.json"),
        &serde_json::to_vec_pretty(&settings)?,
    )?;
    if share {
        write_private_file(
            paths.consent(),
            &serde_json::to_vec(&Consent {
                notice_version: NOTICE_VERSION.into(),
                accepted_at: Utc::now(),
            })?,
        )?;
    } else {
        match fs::remove_file(paths.consent()) {
            Ok(()) => (),
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.into()),
        }
    }
    write_private_file(paths.config.join("setup-complete"), b"1\n")?;
    println!(
        "Setup saved. Sharing {}. Source folders use this account's defaults; status lists them.",
        if share { "on" } else { "off" }
    );
    Ok(())
}
