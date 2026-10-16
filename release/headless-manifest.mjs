import fs from 'node:fs';
import path from 'node:path';
import { createHash, createPublicKey, verify } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const releaseRoot = 'https://github.com/mattivilola/tokrate-clients/releases/download/';
const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

export function verifyMinisign(bytes, encodedSignature, encodedKey) {
  try {
    const keyLines = Buffer.from(encodedKey.trim(), 'base64').toString('utf8').trim().split(/\r?\n/);
    const publicBytes = Buffer.from(keyLines[1] ?? '', 'base64');
    const lines = Buffer.from(encodedSignature.trim(), 'base64').toString('utf8').trim().split(/\r?\n/);
    const signature = Buffer.from(lines[1] ?? '', 'base64');
    const globalSignature = Buffer.from(lines[3] ?? '', 'base64');
    if (publicBytes.length !== 42 || publicBytes.subarray(0, 2).toString() !== 'Ed'
      || signature.length !== 74 || globalSignature.length !== 64
      || !lines[2]?.startsWith('trusted comment: ')
      || !signature.subarray(2, 10).equals(publicBytes.subarray(2, 10))) return false;
    const algorithm = signature.subarray(0, 2).toString();
    if (!['Ed', 'ED'].includes(algorithm)) return false;
    const key = createPublicKey({key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), publicBytes.subarray(10)]), format:'der', type:'spki'});
    const payload = algorithm === 'ED' ? createHash('blake2b512').update(bytes).digest() : bytes;
    return verify(null, payload, key, signature.subarray(10))
      && verify(null, Buffer.concat([signature.subarray(10), Buffer.from(lines[2].slice(17))]), key, globalSignature);
  } catch { return false; }
}

export function createManifest(version, artifacts, epochSeconds) {
  if (!versionPattern.test(version) || !Number.isSafeInteger(epochSeconds) || epochSeconds <= 0)
    throw Error('Canonical release version and source epoch required');
  const releasedAt = new Date(epochSeconds * 1000).toISOString();
  const expiresAt = new Date((epochSeconds + 90 * 24 * 60 * 60) * 1000).toISOString();
  const platforms = {};
  for (const [target, arch] of [['linux-x86_64-deb', 'amd64'], ['linux-aarch64-deb', 'arm64']]) {
    const name = `tokrate-headless_${version}_${arch}.deb`;
    const bytes = artifacts.get(name);
    if (!bytes?.length || bytes.length > 100 * 1024 * 1024) throw Error(`Missing or oversized native artifact: ${name}`);
    platforms[target] = {
      url: `${releaseRoot}v${version}-headless-alpha.1/${name}`,
      size: bytes.length,
      sha256: createHash('sha256').update(bytes).digest('hex'),
    };
  }
  return {schemaVersion:1, product:'tokrate-headless', channel:'alpha', version,
    releaseSequence:epochSeconds, releasedAt, expiresAt, minimumDebian:12, platforms};
}

export function wrapManifest(payload, signature, publicKey) {
  if (payload.length > 32 * 1024 || !verifyMinisign(payload, signature, publicKey))
    throw Error('Headless manifest signature verification failed');
  const manifest = JSON.parse(payload.toString('utf8'));
  if (manifest.schemaVersion !== 1 || manifest.product !== 'tokrate-headless' || manifest.channel !== 'alpha'
    || !versionPattern.test(manifest.version) || !Number.isSafeInteger(manifest.releaseSequence)
    || manifest.releaseSequence <= 0) throw Error('Unexpected signed headless release');
  return {signedPayload:payload.toString('base64'), signature:signature.trim()};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, first, second, third] = process.argv.slice(2);
  if (mode === 'create' && first && second && third) {
    const artifacts = new Map();
    for (const arch of ['amd64', 'arm64']) {
      const name = `tokrate-headless_${first}_${arch}.deb`;
      artifacts.set(name, fs.readFileSync(path.join(second, name)));
    }
    const manifest = createManifest(first, artifacts, Number(process.env.SOURCE_DATE_EPOCH));
    fs.writeFileSync(third, JSON.stringify(manifest, null, 2)+'\n');
  } else if (mode === 'wrap' && first && second && third) {
    const keyFile = fileURLToPath(new URL('../desktop/updater-public-key.txt', import.meta.url));
    const envelope = wrapManifest(fs.readFileSync(first), fs.readFileSync(second, 'utf8'), fs.readFileSync(keyFile, 'utf8'));
    fs.writeFileSync(third, JSON.stringify(envelope, null, 2)+'\n');
    console.log('Verified exact manifest bytes and the embedded updater key before creating the public envelope.');
  } else throw Error('Usage: headless-manifest.mjs create VERSION ARTIFACT_DIRECTORY PAYLOAD | wrap PAYLOAD SIGNATURE ENVELOPE');
}
