import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { createManifest, verifyMinisign, wrapManifest } from './headless-manifest.mjs';

const artifacts = new Map([
  ['tokrate-headless_0.1.28_amd64.deb', Buffer.from('native amd64 fixture')],
  ['tokrate-headless_0.1.28_arm64.deb', Buffer.from('native arm64 fixture')],
]);
const manifest = () => createManifest('0.1.28', artifacts, 1792152000);
function signedFixture(payload) {
  const {privateKey, publicKey} = generateKeyPairSync('ed25519');
  const id = Buffer.from('test-key');
  const key = Buffer.concat([Buffer.from('Ed'), id, publicKey.export({format:'der',type:'spki'}).subarray(-32)]);
  const raw = sign(null, createHash('blake2b512').update(payload).digest(), privateKey);
  const comment = 'timestamp:1792152000\tfile:headless-alpha.payload.json\tversion:0.1.28';
  const signature = Buffer.concat([Buffer.from('ED'), id, raw]);
  const global = sign(null, Buffer.concat([raw, Buffer.from(comment)]), privateKey);
  return {
    publicKey:Buffer.from('untrusted comment: test key\n'+key.toString('base64')+'\n').toString('base64'),
    signature:Buffer.from('untrusted comment: test signature\n'+signature.toString('base64')+'\ntrusted comment: '+comment+'\n'+global.toString('base64')+'\n').toString('base64'),
  };
}

test('native manifest binds both architecture packages to exact release names, sizes and hashes', () => {
  const value = manifest();
  assert.equal(value.product, 'tokrate-headless');
  assert.equal(value.channel, 'alpha');
  assert.equal(value.releaseSequence, 1792152000);
  assert.equal(Date.parse(value.expiresAt)-Date.parse(value.releasedAt), 90*86400*1000);
  assert.equal(Object.keys(value.platforms).length, 2);
  const artifact = artifacts.get('tokrate-headless_0.1.28_amd64.deb');
  assert.deepEqual(value.platforms['linux-x86_64-deb'], {
    url:'https://github.com/mattivilola/tokrate-clients/releases/download/v0.1.28-headless-alpha.1/tokrate-headless_0.1.28_amd64.deb',
    size:artifact.length, sha256:createHash('sha256').update(artifact).digest('hex'),
  });
});
test('missing native package or malformed version/sequence fails closed', () => {
  assert.throws(() => createManifest('0.1.28', new Map(), 1792152000));
  for (const version of ['01.1.28','0.1.28-alpha.1','../0.1.28','0.1.28+other'])
    assert.throws(() => createManifest(version, artifacts, 1792152000));
  for (const epoch of [0,NaN,1.5,-1]) assert.throws(() => createManifest('0.1.28', artifacts, epoch));
});
test('envelope preserves exact signed bytes; tampering, wrong key and changed trusted comment fail', () => {
  const payload = Buffer.from(JSON.stringify(manifest())+'\n');
  const {signature,publicKey} = signedFixture(payload);
  assert.equal(verifyMinisign(payload,signature,publicKey), true);
  assert.deepEqual(wrapManifest(payload,signature,publicKey), {signedPayload:payload.toString('base64'),signature});
  const bad = Buffer.from(payload);bad[0]^=1;
  assert.throws(() => wrapManifest(bad,signature,publicKey));
  assert.equal(verifyMinisign(payload,signature,signedFixture(payload).publicKey),false);
  const changed = Buffer.from(Buffer.from(signature,'base64').toString().replace('timestamp:1792152000','timestamp:1792152001')).toString('base64');
  assert.equal(verifyMinisign(payload,changed,publicKey),false);
});
