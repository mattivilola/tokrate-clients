import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { parse, run } from '../src/cli.mjs';
import { inspect, osRelease, DOWNLOAD } from '../src/inspect.mjs';
import { capture } from '../src/system.mjs';

const native = (extra = {}) => ({ version: '0.1.30', running: true, monitoring: true,
  sharing_consent: false, sharing_active: false, updated_at: '2026-10-21T10:00:00Z', ...extra });

function fixture(overrides = {}) {
  const files = new Set(['/run/systemd/system']);
  const calls = [], output = [];
  let status = native();
  const host = {
    platform: 'linux', arch: 'x64', release: '6.1.0', home: '/home/alice',
    user: 'alice', uid: 1000, env: {}, interactive: true,
    now: () => Date.parse('2026-10-21T10:00:30Z'),
    print: (line) => output.push(line),
    exists: async (file) => files.has(file),
    read: async () => 'ID=debian\nVERSION_ID="12"\n',
    which: async (command) => `/usr/bin/${command}`,
    exec: async (command, args) => {
      calls.push({ command, args });
      if (command === 'id') return { code: 0, stdout: '1000\n' };
      return { code: 0, stdout: command === 'ps' || command === 'tasklist.exe' ? '' : JSON.stringify(status) };
    },
    install: async (command, args) => {
      calls.push({ install: command, args }); files.add('/usr/bin/tokrate-headless');
      if (args.includes('--share')) status = { ...status, sharing_consent: true };
      if (args.includes('--local-only')) status = { ...status, sharing_consent: false };
      return 0;
    },
    launch: async (command, args) => calls.push({ launch: command, args }),
    ...overrides
  };
  return { host, files, calls, output, setStatus: (value) => { status = value; } };
}

test('help and version have no side effects', async () => {
  const f = fixture({ exists: () => { throw Error('unexpected inspection'); } });
  for (const args of [[], ['--help'], ['connect', '--help'], ['--version']]) assert.equal(await run(args, f.host), 0);
  assert.equal(f.calls.length, 0);
});

test('rejects invalid flags before inspecting or installing', () => {
  for (const args of [ ['login'], ['connect', '--headless', '--desktop'], ['connect', '--share', '--local-only'],
    ['connect', '--user'], ['connect', '--user', '--share'], ['connect', '--json'], ['status', '--share'],
    ['doctor', '--no-open'], ['connect', '--bad'], ['status', '--json', '--json'], ['connect', 'alice'] ]) {
    assert.throws(() => parse(args), undefined, args.join(' '));
  }
});

test('reads os-release as data and never evaluates shell expressions', () => {
  assert.deepEqual(osRelease('ID=debian\nVERSION_ID="12.7"\nOTHER=$(touch /tmp/unsafe)\n'), { ID: 'debian', VERSION_ID: '12.7' });
  assert.equal(osRelease('VERSION_ID=$(x)').VERSION_ID, '$(x)');
});

test('headless connect forwards consent to the exact bundled installer with inherited setup', async () => {
  for (const flag of [undefined, '--local-only', '--share']) {
    const f = fixture();
    assert.equal(await run(['connect', ...(flag ? [flag] : [])], f.host), 0);
    const invocation = f.calls.find((call) => call.install);
    assert.equal(invocation.install, 'bash');
    assert.equal(invocation.args[0], fileURLToPath(new URL('../../linux/headless/bootstrap.sh', import.meta.url)));
    assert.deepEqual(invocation.args.slice(1), flag ? [flag] : []);
    assert.equal(f.calls.filter((call) => call.install).length, 1);
    assert.equal(f.calls.filter((call) => call.launch).length, 0);
  }
});

test('unattended setup needs an explicit sharing decision', async () => {
  const f = fixture({ interactive: false });
  await assert.rejects(run(['connect'], f.host), /--local-only or --share/);
  assert.equal(f.calls.some((call) => call.install), false);
  assert.equal(await run(['connect', '--local-only'], f.host), 0);
});

test('reuses a running headless installation without changing saved OFF or identity', async () => {
  const f = fixture({ interactive: false }); f.files.add('/usr/bin/tokrate-headless');
  assert.equal(await run(['connect'], f.host), 0);
  assert.equal(f.calls.some((call) => call.install || call.launch), false);
  assert.match(f.output.join('\n'), /sharing choice and signing identity preserved/);
});

test('explicit consent changes still invoke the existing installer', async () => {
  const f = fixture(); f.files.add('/usr/bin/tokrate-headless');
  assert.equal(await run(['connect', '--local-only'], f.host), 0);
  assert.equal(f.calls.filter((call) => call.install).length, 1);
});

test('installer exit codes and unverified service starts are not reported as success', async () => {
  const failed = fixture({ install: async () => 23 });
  assert.equal(await run(['connect', '--share'], failed.host), 23);
  const stopped = fixture(); stopped.setStatus(native({ running: false }));
  assert.equal(await run(['connect', '--local-only'], stopped.host), 1);
  assert.match(stopped.output.join('\n'), /running collector could not be verified/);
  const unchanged = fixture({ install: async () => 0 }); unchanged.files.add('/usr/bin/tokrate-headless');
  assert.equal(await run(['connect', '--share'], unchanged.host), 1);
  assert.match(unchanged.output.join('\n'), /did not apply the requested sharing choice/);
});

test('root must name a real non-root account, and native status runs as that account', async () => {
  const f = fixture({ uid: 0, user: 'root', home: '/root' });
  assert.equal(await run(['connect', '--local-only'], f.host), 1);
  assert.equal(f.calls.some((call) => call.install), false);
  assert.equal(await run(['connect', '--user', 'alice', '--share'], f.host), 0);
  assert.deepEqual(f.calls.find((call) => call.install).args.slice(1), ['--user', 'alice', '--share']);
  assert.ok(f.calls.some((call) => call.command === 'runuser' && call.args.join(' ') === '-u alice -- /usr/bin/tokrate-headless status'));
  for (const uid of ['0\n', '', 'nobody\n']) {
    const invalid = fixture({ uid: 0, exec: async () => ({ code: 0, stdout: uid }) });
    assert.equal(await run(['connect', '--user', 'root', '--share'], invalid.host), 1);
    assert.equal(invalid.calls.some((call) => call.install), false);
  }
});

test('rejects account injection and accessing other users without root', async () => {
  for (const user of ['alice; touch x', '../bob', 'bob']) {
    const f = fixture();
    await assert.rejects(run(['connect', '--user', user], f.host), /unsupported characters|current account/);
    assert.equal(f.calls.some((call) => call.install), false);
  }
});

test('root checks the target user for a desktop collector before installing headless', async () => {
  const f = fixture({ uid: 0, user: 'root', exec: async (command, args) => {
    if (command === 'id') return { code: 0, stdout: '1000\n' };
    assert.equal(command, 'ps');
    assert.deepEqual(args, ['-U', '1000', '-o', 'comm=']);
    return { code: 0, stdout: 'tokrate-desktop\n' };
  } });
  await assert.rejects(run(['connect', '--headless', '--user', 'alice', '--local-only'], f.host), /desktop collector is running/);
  assert.equal(f.calls.some((call) => call.install), false);
});

test('fails closed on unsupported headless systems and missing prerequisites', async () => {
  const cases = [ { platform: 'darwin', arch: 'arm64', release: '25.0.0' }, { arch: 'ia32' },
    { read: async () => 'ID=ubuntu\nVERSION_ID="24.04"\n' }, { read: async () => 'ID=debian\nVERSION_ID=11\n' },
    { read: async () => null }, { which: async (command) => command === 'sudo' ? null : command },
    { exists: async () => false } ];
  for (const overrides of cases) {
    const f = fixture(overrides);
    assert.equal(await run(['connect', '--headless', '--local-only'], f.host), 1);
    assert.equal(f.calls.some((call) => call.install || call.launch), false);
  }
  assert.equal((await inspect(fixture({ arch: 'arm64' }).host, { mode: 'headless' })).supported, true);
});

test('native status is local-only, preserves details and does not invoke installers', async () => {
  const f = fixture(); f.files.add('/usr/bin/tokrate-headless');
  f.setStatus(native({ pending_samples: 3, last_upload_result: 'never-uploaded' }));
  assert.equal(await run(['status', '--json'], f.host), 0);
  const report = JSON.parse(f.output[0]);
  assert.equal(report.headless.status.pending_samples, 3);
  assert.equal(report.headless.status.sharing_active, false);
  assert.equal(report.desktop.sharing, 'unknown');
  assert.equal(f.calls.some((call) => call.install || call.launch), false);
  assert.ok(f.calls.every((call) => call.command === 'ps' || (call.command === '/usr/bin/tokrate-headless' && call.args[0] === 'status')));
});

test('malformed, failed and incomplete native status remains unknown and blocks reconnect', async () => {
  for (const stdout of ['not json', '[]', '{}', 'null']) {
    const f = fixture({ exec: async (command) => ({ code: 0, stdout: command === 'ps' ? '' : stdout }) });
    f.files.add('/usr/bin/tokrate-headless');
    assert.equal(await run(['status', '--json'], f.host), 1);
    assert.equal(JSON.parse(f.output[0]).headless.status, null);
    await assert.rejects(run(['connect', '--share'], f.host), /Resolve native status/);
  }
  const f = fixture({ exec: async () => ({ code: 1, stdout: '', error: 'Command timed out' }) });
  f.files.add('/usr/bin/tokrate-headless');
  assert.equal(await run(['doctor', '--json'], f.host), 1);
});

test('doctor checks stopped collectors, source/history errors and stale heartbeat', async () => {
  for (const extra of [{ running: false }, { source_error: true }, { history_error: true }]) {
    const f = fixture(); f.files.add('/usr/bin/tokrate-headless'); f.setStatus(native(extra));
    assert.equal(await run(['doctor', '--json'], f.host), 1);
    assert.ok(JSON.parse(f.output[0]).errors.length);
  }
  const f = fixture(); f.files.add('/usr/bin/tokrate-headless');
  f.setStatus(native({ updated_at: '2026-10-20T10:00:00Z', last_upload_result: 'upload-failed' }));
  assert.equal(await run(['doctor', '--json'], f.host), 0);
  const report = JSON.parse(f.output[0]);
  assert.ok(report.warnings.some((warning) => warning.includes('heartbeat')));
  assert.ok(report.warnings.some((warning) => warning.includes('upload-failed')));
});

test('local-only use passes doctor and no installation needs setup', async () => {
  const f = fixture(); f.files.add('/usr/bin/tokrate-headless');
  assert.equal(await run(['doctor', '--json'], f.host), 0);
  assert.equal(JSON.parse(f.output[0]).errors.length, 0);
  const missing = fixture();
  assert.equal(await run(['doctor'], missing.host), 1);
  assert.match(missing.output.join('\n'), /not installed/);
});

test('desktop connect opens the official download page on supported platforms', async () => {
  const cases = [
    { platform: 'darwin', arch: 'arm64', release: '25.0.0', command: 'open' },
    { platform: 'win32', arch: 'x64', release: '10.0.22631', command: 'rundll32.exe' },
    { platform: 'linux', arch: 'x64', env: { DISPLAY: ':0' }, command: 'xdg-open' }
  ];
  for (const { command, ...overrides } of cases) {
    const f = fixture(overrides);
    assert.equal(await run(['connect'], f.host), 0);
    assert.equal(f.calls.find((call) => call.launch).launch, command);
    assert.ok(f.calls.find((call) => call.launch).args.includes(DOWNLOAD));
    assert.equal(f.calls.some((call) => call.install), false);
  }
});

test('desktop no-open never launches an app or browser and rejects consent flags', async () => {
  const f = fixture({ platform: 'darwin', arch: 'arm64', release: '25.0.0' });
  assert.equal(await run(['connect', '--no-open'], f.host), 0);
  assert.equal(f.calls.some((call) => call.launch || call.install), false);
  const restricted = fixture({ platform: 'darwin', arch: 'arm64', release: '25.0.0',
    exec: async () => ({ code: 1, stdout: '', error: 'Command could not be started' }) });
  restricted.files.add('/Applications/Tokrate.app');
  assert.equal(await run(['connect', '--no-open'], restricted.host), 0);
  assert.equal(restricted.calls.some((call) => call.launch || call.install), false);
  for (const flag of ['--share', '--local-only', '--user']) {
    await assert.rejects(run(['connect', flag, ...(flag === '--user' ? ['alice'] : [])], f.host), /require headless/);
  }
  await assert.rejects(run(['connect', '--headless', '--no-open'], fixture().host), /desktop option/);
});

test('desktop detection reuses an existing app without downloading or changing settings', async () => {
  const cases = [
    { platform: 'darwin', arch: 'arm64', release: '25.0.0', file: '/Applications/Tokrate.app' },
    { platform: 'win32', arch: 'x64', release: '10.0.22631', env: { LOCALAPPDATA: 'C:\\Users\\alice\\AppData\\Local' }, file: 'C:\\Users\\alice\\AppData\\Local\\Tokrate\\tokrate-desktop.exe' },
    { platform: 'linux', env: { DISPLAY: ':0' }, file: '/usr/bin/tokrate-desktop' }
  ];
  for (const { file, ...overrides } of cases) {
    const f = fixture(overrides); f.files.add(file);
    assert.equal(await run(['connect', '--desktop'], f.host), 0);
    const launch = f.calls.find((call) => call.launch);
    assert.ok(launch.launch === file || launch.args.includes(file));
    assert.equal(f.calls.some((call) => call.install), false);
  }
});

test('running desktop detection is exact and scoped to the current account', async () => {
  const f = fixture({ platform: 'darwin', arch: 'arm64', release: '25.0.0',
    exec: async () => ({ code: 0, stdout: '/Applications/Tokrate.app/Contents/MacOS/Tokrate\n' }) });
  assert.equal(await run(['connect'], f.host), 0);
  assert.equal(f.calls.some((call) => call.launch), false);
  const unrelated = fixture({ exec: async () => ({ code: 0, stdout: 'tokrate-desktop-other\n' }) });
  assert.equal((await inspect(unrelated.host, {})).desktop.running, false);
});

test('blocks duplicate collectors and unknown process state without changing services', async () => {
  const f = fixture({ exec: async (command) => ({ code: 0, stdout: command === 'ps' ? 'tokrate-desktop\n' : JSON.stringify(native()) }) });
  f.files.add('/usr/bin/tokrate-headless');
  assert.equal(await run(['connect', '--headless'], f.host), 1);
  assert.equal(await run(['doctor', '--headless'], f.host), 1);
  assert.equal(f.calls.some((call) => call.install || call.launch), false);
  const existing = fixture(); existing.files.add('/usr/bin/tokrate-headless');
  await assert.rejects(run(['connect', '--desktop'], existing.host), /headless collector is running/);
  const unknown = fixture({ exec: async () => ({ code: 1, stdout: '' }) });
  await assert.rejects(run(['connect', '--local-only'], unknown.host), /state is unknown/);
});

test('unsupported desktop hardware does not open downloads as if supported', async () => {
  for (const overrides of [{ platform: 'darwin', arch: 'x64', release: '25.0.0' },
    { platform: 'darwin', arch: 'arm64', release: '22.0.0' },
    { platform: 'win32', arch: 'arm64', release: '10.0.22631' },
    { platform: 'win32', arch: 'x64', release: '10.0.19045' }, { platform: 'freebsd' }]) {
    const f = fixture(overrides);
    assert.equal(await run(['connect', '--desktop'], f.host), 1);
    assert.equal(f.calls.some((call) => call.launch || call.install), false);
  }
});

test('native command capture uses argument arrays and reports failures', async () => {
  const ok = await capture(process.execPath, ['-e', 'process.stdout.write(process.argv[1])', 'a; $(echo unsafe)']);
  assert.equal(ok.stdout, 'a; $(echo unsafe)');
  assert.equal(ok.code, 0);
  const missing = await capture('tokrate-nonexistent-command-for-test', []);
  assert.equal(missing.code, 1);
  assert.ok(missing.error);
  const denied = await capture('ps', [], () => { throw Object.assign(new Error('spawn EPERM'), { code: 'EPERM' }); });
  assert.equal(denied.code, 1);
  assert.equal(denied.error, 'Command could not be started');
});

test('published package has a single executable and no automatic installation hooks', async () => {
  const pkg = JSON.parse(await readFile(new URL('../../package.json', import.meta.url), 'utf8'));
  assert.equal(pkg.name, 'tokrate');
  assert.deepEqual(pkg.bin, { tokrate: 'cli/bin/tokrate.mjs' });
  assert.equal(pkg.private, undefined);
  assert.equal(pkg.dependencies, undefined);
  for (const hook of ['preinstall', 'install', 'postinstall', 'prepare']) assert.equal(pkg.scripts[hook], undefined);
  const bootstrap = await readFile(new URL('../../linux/headless/bootstrap.sh', import.meta.url), 'utf8');
  assert.match(bootstrap, /SHA256_AMD64='[a-f0-9]{64}'/);
  assert.match(bootstrap, /SHA256_ARM64='[a-f0-9]{64}'/);
});
