# Tokrate Headless for Debian

Tokrate Headless runs the existing Tokrate monitoring core as a system service
on a Debian 12 or newer server. It has no desktop or graphical-library
dependencies. Local monitoring is the default mode and makes no community
network requests. Community sharing runs as a separate service and requires
current consent plus a host-encrypted signing credential.

This is an initial Debian server alpha with native amd64 and arm64 packages.
It checks signed update availability daily by default after an explicit
installer run, independently of sharing consent. It never installs an update
automatically. Read the project privacy information and the
[shared metrics contract](../../docs/metrics-contract.md) before enabling
sharing or distributing a build; there is no stable-support promise.

## Install from a published release

On a Debian 12+ x64 or arm64 server, the one-line installer downloads a
version-pinned archive and checks its SHA-256 before running the bundled
installer:

```sh
curl -fsSL https://tokrate.dev/install-headless.sh | bash
```

A non-root caller installs for its current account and uses `sudo`. A root
shell must name the non-root account explicitly, for example
`curl -fsSL https://tokrate.dev/install-headless.sh | bash -s -- --user alice`.
Have `curl`, `ca-certificates`, `tar`, `coreutils` (for `sha256sum`), and
`dpkg` available; a non-root caller also needs `sudo`. Add `--local-only` or
`--share` for unattended setup; on first setup without either, the installer
presents the notice and asks once. Reruns without a mode reuse the saved
sharing choice. Community sharing is optional.

## Build and install from source

Install Rust stable, a C build toolchain, and systemd on a Debian 12+ machine.
From this repository, compile the headless binary:

```sh
cargo build --locked --release --manifest-path linux/headless/Cargo.toml
```

Then run the installer as root, naming the non-root account whose local
session files should be monitored. Choose a mode explicitly for unattended
installs:

```sh
sudo linux/headless/install.sh --user alice \
  --binary linux/headless/target/release/tokrate-headless --local-only
```

Use `--share` only after choosing community sharing. If neither mode is given
on first setup, setup displays the sharing notice and asks one yes/no question;
reruns reuse the saved sharing choice. It refuses a
root target account and does not infer the target from `sudo`. When `sudo` is
invoked by the same account named by `--user`, the installer passes supported
source-location variables such as `CODEX_HOME`, `CLAUDE_CONFIG_DIR`,
`GROK_HOME`, `KIMI_CODE_HOME`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME` into
setup. If your sudo policy filters them, preserve those names explicitly, for
example with `sudo --preserve-env=CODEX_HOME,CLAUDE_CONFIG_DIR,GROK_HOME,KIMI_CODE_HOME,XDG_CONFIG_HOME,XDG_DATA_HOME ...`.
Otherwise, setup uses the target account's normal defaults.

The installer stops both service modes before setup or configuration changes.
It runs setup as the target account in a private temporary directory, then
copies only `settings.json`, `setup-complete`, and—after an affirmative sharing
choice—`consent-v6.json` into `/etc/tokrate-headless/USER`. That directory is
root-owned and readable by the service account; the service cannot change the
authoritative consent marker. Runtime data is kept under
`/var/lib/tokrate-headless/USER` with mode `0700`.

The local service is `tokrate-headless-local@USER.service`. Its systemd sandbox
blocks IP networking, does not load a signing credential, and starts only when
the consent marker is absent. The share service is
`tokrate-headless-share@USER.service`; it starts only when the marker exists,
loads `signing-key` from the host-encrypted systemd credential store, and is
the only mode with IP networking enabled. On a fresh share install, the
installer creates the encrypted credential if none exists. If an existing
consent marker has lost its credential, installation fails closed and asks
for the original encrypted file to be restored; it does not silently create a
new signing identity.

## Optional Debian package

On Debian 12+ x64 or arm64, build a local `.deb` from the source and Rust
dependencies:

```sh
linux/headless/package.sh ./dist/headless
```

The package contains the compiled binary, both collector service templates,
the update-check service and timer, and a `tokrate-update` sysusers definition.
The update checker runs under that dedicated unprivileged, non-login system
account so its read-only status cache remains available after the oneshot exits.
Its post-install step provisions that account and reloads systemd's unit
definitions only; unpacking a package does not enable the collector or
update-check timer, create consent, or provision a key. After
installing the package with `dpkg -i`, run `install.sh` from the source
checkout with `--binary /usr/bin/tokrate-headless`, an explicit target user,
and a chosen mode. The published bootstrap archive includes the installer,
templates, sysusers definition, and account validator for a guided setup.

## Status and service operations

`status` prints JSON for the account's system configuration and state when run
as that account:

```sh
sudo -u alice -H /usr/bin/tokrate-headless status
```

The JSON includes whether the service is running, source paths, collection
state, sharing consent/activity, queued items, upload results, and cached
update availability with the separate automatic-check setting. Reading status
does not contact the update service. The
`uploaded_samples` and `uploaded_request_count_entries` counters are for the
current daemon process and reset when it restarts. `latest_turn` describes the
most recently completed local turn; its `turn_throughput_tps` is whole-turn
output tokens per second, including tool time and waiting. It is not response
speed while the model is generating.

For a live terminal view of collection state and recent measurements, run:

```sh
sudo -u alice -H /usr/bin/tokrate-headless status-monitor
```

Preview the screen with synthetic data:

```sh
sudo -u alice -H /usr/bin/tokrate-headless status-monitor --demo
```

Press **Q** or **Esc** to close the monitor; the demo does not use session logs
or upload measurements. Pressing **U** in the live monitor checks for an
available signed update and offers to install it; **U** is disabled in the
offline demo.

View service logs with:

```sh
sudo journalctl -u tokrate-headless-local@alice.service -f
sudo journalctl -u tokrate-headless-share@alice.service -f
```

Stop both units before setup, editing configuration, or provisioning a key:

```sh
sudo systemctl stop \
  tokrate-headless-local@alice.service \
  tokrate-headless-share@alice.service
```

To change modes, rerun `install.sh` with the same `--user` and the desired
`--local-only` or `--share` choice. The installer updates the consent marker,
reuses an existing encrypted key, and enables only the selected service. To
leave monitoring stopped after a mode change, disable the selected unit:

```sh
sudo systemctl disable --now tokrate-headless-local@alice.service
# or
sudo systemctl disable --now tokrate-headless-share@alice.service
```

## Software updates

The machine-wide update-check setting is stored in
`/etc/tokrate-headless/update-checks` and is independent of community sharing.
An explicit `install.sh` run creates it as `on` on first setup and preserves
its saved value on later runs. Package installation by itself never enables
the timer. Change the setting as root:

```sh
sudo /usr/bin/tokrate-headless update-checks on
sudo /usr/bin/tokrate-headless update-checks off
```

Run an immediate signed availability check at any time, including while
automatic checks are off:

```sh
/usr/bin/tokrate-headless check-update
```

The check updates a local public cache. `status` and the live monitor read that
cache without network access. They distinguish never checked, stale, failed,
up-to-date, and available results.

Installing remains an explicit action. Run `update` and confirm the prompt,
or press **U** in the live monitor. The updater verifies the signed manifest,
downloads the matching Debian package, checks its digest, and asks for
privilege to install it. It preserves the selected local/share mode, settings,
consent, encrypted identity, and collected history; it does not rerun setup.
Success output identifies the installed version change and confirms each
previously running service restarted and reported a fresh heartbeat, for
example `Updated 0.1.27 → 0.1.28; 2 services restarted and running.` If no
update is available it prints `Already up to date: VERSION` and does not
restart services. If verification, installation, or health checks fail, the
updater reports the failure and attempts to restore the previous binary and
previously running services.

## Installer checks

Run the focused unit and installer integration checks with:

```sh
python3 linux/headless/test-install.py
```

The Debian CI run also validates the systemd units and executes a root-only
install lifecycle check against a temporary staged root with a fake
`systemctl`, a disposable test account, and an encrypted-key roundtrip. It
does not alter the host's service files or install on a real server.

## Upload timing

The terminal monitor shows the latest successful report upload in UTC with its
relative age, plus the latest attempt and result. `status` JSON keeps the
attempt, latest failure, and latest success timestamps separate; the successful
timestamp survives a service restart. The sent counter is labeled as
since-restart state.

Headless report uploads use five-minute buckets, a one-minute wait after
closure, and up to one extra minute of shared random delay. Completed turns
normally arrive about 1–7 minutes later; sleep, offline collection and pending
subagent work can take longer. Completion timestamps remain rounded to five
minutes. No new telemetry fields or consent version are introduced.
