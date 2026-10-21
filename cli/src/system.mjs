import { spawn } from 'node:child_process';
import { access, readFile, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export function system() {
  const user = os.userInfo();
  return {
    platform: process.platform, arch: process.arch, release: os.release(),
    env: process.env, home: os.homedir(), user: user.username, uid: user.uid,
    interactive: Boolean(process.stdin.isTTY && process.stdout.isTTY),
    print: (text) => console.log(text),
    async exists(file) {
      try { await access(file); return true; } catch { return false; }
    },
    async read(file) {
      try {
        const info = await stat(file);
        if (!info.isFile() || info.size > 65_536) return null;
        return await readFile(file, 'utf8');
      } catch { return null; }
    },
    async which(command) {
      for (const dir of (process.env.PATH ?? '').split(path.delimiter).filter(Boolean)) {
        for (const suffix of process.platform === 'win32' ? ['', '.exe', '.cmd'] : ['']) {
          const file = path.resolve(dir, command + suffix);
          try {
            if (!(await stat(file)).isFile()) continue;
            await access(file, process.platform === 'win32' ? constants.F_OK : constants.X_OK);
            return file;
          } catch { /* Continue searching PATH. */ }
        }
      }
      return null;
    },
    exec: capture,
    async install(command, args) {
      return await new Promise((resolve, reject) => {
        const child = spawn(command, args, { stdio: 'inherit', shell: false });
        child.once('error', reject);
        child.once('exit', (code) => resolve(code ?? 1));
      });
    },
    async launch(command, args) {
      await new Promise((resolve, reject) => {
        const child = spawn(command, args, { detached: true, stdio: 'ignore', shell: false });
        child.once('error', reject);
        child.once('spawn', () => { child.unref(); resolve(); });
      });
    }
  };
}

// Local diagnostics are bounded; never run a shell or inherit a child's stdin.
export async function capture(command, args, spawnCommand = spawn) {
  return await new Promise((resolve) => {
    let stdout = '', stderr = '', size = 0, error = null;
    let child;
    try {
      child = spawnCommand(command, args, { stdio: ['ignore', 'pipe', 'pipe'], shell: false, windowsHide: true });
    } catch {
      resolve({ code: 1, stdout, stderr, error: 'Command could not be started' });
      return;
    }
    const timer = setTimeout(() => { error = 'Command timed out'; child.kill('SIGKILL'); }, 5000);
    const append = (kind, bytes) => {
      size += Buffer.byteLength(bytes);
      if (size > 1_048_576) { error = 'Command output exceeded limit'; child.kill('SIGKILL'); return; }
      if (kind === 'stdout') stdout += bytes.toString(); else stderr += bytes.toString();
    };
    child.stdout.setEncoding('utf8').on('data', (bytes) => append('stdout', bytes));
    child.stderr.setEncoding('utf8').on('data', (bytes) => append('stderr', bytes));
    child.once('error', () => { clearTimeout(timer); resolve({ code: 1, stdout, stderr, error: 'Command could not be started' }); });
    child.once('close', (code) => { clearTimeout(timer); resolve({ code: code ?? 1, stdout, stderr, error }); });
  });
}
