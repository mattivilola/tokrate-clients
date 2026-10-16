import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const source = fs.readFileSync(new URL('../linux/headless/bootstrap.sh', import.meta.url), 'utf8');
const pinned = source.match(/readonly TOKRATE_VERSION=(\d+\.\d+\.\d+)/)[1];

function runFixture(installed, args = [], running = true, oldProcess = false) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tokrate-bootstrap-behavior-'));
  try {
    const bin = path.join(root,'bin');fs.mkdirSync(bin);
    const config = path.join(root,'config','agent');fs.mkdirSync(config,{recursive:true});
    fs.writeFileSync(path.join(config,'setup-complete'),'1');fs.writeFileSync(path.join(config,'settings.json'),'{}');
    fs.writeFileSync(path.join(root,'config','update-checks'),'on\n');
    const binary = path.join(root,'installed');fs.writeFileSync(binary,`#!/bin/sh\nprintf 'tokrate-headless ${installed}\\n'\n`,{mode:0o755});
    const proc = path.join(root,'proc','123');fs.mkdirSync(proc,{recursive:true});
    const oldBinary = path.join(root,'old-binary');fs.writeFileSync(oldBinary,'old');
    fs.symlinkSync(oldProcess ? oldBinary : binary, path.join(proc,'exe'));
    const osRelease = path.join(root,'os-release');fs.writeFileSync(osRelease,'ID=debian\nVERSION_ID=12\n');
    const stub = (name,text) => fs.writeFileSync(path.join(bin,name),text,{mode:0o755});
    stub('id','#!/bin/sh\nprintf "agent\\n"\n');
    stub('stat','#!/bin/sh\ncase "$2" in %u) echo 0;; %a) echo 755;; *) exit 99;; esac\n');
    stub('sudo','#!/bin/sh\nexit 99\n');
    stub('sha256sum','#!/bin/sh\nexit 99\n');
    stub('curl',`#!/bin/sh\ntouch '${root}/download-attempted'\nexit 99\n`);
    stub('systemctl',`#!/bin/sh\n${running ? 'case "$*" in "is-active --quiet tokrate-headless-share@agent.service") exit 0;; "show --property=MainPID --value tokrate-headless-share@agent.service") echo 123;exit 0;; *) exit 1;; esac' : 'exit 1'}\n`);
    stub('dpkg',`#!${process.execPath}\nconst a=process.argv.slice(2);if(a[0]==='--print-architecture'){console.log('amd64');process.exit(0)}const x=a[1].split('.').map(Number),y=a[3].split('.').map(Number);let c=0;for(let i=0;i<3;i++){if(x[i]!==y[i]){c=x[i]>y[i]?1:-1;break}}process.exit((a[2]==='gt'&&c>0)||(a[2]==='ge'&&c>=0)?0:1);\n`);
    const script = source.replaceAll('/usr/bin/tokrate-headless',binary)
      .replaceAll('/etc/tokrate-headless',path.join(root,'config')).replaceAll('/etc/os-release',osRelease).replaceAll('/proc/',path.join(root,'proc')+'/');
    const scriptFile=path.join(root,'bootstrap.sh');fs.writeFileSync(scriptFile,script);
    const result=spawnSync('bash',[scriptFile,'--user','agent',...args],{env:{...process.env,PATH:bin+path.delimiter+process.env.PATH},encoding:'utf8',timeout:10000});
    return {...result,downloaded:fs.existsSync(path.join(root,'download-attempted'))};
  } finally {fs.rmSync(root,{recursive:true,force:true});}
}
test('configured current version reports running service without download or restart', () => {
  const result=runFixture(pinned);
  assert.equal(result.status,0,result.stderr);
  assert.match(result.stdout,/Already up to date:/);
  assert.match(result.stdout,/No download or restart needed/);
  assert.match(result.stdout,/Service is running the installed version: tokrate-headless-share@agent.service/);
  assert.equal(result.downloaded,false);
});
test('a stale installer never downgrades a newer installed binary', () => {
  const v=pinned.split('.').map(Number);v[2]++;
  const result=runFixture(v.join('.'));
  assert.equal(result.status,0,result.stderr);assert.match(result.stdout,/newer than this installer/);
  assert.equal(result.downloaded,false);
});
test('older installation announces old and new versions before download and cannot claim restart on download failure', () => {
  const v=pinned.split('.').map(Number);v[2]--;
  const result=runFixture(v.join('.'),['--share']);
  assert.notEqual(result.status,0);assert.ok(result.stdout.includes(`Updating Tokrate Headless ${v.join('.')} → ${pinned}`));
  assert.equal(result.downloaded,true);assert.doesNotMatch(result.stdout,/Service is running|service restarted/i);
});

test('an intentionally stopped service is reported without claiming it is running or starting it', () => {
  const result=runFixture(pinned,[],false);
  assert.equal(result.status,0,result.stderr);assert.match(result.stdout,/No collector service is running/);
  assert.equal(result.downloaded,false);assert.doesNotMatch(result.stdout,/Service is running/);
});
test('an old running process is not mistaken for the current installed binary', () => {
  const result=runFixture(pinned,[],true,true);
  assert.notEqual(result.status,0);assert.match(result.stdout,/service is using an older binary/);
  assert.doesNotMatch(result.stdout,/No download or restart needed|Service is running/);
});
