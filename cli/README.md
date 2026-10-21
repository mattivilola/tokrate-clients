# Tokrate npm CLI

The `tokrate` npm package is a small, dependency-free setup and diagnostics CLI
for the existing native clients. Requires Node.js 22 or later. Its version is
independent of the Mac, desktop and headless client versions.

Run without a permanent CLI installation:

```sh
npx tokrate@latest connect
npx tokrate@latest status
npx tokrate@latest doctor
```

Or install the command permanently:

```sh
npm install -g tokrate
tokrate connect
```

Installing the npm package does not start a collector, read coding
logs, create a reporting identity or grant sharing consent. There are no npm
install hooks. `status` and `doctor` perform local checks only; they do not
contact Tokrate, GitHub or npm. `npx` itself may contact the npm registry to fetch
the CLI, independently of sharing.

## Connect

On **Debian 12+ with systemd, x64/arm64**, `connect --headless` invokes the exact
`linux/headless/bootstrap.sh` shipped in this package. It retains pinned native
archive SHA-256 verification, non-root service ownership, encrypted signing
credentials, existing identities and the original sharing notice. A non-root
caller installs for their own account using sudo. A root caller must specify
the coding-agent account with `--user alice`; the CLI never infers it from
`SUDO_USER`. Source-location environment variables continue through the existing
installer. A running collector is reused without a reinstall when no sharing
flag was supplied.

```sh
tokrate connect --headless                         # interactive native sharing choice
tokrate connect --headless --local-only            # unattended, no community reporting
tokrate connect --headless --share                 # explicit opt-in via native setup
tokrate connect --headless --user alice --share    # from a root shell
```

An unattended first setup must choose `--local-only` or `--share`. Saved OFF
remains OFF unless the user explicitly changes it. The native installer also
configures its separate update-availability checks; installing updates remains
an explicit action. The CLI verifies native status after the installer returns
and does not call a stopped or unverified service a successful connection.
For ongoing service operations and current consent requirements, see the
[headless README](https://github.com/mattivilola/tokrate-clients/blob/main/linux/headless/README.md).

On **macOS 14+ Apple silicon, Windows 11 x64, or Ubuntu 22.04-compatible Linux
x64 desktops**, `connect --desktop` opens a detected existing app, or opens
[the official download page](https://tokrate.dev/download). The user completes
installation with the existing platform installer, then makes the existing
first-launch sharing choice in the app. The CLI does not download or execute
desktop installers itself, bypass OS signing checks, change preferences or
provide headless support on these other platforms. Windows/Linux desktop
remain alpha; Windows installers are not Authenticode-signed. Use
`connect --desktop --no-open` to print instructions without launching anything.
Headless consent flags and `--user` are rejected in desktop mode.

Linux automatically selects an installed headless client; otherwise it selects
headless without `DISPLAY`/`WAYLAND_DISPLAY`, or desktop with a graphical
session. Specify `--headless` or `--desktop` to override. Running desktop and
headless collectors must be resolved using their native controls before the
CLI starts another collector. Unknown process/status checks remain unknown
and block collector startup; the CLI never stops an existing collector.

## Local status and doctor

```sh
tokrate status --json
tokrate doctor --json
tokrate status --headless --user alice --json  # root inspects Alice via runuser
```

Headless status delegates to `/usr/bin/tokrate-headless status` as the target
account and includes its local JSON under `headless.status`. This can contain
local source/configuration paths; inspect it before sharing diagnostic output.
No keychain or signing credential is accessed. Desktop diagnostics detect
standard installation paths and the current account's process; sharing and
collection state remain **unknown**, with an explanation to check the app.
Custom install paths/AppImages may not be found unless the process is running.
No raw coding-tool logs or app preferences are inspected by this wrapper.

`doctor` checks platform support, headless installer prerequisites, systemd,
installation, stopped/duplicate collectors and native source/history errors.
It warns on stale/unknown heartbeats and reported upload failures. Local-only
use is valid. It does not repair anything or claim successful community uploads
based on a running process. Both commands support `--json`; errors exit 1,
warnings alone exit 0, and `status` can describe an uninstalled client without
failing. Installer failures preserve the installer's exit code. CLI usage
errors exit 1. Desktop runtime/integration acceptance is separate from these
local checks.

## Develop and publish

From the repository root:

```sh
npm ci --ignore-scripts
npm test
npm run test:package
npm publish --dry-run --access public
```

Tests mock desktop launches and native installers. The package smoke check
packs the actual allowlisted files, installs that tarball in a disposable
directory with hooks disabled, exercises its executable, and checks the
bundled installer byte-for-byte. It never installs a native collector or
publishes. CI runs these checks on Linux, macOS and Windows with Node 22/24.

Before a release, check the bundled bootstrap's version and native release
hashes correspond to **published, verified** archives. The npm CLI carries a
snapshot of that installer; publish a new CLI version when its native release
pins change. The package `files` allowlist excludes all desktop builds, coding
logs, tests, private configuration and signing material. The existing root
README and MIT license are included automatically.

An authorized npm maintainer must claim/control the `tokrate` package name,
authenticate to the public registry with the required account protections,
and run `npm publish --access public` from the root after validation. Check
name ownership again immediately before the first publish. No npm token or
new credential is needed to develop, test or pack. Subsequent releases must use a new
package version. Native release publication remains governed by its existing
platform verification and signing gates.

Uninstalling the npm package only removes the CLI. A native app or systemd
service installed through `connect` remains installed and retains its settings;
manage it through the existing native installation/service instructions.
