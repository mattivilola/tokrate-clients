import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { DOWNLOAD, inspect } from './inspect.mjs';

const { version } = JSON.parse(await readFile(new URL('../../package.json', import.meta.url), 'utf8'));
export const HELP = `Tokrate ${version} — native client setup and local diagnostics

Usage: tokrate connect|status|doctor [options]
  connect       Install Debian headless, open an installed app, or open downloads
  status        Show local installation and collector state (no network requests)
  doctor        Check local support, prerequisites and collector problems

Options:
  --headless    Use the Debian 12+ x64/arm64 systemd collector
  --desktop     Use the existing desktop app and its first-launch sharing choice
  --user USER   Headless target account (root must name a non-root account)
  --share       Headless connect: explicit opt-in through the native installer
  --local-only  Headless connect: keep community sharing off
  --no-open     Desktop connect: print instructions without opening anything
  --json        status/doctor: machine-readable local diagnostics
  --help        Show help
  --version     Show the npm CLI version (independent of native client versions)

Installing this npm package does not start monitoring or enable sharing.
Headless connect uses sudo when needed; desktop installation finishes in the
native installer. Without mode flags Linux prefers an installed headless client,
then headless without DISPLAY/WAYLAND_DISPLAY, otherwise desktop.
`;

export function parse(argv) {
  if (argv.length === 0 || (argv.length === 1 && ['--help', '-h'].includes(argv[0]))) return { help: true };
  if (argv.length === 1 && ['--version', '-v'].includes(argv[0])) return { version: true };
  const [command, ...flags] = argv;
  if (!['connect', 'status', 'doctor'].includes(command)) throw Error('Unknown command; use tokrate --help');
  const options = { command };
  const seen = new Set();
  for (let index = 0; index < flags.length; index++) {
    const flag = flags[index];
    if (seen.has(flag)) throw Error(`Repeated option: ${flag}`);
    seen.add(flag);
    if (flag === '--help' || flag === '-h') { options.help = true; continue; }
    if (flag === '--headless' || flag === '--desktop') {
      if (options.mode) throw Error('Choose only one of --headless or --desktop');
      options.mode = flag.slice(2);
    } else if (flag === '--share' || flag === '--local-only') {
      if (options.sharing) throw Error('Choose only one of --share or --local-only');
      options.sharing = flag;
    } else if (flag === '--user') {
      const value = flags[++index];
      if (!value || value.startsWith('-')) throw Error('--user requires a username');
      options.user = value;
    } else if (flag === '--json') options.json = true;
    else if (flag === '--no-open') options.noOpen = true;
    else throw Error(`Unknown option: ${flag}`);
  }
  if (options.help) return options;
  if (command === 'connect' && options.json) throw Error('--json is available for status and doctor');
  if (command !== 'connect' && (options.sharing || options.noOpen)) throw Error('--share, --local-only and --no-open are connect options');
  return options;
}

export async function run(argv, host) {
  const options = parse(argv);
  if (options.help) { host.print(HELP); return 0; }
  if (options.version) { host.print(version); return 0; }
  const report = { cliVersion: version, ...await inspect(host, options) };
  if (options.noOpen && report.mode === 'headless') throw Error('--no-open is a desktop option');
  if (options.command === 'connect') return await connect(host, options, report);
  const native = report.headless.status;
  const installed = report.mode === 'headless' ? report.headless.installed : report.desktop.installed;
  if (options.command === 'doctor') {
    if (!installed) report.errors.push('Tokrate is not installed in a standard location. Run tokrate connect to set it up.');
    if (report.mode === 'headless' && installed) {
      if (report.headless.error) report.errors.push(report.headless.error);
      if (native && native.running !== true) report.errors.push('Headless collector is stopped. Inspect its systemd service before restarting it.');
      if (native?.running === true && native.monitoring === false) report.warnings.push('The collector is running but monitoring is paused.');
      if (native?.source_error) report.errors.push('The native collector reports a source-reading error. Inspect its service logs locally.');
      if (native?.history_error) report.errors.push('The native collector reports a local-history error. Inspect its service logs locally.');
      if (native?.running === true) {
        const age = (host.now?.() ?? Date.now()) - Date.parse(native.updated_at);
        if (!Number.isFinite(age)) report.warnings.push('Collector heartbeat age is unknown.');
        else if (age > 180_000 || age < -60_000) report.warnings.push('Collector heartbeat is stale or its timestamp differs from the system clock.');
      }
      if (native?.last_upload_result && /fail|error|upgrade-required/.test(native.last_upload_result)) report.warnings.push(`Last upload result: ${native.last_upload_result}`);
    }
  }
  if (options.json) host.print(JSON.stringify(report, null, 2)); else printReport(host, report);
  return report.errors.length || (report.mode === 'headless' && report.headless.error) ? 1 : 0;
}

function printReport(host, report) {
  host.print(`Tokrate CLI ${version} · ${report.platform}/${report.arch} · ${report.mode} · ${report.account}`);
  if (report.mode === 'headless') {
    const native = report.headless.status;
    host.print(`Installed: ${report.headless.installed ? 'yes' : 'no'}${native?.version ? ` (${native.version})` : ''}`);
    host.print(`Collector: ${native ? (native.running === true ? 'running' : native.running === false ? 'stopped' : 'unknown') : 'unknown'}`);
    host.print(`Sharing: ${native ? (native.sharing_active === true ? 'active' : native.sharing_active === false ? 'inactive' : 'unknown') : 'unknown'}`);
    if (native?.sharing_consent === false) host.print('Current sharing consent: off or not accepted. Local-only use is supported.');
    if (native?.last_upload_result) host.print(`Last upload result: ${native.last_upload_result}`);
  } else {
    host.print(`Desktop installed: ${report.desktop.installed ? 'yes' : 'not found in standard locations'}`);
    host.print(`Desktop process: ${report.desktop.running === null ? 'unknown' : report.desktop.running ? 'running' : 'not detected'}`);
  }
  for (const error of report.errors) host.print(`Problem: ${error}`);
  for (const warning of report.warnings) host.print(`Note: ${warning}`);
}

async function connect(host, options, report) {
  if (report.errors.length) { printReport(host, report); return 1; }
  if (report.mode === 'desktop' && options.noOpen) {
    printReport(host, report);
    host.print(`Desktop setup: ${DOWNLOAD}`);
    host.print('Open your existing Tokrate app, or install the native package and choose sharing or local-only use in its onboarding.');
    return 0;
  }
  if (report.mode === 'headless') {
    if (report.desktop.running !== false) throw Error('A desktop collector is running or its state is unknown. Close the desktop app and verify local process access before installing headless.');
    if (report.headless.installed && report.headless.error) throw Error('Cannot verify the existing headless collector. Resolve native status before reconnecting.');
    if (report.headless.status?.running === true && !options.sharing) {
      printReport(host, report);
      host.print('Existing collector reused; sharing choice and signing identity preserved.');
      return 0;
    }
    if (!options.sharing && !host.interactive) throw Error('Interactive setup needs a terminal. For unattended headless setup choose --local-only or --share explicitly.');
    const args = [fileURLToPath(new URL('../../linux/headless/bootstrap.sh', import.meta.url))];
    if (options.user) args.push('--user', options.user);
    if (options.sharing) args.push(options.sharing);
    host.print('Using the native Debian installer. Its sharing notice, saved OFF preference, encrypted credentials and release checksum checks apply.');
    const code = await host.install('bash', args);
    if (code !== 0) return code;
    const after = await inspect(host, options);
    printReport(host, { cliVersion: version, ...after });
    if (after.headless.status?.running !== true || after.errors.length) {
      host.print('Installation returned, but a running collector could not be verified. Inspect the systemd service before collecting.');
      return 1;
    }
    if (options.sharing && after.headless.status.sharing_consent !== (options.sharing === '--share')) {
      host.print('The native installer did not apply the requested sharing choice. Review its output and rerun a current native installer.');
      return 1;
    }
    return 0;
  }
  if (report.headless.status?.running === true || (report.headless.installed && !report.headless.status)) {
    throw Error('An existing headless collector is running or could not be inspected. Use tokrate status --headless and its native controls before starting desktop.');
  }
  if (report.desktop.running === true) {
    host.print('Tokrate desktop is already running. Use its Sharing settings to review consent.');
    return 0;
  }
  if (report.desktop.running === null && report.desktop.installed) throw Error('Cannot determine whether the desktop app is running. Open it using your desktop controls.');
  host.print(`Desktop setup: ${DOWNLOAD}`);
  host.print('Install the native package for your platform, then open Tokrate and choose community sharing or local-only use in its existing onboarding.');
  if (host.platform === 'win32') host.print('Windows alpha is not Authenticode-signed; manual desktop acceptance is pending.');
  if (host.platform === 'linux') host.print('Linux desktop is alpha and needs a graphical session and an unlocked Secret Service keyring for sharing.');
  if (report.desktop.path) {
    if (host.platform === 'darwin') await host.launch('open', ['-a', report.desktop.path]);
    else await host.launch(report.desktop.path, []);
    host.print('Opened the existing app; its saved sharing choice is preserved.');
  } else {
    if (host.platform === 'darwin') await host.launch('open', [DOWNLOAD]);
    else if (host.platform === 'win32') await host.launch('rundll32.exe', ['url.dll,FileProtocolHandler', DOWNLOAD]);
    else await host.launch('xdg-open', [DOWNLOAD]);
    host.print('Opened the official download page. Finish installation there, then run tokrate doctor.');
  }
  return 0;
}
