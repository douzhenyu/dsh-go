// Public synthetic Noise IK golden material only; never use these keys in a connection.
// Tests the unchanged ETS state machine against Node/OpenSSL primitives and the Dart/upstream fixture.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { createLoader } = require('./ets-loader.cjs');
const fixture = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../../packages/dsh_remote/test/fixtures/noise-ik.json'), 'utf8'));
const vector = fixture.vectors[0];
const from64 = text => new Uint8Array(Buffer.from(text, 'base64url'));
const to64 = value => Buffer.from(value).toString('base64url');
const concat = (...values) => new Uint8Array(Buffer.concat(values.map(value => Buffer.from(value))));
const hash = value => new Uint8Array(crypto.createHash('sha256').update(value).digest());
const hmac = (key, data) => new Uint8Array(crypto.createHmac('sha256', key).update(data).digest());
const pkcs8 = Buffer.from('302e020100300506032b656e04220420', 'hex');
const spki = Buffer.from('302a300506032b656e032100', 'hex');
const priv = raw => crypto.createPrivateKey({key:Buffer.concat([pkcs8,Buffer.from(raw)]),format:'der',type:'pkcs8'});
const pub = raw => crypto.createPublicKey({key:Buffer.concat([spki,Buffer.from(raw)]),format:'der',type:'spki'});
const derive = raw => new Uint8Array(crypto.createPublicKey(priv(raw)).export({format:'der',type:'spki'}).subarray(-32));
function agreement(pair, publicKey) {
  try {
    const shared = new Uint8Array(crypto.diffieHellman({privateKey:priv(pair.privateKey),publicKey:pub(publicKey)}));
    if (shared.length !== 32 || shared.every(byte=>byte===0)) throw new Error('INVALID_KEY');
    return shared;
  } catch (_) { throw new Error('INVALID_KEY'); }
}
function hkdf(chain, input) {
  const temp = hmac(chain,input);
  try { const first=hmac(temp,new Uint8Array([1])); return [first,hmac(temp,concat(first,new Uint8Array([2])))]; }
  finally { temp.fill(0); }
}
function nonce(counter) {
  if (!Number.isSafeInteger(counter) || counter < 0) throw new Error('NOISE_NONCE_EXHAUSTED');
  const value=Buffer.alloc(12); value.writeBigUInt64LE(BigInt(counter),4); return value;
}
function seal(key, counter, aad, plain) {
  if (plain.length+16>65535) throw new Error('NOISE_MESSAGE_INVALID');
  const cipher=crypto.createCipheriv('chacha20-poly1305',key,nonce(counter),{authTagLength:16});
  cipher.setAAD(aad,{plaintextLength:plain.length});
  return concat(cipher.update(plain),cipher.final(),cipher.getAuthTag());
}
function open(key, counter, aad, encrypted) {
  if (encrypted.length<16 || encrypted.length>65535) throw new Error('NOISE_MESSAGE_INVALID');
  try {
    const cipher=crypto.createDecipheriv('chacha20-poly1305',key,nonce(counter),{authTagLength:16});
    cipher.setAAD(aad,{plaintextLength:encrypted.length-16}); cipher.setAuthTag(encrypted.slice(-16));
    return concat(cipher.update(encrypted.slice(0,-16)),cipher.final());
  } catch (_) { throw new Error('NOISE_DECRYPT_FAILED'); }
}
class Pair {
  constructor(raw, publicKey=derive(raw)) { this.privateKey=new Uint8Array(raw); this.publicKey=new Uint8Array(publicKey); this.destroyed=false; }
  destroy() { this.privateKey.fill(0); this.publicKey.fill(0); this.destroyed=true; }
}
function setup({prologue=from64(vector.prologue.bytes), remote=from64(vector.staticKeys.responder.publicKey), ephemeral=from64(vector.ephemeralPrivateKeys.initiator), localPublic}={}) {
  const identity=new Pair(from64(vector.staticKeys.initiator.privateKey),localPublic);
  const generated=[]; const derivedKeys=[];
  class MockPair extends Pair {
    static generate() { const pair=new Pair(ephemeral); generated.push(pair); return pair; }
  }
  const exports={RemoteKeyPair:MockPair,dh:agreement,sha256:hash,hmac,
    hkdf2:(chain,input)=>{const keys=hkdf(chain,input);derivedKeys.push(...keys);return keys;},seal,open};
  const load=createLoader({'./RemoteCrypto':exports,'./RemoteBytes':{bytes:concat,utf8:text=>new Uint8Array(Buffer.from(text)),equalBytes:(a,b)=>a.length===b.length&&crypto.timingSafeEqual(a,b)}});
  const {NoiseInitiator}=load('remote/RemoteNoise');
  const session=new NoiseInitiator(identity,remote,prologue);
  return {session,identity,generated,derivedKeys,NoiseInitiator};
}
// Independent responder used only in this test, on Node/OpenSSL, with exact IK token order.
function responder(message1, {prologue=from64(vector.prologue.bytes), pinned=from64(vector.staticKeys.initiator.publicKey), payload=from64(vector.handshake.message2.payload)}={}) {
  const identity=new Pair(from64(vector.staticKeys.responder.privateKey));
  const ephemeral=new Pair(from64(vector.ephemeralPrivateKeys.responder));
  const name=Buffer.from(fixture.suite); let h=name.length<=32?concat(name,Buffer.alloc(32-name.length)):hash(name);
  let chain=new Uint8Array(h), key, counter=0;
  const mixHash=value=>{h=hash(concat(h,value));};
  const mixKey=value=>{[chain,key]=hkdf(chain,value);counter=0;};
  const decrypt=value=>{const result=open(key,counter++,h,value);mixHash(value);return result;};
  mixHash(prologue);mixHash(identity.publicKey);
  const remoteE=message1.slice(0,32);mixHash(remoteE);mixKey(agreement(identity,remoteE));
  const remoteS=decrypt(message1.slice(32,80));assert.equal(to64(remoteS),to64(pinned));
  mixKey(agreement(identity,remoteS));const firstPayload=decrypt(message1.slice(80));
  mixHash(ephemeral.publicKey);mixKey(agreement(ephemeral,remoteE));mixKey(agreement(ephemeral,remoteS));
  const encrypted=seal(key,counter++,h,payload);mixHash(encrypted);
  const keys=hkdf(chain,new Uint8Array(0));let sendCounter=0,receiveCounter=0;
  return {message:concat(ephemeral.publicKey,encrypted),payload:firstPayload,
    encrypt:plain=>seal(keys[1],sendCounter++,new Uint8Array(0),plain),
    decrypt:frame=>open(keys[0],receiveCounter++,new Uint8Array(0),frame)};
}
function handshake(options={}) {
  const context=setup(options); const first=context.session.writeMessage(from64(vector.handshake.message1.payload));
  const host=responder(first,options);context.session.readMessage(host.message);return {...context,host};
}
function allZero(value) { return value.every(byte=>byte===0); }

test('exact upstream/Dart IK handshake, bidirectional transport and counters',()=>{
  const {session,identity,generated,derivedKeys}=setup();
  assert.equal(session.ready,false);
  const first=session.writeMessage(from64(vector.handshake.message1.payload));
  assert.equal(to64(first),vector.handshake.message1.message);
  const host=responder(first);assert.equal(to64(host.message),vector.handshake.message2.message);
  assert.equal(to64(session.readMessage(host.message)),vector.handshake.message2.payload);
  assert.equal(session.ready,true);assert.equal(session.sendingCounter,0);assert.equal(session.receivingCounter,0);
  for (const step of vector.transport) {
    const plain=from64(step.plaintext);
    if (step.sender==='initiator') {
      const encrypted=session.encrypt(plain);assert.equal(to64(encrypted),step.ciphertext);assert.equal(to64(host.decrypt(encrypted)),step.plaintext);
    } else {
      const encrypted=host.encrypt(plain);assert.equal(to64(encrypted),step.ciphertext);assert.equal(to64(session.decrypt(encrypted)),step.plaintext);
    }
    assert.equal(String(session.sendingCounter),step.countersAfter.initiatorSending);
    assert.equal(String(session.receivingCounter),step.countersAfter.initiatorReceiving);
  }
  assert(generated[0].destroyed,'ephemeral destroyed immediately after Split');
  session.destroy();session.destroy();assert(!session.ready);assert(session.isDestroyed);
  assert(derivedKeys.every(allZero),'all owned HKDF outputs cleared');
  assert(!identity.destroyed);assert.equal(to64(identity.privateKey),vector.staticKeys.initiator.privateKey);
});
test('handshake order and not-ready checks do not advance valid state',()=>{
  const {session}=setup();
  assert.throws(()=>session.readMessage(new Uint8Array(48)),/NOISE_HANDSHAKE_ORDER/);
  assert.throws(()=>session.encrypt(new Uint8Array(0)),/NOISE_NOT_READY/);
  assert.throws(()=>session.decrypt(new Uint8Array(16)),/NOISE_NOT_READY/);
  session.writeMessage();assert.throws(()=>session.writeMessage(),/NOISE_HANDSHAKE_ORDER/);session.destroy();
  assert.throws(()=>session.writeMessage(),/NOISE_DESTROYED/);
});
test('wrong prologue, responder identity, truncation and tampered handshake fail closed',()=>{
  for (const mode of ['prologue','identity','short','long','tamper']) {
    const options=mode==='prologue'?{prologue:new Uint8Array(Buffer.from('different binding'))}:mode==='identity'?{remote:derive(new Uint8Array(32).fill(7))}:{};
    const {session,identity,generated}=setup(options);session.writeMessage();
    let response=from64(vector.handshake.message2.message);
    if(mode==='short')response=response.slice(0,47);
    if(mode==='long')response=new Uint8Array(65536);
    if(mode==='tamper')response[response.length-1]^=1;
    assert.throws(()=>session.readMessage(response),/NOISE_(DECRYPT_FAILED|MESSAGE_INVALID)/,mode);
    assert(session.isDestroyed);assert(generated[0].destroyed);assert(!identity.destroyed);
    assert.throws(()=>session.readMessage(response),/NOISE_DESTROYED/);
  }
});
test('low-order peer points are rejected in both handshake DH positions',()=>{
  for(const first of [true,false]) {
    const {session,identity}=setup(first?{remote:new Uint8Array(32)}:{});
    if(first)assert.throws(()=>session.writeMessage(),/INVALID_KEY/);
    else { session.writeMessage();const response=new Uint8Array(48);assert.throws(()=>session.readMessage(response),/INVALID_KEY/); }
    assert(session.isDestroyed);assert(!identity.destroyed);
  }
});
test('transport replay, reordering, forged tags and malformed sizes destroy state',()=>{
  for(const mode of ['replay','reorder','tamper','short','long']) {
    const {session,host,identity,derivedKeys}=handshake();
    const first=host.encrypt(new Uint8Array([1])),second=host.encrypt(new Uint8Array([2]));
    let frame=first;
    if(mode==='replay')session.decrypt(first);
    if(mode==='reorder')frame=second;
    if(mode==='tamper'){frame=new Uint8Array(first);frame[0]^=1;}
    if(mode==='short')frame=new Uint8Array(15);
    if(mode==='long')frame=new Uint8Array(65536);
    assert.throws(()=>session.decrypt(frame),/NOISE_(DECRYPT_FAILED|MESSAGE_INVALID)/,mode);
    assert(session.isDestroyed);assert(derivedKeys.every(allZero));assert(!identity.destroyed);
  }
});
test('empty/max messages and handshake size limits',()=>{
  const {session,host}=handshake();
  const max=new Uint8Array(65519);for(let i=0;i<max.length;i++)max[i]=i&255;
  assert.equal(to64(host.decrypt(session.encrypt(max))),to64(max));
  assert.equal(to64(session.decrypt(host.encrypt(max))),to64(max));
  assert.equal(session.encrypt(new Uint8Array(0)).length,16);
  assert.throws(()=>session.encrypt(new Uint8Array(65520)),/NOISE_MESSAGE_INVALID/);assert(session.ready);
  session.destroy();
  const exact=setup();assert.equal(exact.session.writeMessage(new Uint8Array(65439)).length,65535);exact.session.destroy();
  const tooBig=setup();assert.throws(()=>tooBig.session.writeMessage(new Uint8Array(65440)),/NOISE_MESSAGE_INVALID/);assert(tooBig.session.isDestroyed);
});
test('nonce cap and LE64 carry do not round or reuse counters',()=>{
  const {session,host}=handshake();
  session.sendCipher.counter=0x100000001;
  const key=session.sendCipher.key;const plain=new Uint8Array([3,4]);
  assert.equal(to64(session.encrypt(plain)),to64(seal(key,0x100000001,new Uint8Array(0),plain)));
  session.sendCipher.counter=Number.MAX_SAFE_INTEGER;
  assert.throws(()=>session.encrypt(plain),/NOISE_NONCE_EXHAUSTED/);assert(session.isDestroyed);
});
test('constructor validates key lengths and public/private correspondence without clearing caller keys',()=>{
  const context=setup();context.session.destroy();
  assert.throws(()=>new context.NoiseInitiator(context.identity,new Uint8Array(31)),/INVALID_KEY/);
  assert(!context.identity.destroyed);
  assert.throws(()=>setup({localPublic:new Uint8Array(32)}),/INVALID_KEY/);
});
