import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const temp = await mkdtemp(path.join(os.tmpdir(), 'tokrate-npm-test-'));
const npmCli = process.env.npm_execpath;
assert.ok(npmCli, 'Run this check using npm run test:package');
const npm = (args) => execFileSync(process.execPath, [npmCli, ...args, '--cache', path.join(temp, 'cache')],
  { cwd: root, encoding: 'utf8', timeout: 60_000, stdio: ['ignore', 'pipe', 'pipe'] });

try {
  const [pack] = JSON.parse(npm(['pack', '--json', '--ignore-scripts', '--pack-destination', temp]));
  assert.deepEqual(pack.files.map((file) => file.path).sort(), [
    'LICENSE', 'README.md', 'cli/README.md', 'cli/bin/tokrate.mjs', 'cli/src/cli.mjs',
    'cli/src/inspect.mjs', 'cli/src/system.mjs', 'linux/headless/bootstrap.sh', 'package.json'
  ].sort(), 'Only the CLI, documented installer and license should be published');
  assert.ok(pack.unpackedSize < 100_000, 'Keep the zero-dependency wrapper small');
  const prefix = path.join(temp, 'installed');
  npm(['install', '--prefix', prefix, '--ignore-scripts', '--no-audit', '--no-fund', '--package-lock=false', path.join(temp, pack.filename)]);
  const installed = path.join(prefix, 'node_modules', 'tokrate');
  const bin = path.join(installed, 'cli', 'bin', 'tokrate.mjs');
  const run = (args) => execFileSync(process.execPath, [bin, ...args], { encoding: 'utf8', timeout: 10_000 });
  assert.match(run(['--help']), /connect\|status\|doctor/);
  assert.match(run(['connect', '--help']), /does not start monitoring/);
  assert.equal(run(['--version']).trim(), pack.version);
  if (process.platform !== 'win32') {
    assert.match(execFileSync(path.join(prefix, 'node_modules', '.bin', 'tokrate'), ['--version'], { encoding: 'utf8' }), new RegExp(pack.version));
  } else {
    assert.ok((await stat(path.join(prefix, 'node_modules', '.bin', 'tokrate.cmd'))).isFile());
  }
  const bootstrap = await readFile(path.join(installed, 'linux', 'headless', 'bootstrap.sh'));
  assert.deepEqual(bootstrap, await readFile(path.join(root, 'linux', 'headless', 'bootstrap.sh')));
  console.log(`Packed and installed ${pack.name}@${pack.version}: ${pack.files.length} files, ${pack.size} bytes compressed; executable and canonical installer verified.`);
} finally {
  // This directory contains only disposable artifacts created by this check.
  await rm(temp, { recursive: true, force: true });
}
