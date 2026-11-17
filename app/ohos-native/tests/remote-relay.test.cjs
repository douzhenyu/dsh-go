// Synthetic upstream protocol-v1 fixtures + Node/OpenSSL responder. No network/device/account access.
// Tests production Relay/Noise/Protocol/Bytes through a fake NetworkKit WebSocket only.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { createLoader, deferred, flush } = require('./ets-loader.cjs');
const fixtureRoot=path.resolve(__dirname,'../../../packages/dsh_remote/test/fixtures');
const fixture=name=>JSON.parse(fs.readFileSync(path.join(fixtureRoot,name),'utf8'));
const golden=fixture('noise-ik.json').vectors[0];
const helloCases=fixture('protocol-v1/control/hello.json').cases;
const connectCases=fixture('protocol-v1/control/connect.json').cases;
const frame=(type,payload)=>({v:1,id:crypto.randomUUID(),timestamp:Date.now(),type,payload});
const encoded=value=>new Uint8Array(Buffer.from(JSON.stringify(value)));
const raw=value=>new Uint8Array(Buffer.from(value,'base64url'));
const b64=value=>Buffer.from(value).toString('base64url');
const join=(...values)=>new Uint8Array(Buffer.concat(values.map(value=>Buffer.from(value))));
const hash=value=>new Uint8Array(crypto.createHash('sha256').update(value).digest());
const hmac=(key,value)=>new Uint8Array(crypto.createHmac('sha256',key).update(value).digest());
const privateKey=value=>crypto.createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b656e04220420','hex'),Buffer.from(value)]),type:'pkcs8',format:'der'});
const publicKey=value=>crypto.createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b656e032100','hex'),Buffer.from(value)]),type:'spki',format:'der'});
const derive=value=>new Uint8Array(crypto.createPublicKey(privateKey(value)).export({type:'spki',format:'der'}).subarray(-32));
class Pair {
  constructor(privateBytes){this.privateKey=new Uint8Array(privateBytes);this.publicKey=derive(privateBytes);this.destroyed=false;}
  static generate(){return new Pair(raw(golden.ephemeralPrivateKeys.initiator));}
  destroy(){this.privateKey.fill(0);this.publicKey.fill(0);this.destroyed=true;}
}
function dh(pair,peer){try{return new Uint8Array(crypto.diffieHellman({privateKey:privateKey(pair.privateKey),publicKey:publicKey(peer)}));}catch(_){throw new Error('INVALID_KEY');}}
function hkdf2(chain,input){const temporary=hmac(chain,input);try{const first=hmac(temporary,new Uint8Array([1]));return[first,hmac(temporary,join(first,new Uint8Array([2])))];}finally{temporary.fill(0);}}
function nonce(counter){const value=Buffer.alloc(12);value.writeBigUInt64LE(BigInt(counter),4);return value;}
function seal(key,counter,aad,plaintext){const cipher=crypto.createCipheriv('chacha20-poly1305',key,nonce(counter),{authTagLength:16});cipher.setAAD(aad,{plaintextLength:plaintext.length});return join(cipher.update(plaintext),cipher.final(),cipher.getAuthTag());}
function open(key,counter,aad,ciphertext){try{const cipher=crypto.createDecipheriv('chacha20-poly1305',key,nonce(counter),{authTagLength:16});cipher.setAAD(aad,{plaintextLength:ciphertext.length-16});cipher.setAuthTag(ciphertext.slice(-16));return join(cipher.update(ciphertext.slice(0,-16)),cipher.final());}catch(_){throw new Error('NOISE_DECRYPT_FAILED');}}
// Independent host, not a second invocation of the production state machine.
function respond(first,prologue,handshakePayload=new Uint8Array(0)){
  const identity=new Pair(raw(golden.staticKeys.responder.privateKey)),ephemeral=new Pair(raw(golden.ephemeralPrivateKeys.responder));
  const name=Buffer.from('Noise_IK_25519_ChaChaPoly_SHA256');let h=join(name,Buffer.alloc(32-name.length)),chain=new Uint8Array(h),key,counter=0;
  const mixHash=value=>{h=hash(join(h,value));};const mixKey=value=>{[chain,key]=hkdf2(chain,value);counter=0;};
  const decrypt=value=>{const result=open(key,counter++,h,value);mixHash(value);return result;};
  mixHash(prologue);mixHash(identity.publicKey);
  const remoteE=first.slice(0,32);mixHash(remoteE);mixKey(dh(identity,remoteE));
  const remoteS=decrypt(first.slice(32,80));assert.equal(b64(remoteS),golden.staticKeys.initiator.publicKey);
  mixKey(dh(identity,remoteS));assert.equal(decrypt(first.slice(80)).length,0);
  mixHash(ephemeral.publicKey);mixKey(dh(ephemeral,remoteE));mixKey(dh(ephemeral,remoteS));
  const payload=seal(key,counter++,h,handshakePayload);mixHash(payload);
  const [receiveKey,sendKey]=hkdf2(chain,new Uint8Array(0));let sending=0,receiving=0;
  return {message:join(ephemeral.publicKey,payload),get sending(){return sending;},
    encrypt:plaintext=>seal(sendKey,sending++,new Uint8Array(0),plaintext),
    decrypt:ciphertext=>open(receiveKey,receiving++,new Uint8Array(0),ciphertext)};
}
class Timers {
  constructor(){this.entries=new Map();this.next=1;}
  timeout=(callback,ms)=>{const id=this.next++;this.entries.set(id,{callback,ms});return id;};
  interval=(callback,ms)=>{const id=this.next++;this.entries.set(id,{callback,ms,interval:true});return id;};
  clear=id=>this.entries.delete(id);
}
function setup(){
  const sockets=[];const timers=new Timers();const sdkConnect={hold:false,gate:deferred()};
  class Socket{
    constructor(){this.handlers={};this.sent=[];this.closed=false;this.blockNext=null;sockets.push(this);}
    on(name,callback){this.handlers[name]=callback;}
    async connect(url,options){this.url=url;this.options=options;if(sdkConnect.hold)await sdkConnect.gate.promise;return true;}
    upgrade(error){this.handlers.open?.(error,{status:101});}
    receive(value){this.handlers.message?.(undefined,typeof value==='string'?value:JSON.stringify(value));}
    fail(code){this.handlers.error?.({code,message:'sensitive-sentinel'});}
    async send(json){this.sent.push(JSON.parse(json));if(this.blockNext){const gate=this.blockNext;this.blockNext=null;await gate.promise;}return true;}
    async close(){this.closed=true;return true;}
  }
  class Base64Helper{encodeToStringSync(value){return Buffer.from(value).toString('base64');}decodeSync(value){return new Uint8Array(Buffer.from(value,'base64'));}}
  class Encoder{encodeInto(value){return new Uint8Array(Buffer.from(value));}}
  const util={generateRandomUUID:()=>crypto.randomUUID(),Base64Helper,TextEncoder:Encoder,TextDecoder:{create:(_encoding,options)=>({decodeWithStream:value=>new TextDecoder('utf-8',options).decode(value)})}};
  const load=createLoader({'@kit.NetworkKit':{webSocket:{createWebSocket:()=>new Socket()}},'@kit.ArkTS':{util},
    '@kit.CryptoArchitectureKit':{cryptoFramework:{createRandom:()=>({generateRandomSync:size=>({data:new Uint8Array(crypto.randomBytes(size))})})}},
    './RemoteCrypto':{RemoteKeyPair:Pair,dh,sha256:hash,hmac,hkdf2,seal,open}},
    {setTimeout:timers.timeout,clearTimeout:timers.clear,setInterval:timers.interval,clearInterval:timers.clear});
  const {RemoteConnectParameters}=load('remote/RemoteDtos');const parameters=new RemoteConnectParameters();
  Object.assign(parameters,{serverUrl:'https://control.invalid',controlUrl:'wss://control.invalid:8443/control',deviceId:'fixture-client-1',hostDeviceId:'fixture-host-1',accessToken:'fixture-access-token',hostIdentityKey:golden.staticKeys.responder.publicKey});
  const identity=new Pair(raw(golden.staticKeys.initiator.privateKey));
  const {RemoteRelay}=load('remote/RemoteRelay');const relay=new RemoteRelay(parameters,identity);
  const received=[],closed=[];relay.onMessage=value=>received.push(value);relay.onClosed=code=>closed.push(code);
  return {relay,parameters,identity,sockets,timers,received,closed,load,sdkConnect};
}
async function hello(context){
  const connecting=context.relay.connect();connecting.catch(()=>{});await flush();
  const control=context.sockets[0];assert.equal(control.sent.length,0,'connect Promise alone is not HTTP 101');
  control.upgrade();await flush();assert.equal(control.sent[0].type,'hello');
  const ack=structuredClone(helloCases.find(row=>row.name==='accept-valid-hello-ack').input);
  // Fixture validates frame syntax. Select only capabilities actually offered by this client.
  ack.payload.capabilities=['transport.relay','transport.relay.attach'];control.receive(ack);await flush();
  assert.equal(control.sent[1].type,'connect.request');
  return {connecting,control};
}
async function prepare({attached=true,hostPayload=new Uint8Array(0)}={}){
  const context=setup();const opened=await hello(context);const {control}=opened;
  const accepted=structuredClone(connectCases.find(row=>row.name==='accept-connect-accepted').input);
  context.connectionId=accepted.payload.connectionId;
  if(attached)Object.assign(accepted.payload,{relayEndpoint:'wss://relay.invalid:9443/data',relayTicket:'fixture-relay-ticket',relayNodeId:'fixture-node',relayEpoch:7});
  control.receive(accepted);await flush();
  let data;
  if(attached){data=context.sockets[1];assert(data);assert.equal(data.sent.length,0);data.upgrade();await flush();assert.equal(data.sent[0].type,'relay.attach');data.receive(frame('relay.ready',{connectionId:context.connectionId,epoch:7}));await flush();}
  const handshake=control.sent.find(value=>value.type==='secure.handshake');assert(handshake);
  const prologue=Buffer.from('DSH-REMOTE\0v=1\0connection='+context.connectionId+'\0host='+context.parameters.hostDeviceId+'\0client='+context.parameters.deviceId);
  const host=respond(raw(handshake.payload.data),prologue,hostPayload);
  return {...context,...opened,data,handshake,prologue,host};
}
async function ready(options){const context=await prepare(options);context.control.receive(frame('secure.handshake',{connectionId:context.connectionId,targetDeviceId:context.parameters.deviceId,step:2,data:b64(context.host.message)}));await context.connecting;return context;}
function hostSend(context,plaintext,{counter=context.host.sending,padding=false,target=context.parameters.deviceId}={}){
  let ciphertext=b64(context.host.encrypt(plaintext));if(padding)while(ciphertext.length%4)ciphertext+='=';
  const incoming=frame('relay',{connectionId:context.connectionId,targetDeviceId:target,counter,ciphertext});
  (context.data||context.control).receive(incoming);return incoming;
}
function dshf(message,id=19){
  const result=[];const total=Math.ceil(message.length/49152);
  for(let index=0;index<total;index++){
    const part=message.slice(index*49152,(index+1)*49152);const header=Buffer.alloc(17);header.write('DSHF');header[4]=1;
    header.writeUInt32BE(id,5);header.writeUInt16BE(index,9);header.writeUInt16BE(total,11);header.writeUInt32BE(message.length,13);result.push(join(header,part));
  }return result;
}

test('fixture-backed control + relay.attach + selected ordering; token/ticket channel separation and Noise binding',async()=>{
  const context=await ready();const {control,data,parameters,relay,identity,timers}=context;
  const helloFrame=control.sent[0];assert.deepEqual(helloFrame.payload.protocols,[1]);assert.equal(helloFrame.payload.role,'client');
  assert.equal(helloFrame.payload.accessToken,'fixture-access-token');
  assert.equal(control.options?.header,undefined,'control Upgrade uses SDK-generated headers');
  assert.equal(data.options?.header,undefined,'data Upgrade uses SDK-generated headers');
  assert.deepEqual(data.sent[0].payload,{connectionId:context.connectionId,deviceId:'fixture-client-1',peerDeviceId:'fixture-host-1',ticket:'fixture-relay-ticket'});
  assert.deepEqual(control.sent.map(value=>value.type),['hello','connect.request','transport.selected','secure.handshake']);
  assert.equal(control.sent[2].payload.targetDeviceId,'fixture-host-1');assert.equal(control.sent[2].payload.transport,'relay');
  assert(!JSON.stringify(data.sent).includes('fixture-access-token'));assert(!JSON.stringify(control.sent).includes('fixture-relay-ticket'));
  assert(!control.url.includes('token'));assert(!data.url.includes('ticket'));
  assert.throws(()=>respond(raw(context.handshake.payload.data),Buffer.from('wrong connection binding')),/NOISE_DECRYPT_FAILED/);
  relay.close();assert.equal(parameters.accessToken,'');assert(!identity.destroyed);assert.equal(timers.entries.size,0);
});
test('legacy no-assignment relay keeps Noise and ciphertext on control',async()=>{
  const context=await ready({attached:false});await context.relay.send(new Uint8Array([1,2,3]));
  assert.equal(context.sockets.length,1);assert.equal(context.control.sent.at(-1).type,'relay');
  assert.deepEqual([...context.host.decrypt(raw(context.control.sent.at(-1).payload.ciphertext))],[1,2,3]);context.relay.close();
});
test('authenticated nonempty host-ack handshake completes actual relay negotiation and bidirectional transport',async()=>{
  const hostPayload=raw(golden.handshake.message2.payload);assert.equal(Buffer.from(hostPayload).toString(),'host-ack');
  const context=await ready({hostPayload});
  assert.equal(context.host.message.length,32+hostPayload.length+16);
  assert.equal(context.received.length,0,'handshake metadata is not a Remote application message');
  for(let counter=0;counter<2;counter++){
    const outbound=new Uint8Array(Buffer.from('client '+counter));await context.relay.send(outbound);
    const wire=context.data.sent.at(-1);assert.equal(wire.type,'relay');assert.equal(wire.payload.counter,counter);
    assert.deepEqual(Buffer.from(context.host.decrypt(raw(wire.payload.ciphertext))),Buffer.from(outbound));
    const inbound=new Uint8Array(Buffer.from('host '+counter));hostSend(context,inbound);
    assert.deepEqual(Buffer.from(context.received[counter]),Buffer.from(inbound));
  }
  assert.equal(context.closed.length,0);context.relay.close();assert.equal(context.timers.entries.size,0);
});
test('nonempty handshake metadata remains authenticated before ready',async()=>{
  const context=await prepare({hostPayload:new Uint8Array(Buffer.from('host-ack'))});
  const forged=new Uint8Array(context.host.message);forged[forged.length-1]^=1;
  context.control.receive(frame('secure.handshake',{connectionId:context.connectionId,targetDeviceId:context.parameters.deviceId,step:2,data:b64(forged)}));
  await assert.rejects(context.connecting,error=>error.message==='NOISE_DECRYPT_FAILED');
  assert.deepEqual(context.closed,['NOISE_DECRYPT_FAILED']);assert.equal(context.received.length,0);assert(context.control.closed&&context.data.closed);
});
test('control/data numeric close source codes and 4003 replacement are preserved without reading reason',async()=>{
  for(const channel of ['control','data'])for(const code of [1000,1006,4003]){
    const context=await ready();const socket=context[channel];
    const result={code,get reason(){assert.fail('raw close reason must never be inspected');}};
    assert.doesNotThrow(()=>socket.handlers.close(undefined,result));
    const expected=code===4003?'CONNECTION_REPLACED':(channel==='control'?'CONTROL_SOCKET_FAILED':'RELAY_SOCKET_FAILED')+'_CLOSE_'+code;
    assert.deepEqual(context.closed,[expected]);assert(context.control.closed&&context.data.closed);assert.equal(context.timers.entries.size,0);
    socket.handlers.close(undefined,result);assert.equal(context.closed.length,1,'duplicate late close is ignored');
  }
});
test('undefined SDK close result never throws and closes both control/data links',async()=>{
  for(const channel of ['control','data']){
    const context=await ready();
    assert.doesNotThrow(()=>context[channel].handlers.close({code:2300000,message:'sensitive-sentinel'},undefined));
    assert.deepEqual(context.closed,[(channel==='control'?'CONTROL_SOCKET_FAILED':'RELAY_SOCKET_FAILED')+'_CLOSE_0']);
    assert(context.control.closed&&context.data.closed);assert.equal(context.timers.entries.size,0);
  }
});
test('relay detach and control remote errors preserve distinct safe source codes',async()=>{
  for(const source of ['detach','absent','generic']){
    const context=await ready();
    if(source==='detach')context.data.receive(frame('relay.detach',{connectionId:context.connectionId}));
    else context.control.receive(frame('error',{connectionId:context.connectionId,...(source==='generic'?{code:'CONNECTION_FAILED'}:{}),message:'sensitive-sentinel'}));
    assert.deepEqual(context.closed,[source==='detach'?'RELAY_DETACHED':source==='absent'?'CONTROL_REMOTE_ERROR':'REMOTE_CONNECTION_FAILED']);
    assert(context.control.closed&&context.data.closed);assert.equal(context.timers.entries.size,0);
  }
});

test('HTTP 200 error before 101 rejects connect and sends no hello',async()=>{
  const context=setup();const pending=context.relay.connect();pending.catch(()=>{});await flush();context.sockets[0].fail(200);
  await assert.rejects(pending,error=>error.message==='CONTROL_SOCKET_FAILED');
  assert.deepEqual(context.closed,['CONTROL_SOCKET_FAILED']);
  assert.equal(context.sockets[0].sent.length,0);assert(context.sockets[0].closed);assert(!context.closed.join().includes('sensitive-sentinel'));
});
test('outbound queued canSend applies once before first fragment, preserves contiguous counters',async()=>{
  const context=await ready();const gate=deferred();context.data.blockNext=gate;
  const message=new Uint8Array(100000).fill(37);const first=context.relay.send(message);await flush();
  let permitted=true;const second=context.relay.send(new Uint8Array([99]),()=>permitted);permitted=false;
  gate.resolve();await Promise.all([first,second]);
  const relayFrames=context.data.sent.filter(value=>value.type==='relay');assert.deepEqual(relayFrames.map(value=>value.payload.counter),[0,1,2]);
  const decrypted=relayFrames.map(value=>context.host.decrypt(raw(value.payload.ciphertext)));
  assert.equal(Buffer.from(decrypted[0].slice(0,17)).toString('hex'),'44534846010000000100000003000186a0');
  assert.deepEqual(Buffer.concat(decrypted.map(value=>Buffer.from(value.slice(17)))),Buffer.from(message));context.relay.close();
});
test('inbound DSHF reassembles authenticated frames; replay/counter gaps/wrong target fail closed',async()=>{
  for(const mode of ['replay','gap','target','tamper']){
    const context=await ready();const message=new Uint8Array(100000).fill(8);
    for(const fragment of dshf(message))hostSend(context,fragment);
    assert.equal(context.received.length,1);assert.deepEqual(Buffer.from(context.received[0]),Buffer.from(message));
    const packet=hostSend(context,new Uint8Array([4]));assert.equal(context.received.length,2);
    if(mode==='replay')context.data.receive(packet);
    if(mode==='gap')hostSend(context,new Uint8Array([5]),{counter:99});
    if(mode==='target')hostSend(context,new Uint8Array([5]),{target:'some-other-device'});
    if(mode==='tamper'){const next=frame('relay',{connectionId:context.connectionId,targetDeviceId:context.parameters.deviceId,counter:context.host.sending,ciphertext:b64(context.host.encrypt(new Uint8Array([6])))});const ciphertext=raw(next.payload.ciphertext);ciphertext[0]^=1;next.payload.ciphertext=b64(ciphertext);context.data.receive(next);}
    assert.equal(context.closed.length,1,mode);assert(context.control.closed&&context.data.closed);assert.equal(context.received.length,2);assert.equal(context.timers.entries.size,0);
  }
});
test('relay.ready epoch mismatch, wrong ownership and out-of-order handshake refuse establishment',async()=>{
  for(const mode of ['epoch','owner','step']){
    if(mode==='epoch'){
      const context=setup();const {control,connecting}=await hello(context);
      control.receive(frame('connect.accepted',{connectionId:'assigned',relayEndpoint:'wss://relay.invalid/data',relayTicket:'fixture-relay-ticket',relayEpoch:2}));await flush();context.sockets[1].upgrade();await flush();
      context.sockets[1].receive(frame('relay.ready',{connectionId:'assigned',epoch:3}));await assert.rejects(connecting,/PROTOCOL_MISMATCH/);assert(!control.sent.some(value=>value.type==='secure.handshake'));
    }else{
      const context=await prepare();context.control.receive(frame('secure.handshake',{connectionId:mode==='owner'?'other':context.connectionId,targetDeviceId:context.parameters.deviceId,step:mode==='step'?1:2,data:b64(context.host.message)}));
      await assert.rejects(context.connecting,/PROTOCOL_MISMATCH|NOISE_HANDSHAKE_ORDER/);assert(context.data.closed);
    }
  }
});
test('duplicate/escaped duplicate JSON and unknown envelope fields fail closed',async()=>{
  const context=setup();const protocol=context.load('remote/RemoteProtocol');
  for(const json of ['{"v":1,"v":1,"id":"a","type":"ping","timestamp":1,"payload":{"nonce":"n"}}',
    '{"v":1,"id":"a","type":"ping","timestamp":1,"payload":{"nonce":"a","\\u006eonce":"b"}}'])assert.throws(()=>protocol.envelope(json,true),/PROTOCOL_MISMATCH/);
  assert.throws(()=>protocol.envelope(JSON.stringify({...frame('ping',{nonce:'n'}),extra:1}),true),/PROTOCOL_MISMATCH/);
  const live=await ready();live.control.receive('{"v":1,"id":"a","type":"ping","timestamp":1,"payload":{"nonce":"a","nonce":"b"}}');assert.deepEqual(live.closed,['PROTOCOL_MISMATCH']);
});
test('original protocol-v1 envelope fixtures are accepted/rejected through the control socket',async()=>{
  for(const sample of fixture('protocol-v1/control/envelope.json').cases){
    const context=setup();const pending=context.relay.connect();pending.catch(()=>{});await flush();
    context.sockets[0].upgrade();await flush();context.sockets[0].receive(sample.input);await flush();
    if(sample.expect.accepted){assert.equal(context.closed.length,0,sample.name);assert.equal(context.sockets[0].sent.at(-1).type,'pong');context.relay.close();}
    else assert.equal(context.closed.length,1,sample.name);
    await assert.rejects(pending);
  }
});

test('DSHF public layout and reassembly limits: exact max, missing first, duplicate, gaps, oversize, reset',()=>{
  const context=setup();const {RemoteFragments}=context.load('remote/RemoteProtocol');
  const message=new Uint8Array(4194304).fill(1);const encoded=new RemoteFragments().encode(message);assert.equal(encoded.length,86);
  const decoder=new RemoteFragments();let result;for(const part of encoded)result=decoder.decode(part);assert.deepEqual(Buffer.from(result),Buffer.from(message));
  assert.throws(()=>new RemoteFragments().encode(new Uint8Array(4194305)),/FRAME_TOO_LARGE/);
  const two=dshf(new Uint8Array(49153));assert.throws(()=>new RemoteFragments().decode(two[1]),/PROTOCOL_MISMATCH/);
  const duplicate=new RemoteFragments();duplicate.decode(two[0]);assert.throws(()=>duplicate.decode(two[0]),/PROTOCOL_MISMATCH/);
  const truncated=two[1].slice(0,-1);const bad=new RemoteFragments();bad.decode(two[0]);assert.throws(()=>bad.decode(truncated),/PROTOCOL_MISMATCH/);
  const many=new RemoteFragments();for(let id=1;id<=8;id++)many.decode(dshf(new Uint8Array(49153),id)[0]);assert.throws(()=>many.decode(dshf(new Uint8Array(49153),9)[0]),/PROTOCOL_MISMATCH/);
  many.reset();assert.equal(many.decode(dshf(new Uint8Array(49153),9)[0]),null);many.reset();
});
test('canonical base64url rule from protocol-v1 relay fixture rejects padding even when Noise authenticates',async()=>{
  const rejected=fixture('protocol-v1/control/relay.json').cases.find(row=>row.name==='reject-relay-with-padding');assert.equal(rejected.expect.accepted,false);
  const context=await ready();hostSend(context,new Uint8Array([42]),{padding:true});
  assert.equal(context.received.length,0,'padded authenticated ciphertext must still fail protocol conformance');
  assert.equal(context.closed.length,1);context.relay.close();
});
test('protocol-v1 nonzero unused base64 bits are rejected independently of AEAD authentication',async()=>{
  const rejected=fixture('protocol-v1/control/relay.json').cases.find(row=>row.name==='reject-relay-with-nonzero-unused-bits');assert.equal(rejected.expect.accepted,false);
  const context=await ready();const counter=context.host.sending;const ciphertext=context.host.encrypt(new Uint8Array([42]));
  const canonical=b64(ciphertext);const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  const altered=canonical.slice(0,-1)+alphabet[alphabet.indexOf(canonical.at(-1))^1];
  assert.deepEqual(Buffer.from(raw(altered)),Buffer.from(ciphertext));
  context.data.receive(frame('relay',{connectionId:context.connectionId,targetDeviceId:context.parameters.deviceId,counter,ciphertext:altered}));
  assert.equal(context.received.length,0,'noncanonical encoding must not reach plaintext consumer');assert.equal(context.closed.length,1);context.relay.close();
});

test('close rejects connect even when SDK connect Promise never resolves',async()=>{
  const context=setup();context.sdkConnect.hold=true;let state='pending';
  const pending=context.relay.connect().then(()=>state='resolved',()=>state='rejected');await flush();
  context.relay.close();await flush();const observed=state;
  context.sdkConnect.gate.resolve();await pending;
  assert.equal(observed,'rejected','close must reject before the underlying SDK connect settles');
});
test('close promptly settles blocked and queued sends, without waiting for SDK send',async()=>{
  const context=await ready();const gate=deferred();context.data.blockNext=gate;
  let firstState='pending',secondState='pending';
  const first=context.relay.send(new Uint8Array([1])).then(()=>firstState='resolved',()=>firstState='rejected');
  await flush();const second=context.relay.send(new Uint8Array([2])).then(()=>secondState='resolved',()=>secondState='rejected');
  context.relay.close();await flush();
  const observed=[firstState,secondState];gate.resolve();await Promise.all([first,second]);
  assert.deepEqual(observed,['rejected','rejected'],'close must reject both the blocked write and its queued successor');
});
