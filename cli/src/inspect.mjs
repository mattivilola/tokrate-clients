import path from 'node:path';

export const DOWNLOAD = 'https://tokrate.dev/download';
const namePattern = /^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$/;

export function osRelease(text) {
  const values = {};
  for (const line of (text ?? '').split('\n')) {
    const match = /^(ID|VERSION_ID)=(?:"([^"]*)"|'([^']*)'|([^\s#]*))$/.exec(line);
    if (match) values[match[1]] = match[2] ?? match[3] ?? match[4];
  }
  return values;
}

export async function desktopInfo(host) {
  const join = host.platform === 'win32' ? path.win32.join : path.posix.join;
  let candidates = [];
  if (host.platform === 'darwin') candidates = ['/Applications/Tokrate.app', join(host.home, 'Applications/Tokrate.app')];
  if (host.platform === 'win32') candidates = [host.env.LOCALAPPDATA, host.env.ProgramFiles]
    .filter(Boolean).map((dir) => join(dir, 'Tokrate', 'tokrate-desktop.exe'));
  if (host.platform === 'linux') candidates = ['/usr/bin/tokrate-desktop', '/usr/local/bin/tokrate-desktop', join(host.home, '.local/bin/tokrate-desktop')];
  let installedPath = null;
  for (const candidate of candidates) if (await host.exists(candidate)) { installedPath = candidate; break; }
  let running = null;
  if (['linux', 'darwin'].includes(host.platform)) {
    const result = await host.exec('ps', ['-U', String(host.uid), '-o', 'comm=']);
    if (result.code === 0 && !result.error) running = result.stdout.split('\n').some((line) => {
      const command = line.trim();
      return host.platform === 'darwin' ? command.endsWith('/Tokrate.app/Contents/MacOS/Tokrate')
        : path.posix.basename(command) === 'tokrate-desktop';
    });
  } else if (host.platform === 'win32') {
    const account = host.env.USERDOMAIN ? `${host.env.USERDOMAIN}\\${host.user}` : host.user;
    const result = await host.exec('tasklist.exe', ['/FI', 'IMAGENAME eq tokrate-desktop.exe', '/FI', `USERNAME eq ${account}`, '/FO', 'CSV', '/NH']);
    if (result.code === 0 && !result.error) running = /^"tokrate-desktop\.exe",/im.test(result.stdout);
  }
  return { installed: Boolean(installedPath) || running === true, path: installedPath, running,
    sharing: 'unknown', monitoring: 'unknown' };
}

export async function inspect(host, options) {
  const target = options.user ?? host.user;
  if (options.user && !namePattern.test(options.user)) throw Error('--user contains unsupported characters');
  if (options.user && host.uid !== 0 && options.user !== host.user) throw Error('A non-root run can access only the current account');
  let targetUid = host.uid, accountError = null;
  if (options.user && host.uid === 0) {
    const account = await host.exec('id', ['-u', options.user]);
    if (account.code !== 0 || account.error || !/^[1-9]\d*\s*$/.test(account.stdout)) accountError = '--user must identify an existing non-root account.';
    else targetUid = Number(account.stdout.trim());
  }
  // Root setup checks the target account's processes, not root's desktop session.
  const desktop = await desktopInfo({ ...host, uid: targetUid, user: target });
  const binary = '/usr/bin/tokrate-headless';
  const headlessInstalled = host.platform === 'linux' && await host.exists(binary);
  const graphical = Boolean(host.env.DISPLAY || host.env.WAYLAND_DISPLAY);
  const mode = options.mode ?? (host.platform === 'linux' && (headlessInstalled || !graphical) ? 'headless' : 'desktop');
  const errors = [], warnings = [], prerequisites = [];
  if (desktop.running === null) warnings.push('Desktop process state is unknown; local process listing may be restricted.');
  if (mode !== 'headless' && (options.user || options.sharing)) throw Error('--user, --share and --local-only require headless mode');
  if (mode === 'headless' && host.uid === 0 && !options.user) errors.push('Root must name the non-root coding-agent account with --user USER.');
  if (accountError) errors.push(accountError);
  let supported = false;
  if (mode === 'headless') {
    const os = host.platform === 'linux' ? osRelease(await host.read('/etc/os-release')) : {};
    supported = host.platform === 'linux' && ['x64', 'arm64'].includes(host.arch)
      && os.ID === 'debian' && /^\d+(?:\.\d+)*$/.test(os.VERSION_ID ?? '') && Number.parseInt(os.VERSION_ID, 10) >= 12;
    if (!supported) errors.push('Headless requires Debian 12+ with systemd on x64 or arm64.');
    if (host.platform === 'linux') {
      if (!await host.exists('/run/systemd/system')) errors.push('A running systemd system manager is required for headless installation.');
      for (const command of ['bash', 'curl', 'sha256sum', 'tar', 'dpkg', 'mktemp', 'systemctl', ...(host.uid === 0 ? ['runuser'] : ['sudo'])]) {
        const found = Boolean(await host.which(command));
        prerequisites.push({ command, found });
        if (!found) errors.push(`Required command is missing: ${command}.`);
      }
      if (!await host.which('systemd-creds')) warnings.push('systemd-creds is unavailable; community sharing needs encrypted systemd credentials.');
    }
  } else {
    supported = (host.platform === 'darwin' && host.arch === 'arm64' && Number.parseInt(host.release, 10) >= 23)
      || (host.platform === 'win32' && host.arch === 'x64' && Number(host.release.split('.')[2]) >= 22000)
      || (host.platform === 'linux' && host.arch === 'x64');
    if (!supported) errors.push('Desktop targets macOS 14+ Apple silicon, Windows 11 x64, or Ubuntu 22.04-compatible Linux x64.');
    if (host.platform === 'linux' && !graphical) warnings.push('No graphical session detected. Desktop setup needs a desktop session.');
    warnings.push('Desktop sharing and collection state are available in the app; this CLI cannot verify them.');
  }
  const headless = { installed: headlessInstalled, status: null, error: null };
  // Native status reads local operational state. It does not load a signing key or contact the API.
  if (headlessInstalled && !(host.uid === 0 && (!options.user || errors.some((error) => error.startsWith('--user'))))) {
    const result = host.uid === 0
      ? await host.exec('runuser', ['-u', target, '--', binary, 'status'])
      : await host.exec(binary, ['status']);
    try {
      if (result.code !== 0 || result.error) throw Error('Native headless status could not be read. Run tokrate-headless status as the coding-agent account.');
      const status = JSON.parse(result.stdout);
      if (!status || Array.isArray(status) || typeof status !== 'object'
        || typeof status.running !== 'boolean' || typeof status.sharing_consent !== 'boolean') throw Error();
      headless.status = status;
    } catch {
      headless.error = 'Native headless status is unavailable or invalid; collection and sharing state are unknown.';
      if (mode === 'headless') warnings.push(headless.error);
    }
  }
  if (desktop.running === true && headless.status?.running === true) errors.push('Both desktop and headless collectors are running. Stop one in its native controls to avoid duplicate collection.');
  return { platform: host.platform, arch: host.arch, mode, account: target, supported,
    desktop, headless, prerequisites, errors, warnings };
}
