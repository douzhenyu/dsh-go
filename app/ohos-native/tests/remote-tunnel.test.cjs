// In-memory authenticated Link only. No credentials, hosts, sockets or native SDK calls.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createLoader, flush, deferred } = require('./ets-loader.cjs');
const encode = value => new Uint8Array(Buffer.from(JSON.stringify(value)));
const decode = value => JSON.parse(Buffer.from(value).toString());
const CHUNK = 512 * 1024;
class Clock {
  constructor() { this.entries = new Map(); this.next = 1; }
  set = (callback, ms) => { const id=this.next++; this.entries.set(id,{callback,ms}); return id; };
  clear = id => this.entries.delete(id);
  expire(ms) { for(const [id,timer] of [...this.entries]) if(timer.ms<=ms){ this.entries.delete(id);timer.callback(); } }
}
class Link {
  constructor(caps=['harness.remote.v3']) { this.caps=caps;this.sent=[];this.queued=[];this.hold=false;this.closed=false;this.handler=null; }
  async connect() {}
  send(bytes, canSend) {
    const task={request:decode(bytes),canSend,gate:deferred()};this.queued.push(task);
    if(!this.hold)this.release(task);
    return task.gate.promise;
  }
  release(task=this.queued[0]) {
    const index=this.queued.indexOf(task);if(index>=0)this.queued.splice(index,1);
    if(!task.canSend || task.canSend()) {
      this.sent.push(task.request);
      if(this.handler)this.handler(task.request,this);
      else this.defaultReply(task.request);
    }
    task.gate.resolve();
  }
  defaultReply(request) {
    const {method}=request.payload;
    if(method==='harness.transport.describe')this.reply(request,{capabilities:this.caps});
    else if(method==='remote.history.configure')this.reply(request,{compact:false});
    else if(method==='harness.remote.call')this.reply(request,{ok:true,value:{items:[]}});
    else this.reply(request,{});
  }
  frame(type,payload) { this.onMessage?.(encode({v:1,id:crypto.randomUUID(),timestamp:Date.now(),type,payload})); }
  reply(request,result) { this.frame('rpc.response',{requestId:request.id,result}); }
  reject(request,code,message='synthetic error') { this.frame('rpc.error',{requestId:request.id,code,message}); }
  event(event,data) { this.frame('event',{event,data}); }
  close() { this.closed=true; }
}
function setup(caps) {
  const clock=new Clock();const link=new Link(caps);
  const bytes={utf8:text=>new Uint8Array(Buffer.from(text)),text:value=>new TextDecoder('utf-8',{fatal:true}).decode(value),
    bytes:(...values)=>new Uint8Array(Buffer.concat(values.map(v=>Buffer.from(v)))),
    base64url:value=>Buffer.from(value).toString('base64url'),unbase64url:value=>new Uint8Array(Buffer.from(value,'base64url'))};
  const load=createLoader({'@kit.ArkTS':{util:{generateRandomUUID:()=>crypto.randomUUID()}},'./RemoteBytes':bytes},
    {setTimeout:clock.set,clearTimeout:clock.clear});
  const {RemoteTunnel}=load('remote/RemoteTunnel');
  return {tunnel:new RemoteTunnel(link),link,clock};
}
async function connected(caps) {const value=setup(caps);await value.tunnel.connect();return value;}
function methods(link) {return link.sent.map(request=>request.payload.method);}

test('describe is first, full-history negotiation is explicit and Gateway result unwraps exactly once',async()=>{
  const {tunnel,link,clock}=await connected(['harness.remote.v3','remote.history.compact.v1']);
  assert.deepEqual(methods(link),['harness.transport.describe','remote.history.configure']);
  assert.deepEqual(link.sent[1].payload.params,{compact:false});
  link.handler=(request)=>{assert.equal(request.payload.method,'harness.remote.call');assert.deepEqual(request.payload.params,{endpoint:'session/list',payload:{args:{_request:{}}}});link.reply(request,{ok:true,value:{ok:false,nested:true}});};
  assert.equal(await tunnel.rpc('session/list','{"_request":{}}'),'{"ok":false,"nested":true}');
  tunnel.close();assert(link.closed);assert.equal(clock.entries.size,0);
});
test('malformed/conflicting/legacy capabilities fail before any business call',async()=>{
  for(const caps of [[],['harness.remote.v1'],['harness.remote.v3','harness.remote.v1'],['harness.remote.v3','harness.remote.v3'],['harness.remote.v3',5],Array(129).fill('x')]) {
    const {tunnel,link,clock}=setup(caps);
    await assert.rejects(tunnel.connect(),/INVALID_MESSAGE|HARNESS_VERSION_INCOMPATIBLE|PROTOCOL_MISMATCH/);
    assert(link.closed);assert.deepEqual(methods(link),['harness.transport.describe']);assert.equal(clock.entries.size,0);
  }
});
test('pending limit is 128; close rejects calls without waiting for stuck sends',async()=>{
  const {tunnel,link,clock}=await connected();link.hold=true;
  const calls=Array.from({length:128},()=>tunnel.rpc('session/prompt','{}'));
  const settled=Promise.allSettled(calls);
  await assert.rejects(tunnel.rpc('session/prompt','{}'),/RATE_LIMITED/);
  assert.equal(link.queued.length,128);tunnel.close();
  const outcomes=await settled;assert(outcomes.every(row=>row.status==='rejected' && /CLIENT_CLOSED/.test(row.reason.message)));
  for(const queued of [...link.queued])link.release(queued);
  assert.equal(methods(link).filter(method=>method==='harness.remote.call').length,0);assert.equal(clock.entries.size,0);
});
test('queued deadline disables canSend; late and mismatched responses are ignored',async()=>{
  const {tunnel,link,clock}=await connected();link.hold=true;
  const call=tunnel.rpc('session/prompt','{}');const queued=link.queued[0];
  clock.expire(65000);await assert.rejects(call,/RPC_TIMEOUT/);
  assert.equal(queued.canSend(),false);link.release(queued);
  link.reply(queued.request,{ok:true,value:'late'});
  assert.equal(methods(link).length,1);tunnel.close();assert.equal(clock.entries.size,0);
});
test('frames before open ack, natural close, failures and queued open cancellation',async()=>{
  const {tunnel,link,clock}=await connected();let openRequest;const values=[];const errors=[];
  link.handler=request=>{
    if(request.payload.method==='harness.remote.stream.open'){
      if(request.payload.params.streamId==='events') {
        openRequest=request;assert.deepEqual(request.payload.params,{streamId:'events',endpoint:'$events',payload:{args:{}}});
        link.event('harness.remote.frame',{streamId:'events',hasValue:true,value:{type:'ready',clientId:'fixture'}});
      }
    }else link.reply(request,{});
  };
  tunnel.open('events','$events','{}',value=>values.push(JSON.parse(value)),error=>errors.push(error.message));
  await flush();assert.equal(values[0].clientId,'fixture');link.reply(openRequest,{});
  link.event('harness.remote.stream.closed',{streamId:'events',reason:'completed'});await flush();assert.deepEqual(errors,['STREAM_ENDED']);
  tunnel.open('failed','session/follow','{}',()=>{},error=>errors.push(error.message));
  link.event('harness.remote.stream.closed',{streamId:'failed',reason:'failed',failure:{code:'METHOD_NOT_ALLOWED',message:'do not echo sensitive sentinel'}});
  await flush();assert.equal(errors.at(-1),'METHOD_NOT_ALLOWED');
  link.hold=true;tunnel.open('cancelled','workspace/follow','{}',()=>assert.fail('late frame'),()=>assert.fail('cancel is silent'));
  const queued=link.queued[0];tunnel.cancel('cancelled');assert.equal(queued.canSend(),false);
  for(const task of [...link.queued])link.release(task);await flush();
  assert(!link.sent.some(request=>request.payload.method==='harness.remote.stream.open'&&request.payload.params.streamId==='cancelled'));
  assert(link.sent.some(request=>request.payload.method==='harness.remote.stream.close'&&request.payload.params.streamId==='cancelled'));
  tunnel.close();assert.equal(clock.entries.size,0);
});
test('open ack timeout closes the remote slot even after ready frame arrived',async()=>{
  const {tunnel,link,clock}=await connected();const errors=[];
  link.handler=request=>{if(request.payload.method==='harness.remote.stream.open')link.event('harness.remote.frame',{streamId:'s',hasValue:true,value:{type:'snapshot'}});else link.reply(request,{});};
  tunnel.open('s','session/follow','{}',()=>{},error=>errors.push(error.message));await flush();
  clock.expire(15000);await flush();assert.deepEqual(errors,['RPC_TIMEOUT']);
  assert(methods(link).includes('harness.remote.stream.close'));tunnel.close();
});
test('Gateway and RPC errors use stable codes; RESPONSE_TOO_LARGE never repeats a write',async()=>{
  const {tunnel,link}=await connected(['harness.remote.v3','harness.remote.transfer.v1']);
  link.handler=request=>link.reject(request,'RESPONSE_TOO_LARGE','sensitive-sentinel');
  await assert.rejects(tunnel.rpc('commands/execute','{}'),error=>error.message==='RESPONSE_TOO_LARGE');
  assert.equal(methods(link).filter(method=>method==='harness.remote.call').length,1);
  assert(!methods(link).includes('harness.remote.transfer.open'));
  link.handler=request=>link.reply(request,{ok:false,error:{code:'METHOD_NOT_ALLOWED',message:'sensitive-sentinel'}});
  await assert.rejects(tunnel.rpc('session/create','{}'),error=>error.message==='METHOD_NOT_ALLOWED');
  for (const [wire, expected] of [['settings/conflict','settings/conflict'], ['credential/rejected','credential/rejected'], ['sensitive message','REMOTE_ERROR']]) {
    link.handler=request=>link.reply(request,{ok:false,error:{code:wire,message:'sensitive-sentinel'}});
    await assert.rejects(tunnel.rpc('settings/mutate','{}'),error=>error.message===expected && !error.message.includes('sensitive-sentinel'));
  }
  tunnel.close();
});
test('stream transfer reads canonical chunks and acks before following frames/close',async()=>{
  const {tunnel,link}=await connected(['harness.remote.v3','harness.remote.stream.transfer.v1']);
  const transferId=crypto.randomUUID();const frame={streamId:'s',hasValue:true,value:{type:'snapshot',body:'x'.repeat(CHUNK+27)}};
  const content=encode(frame);const values=[];const errors=[];const order=[];
  link.handler=request=>{
    const {method,params}=request.payload;
    if(method==='harness.remote.stream.open'){assert.equal(params.transferFrames,true);link.reply(request,{});}
    else if(method==='harness.remote.transfer.read'){
      order.push('read'+params.index);link.reply(request,{transferId,index:params.index,data:Buffer.from(content.slice(params.index*CHUNK,(params.index+1)*CHUNK)).toString('base64')});
    }else {order.push(method);link.reply(request,{});}
  };
  tunnel.open('s','session/follow','{}',value=>{order.push('item');values.push(JSON.parse(value));},error=>{order.push('end');errors.push(error.message);});
  link.event('harness.remote.frame',{streamId:'s',hasValue:true,transfer:{kind:'chunked',transferId,totalBytes:content.length,totalChunks:Math.ceil(content.length/CHUNK)}});
  link.event('harness.remote.frame',{streamId:'s',hasValue:true,value:{type:'event'}});
  link.event('harness.remote.stream.closed',{streamId:'s',reason:'completed'});
  for(let i=0;i<5;i++)await flush();
  assert.deepEqual(values.map(value=>value.type),['snapshot','event']);assert.deepEqual(errors,['STREAM_ENDED']);
  assert.deepEqual(order,['read0','read1','harness.remote.transfer.close','item','item','end']);tunnel.close();
});
test('transfer cancel releases Host allocation; malformed data never reaches UI',async()=>{
  for(const cancel of [false,true]) {
    const {tunnel,link}=await connected(['harness.remote.v3','harness.remote.stream.transfer.v1']);const errors=[];const transferId=crypto.randomUUID();
    let read;
    link.handler=request=>{
      if(request.payload.method==='harness.remote.transfer.read'){read=request;if(!cancel)link.reply(request,{transferId,index:0,data:'YQ'});}
      else link.reply(request,{});
    };
    tunnel.open('s','session/follow','{}',()=>assert.fail('must not emit malformed transfer'),error=>errors.push(error.message));
    link.event('harness.remote.frame',{streamId:'s',hasValue:true,transfer:{kind:'chunked',transferId,totalBytes:1,totalChunks:1}});
    await flush();if(cancel){assert(read);tunnel.cancel('s');}
    for(let i=0;i<3;i++)await flush();
    assert(methods(link).includes('harness.remote.transfer.close'));
    assert.deepEqual(errors,cancel?[]:['PROTOCOL_MISMATCH']);tunnel.close();
  }
});
test('proactive large unary transfer executes commit once and reads its saved response',async()=>{
  const {tunnel,link}=await connected(['harness.remote.v3','harness.remote.transfer.v1']);
  let id,bytesExpected,chunksExpected;const chunks=[];let commits=0;
  const response=encode({ok:true,value:{result:'r'.repeat(CHUNK+20)}});
  link.handler=request=>{
    const {method,params}=request.payload;
    if(method==='harness.remote.transfer.open'){id=params.transferId;bytesExpected=params.totalBytes;chunksExpected=params.totalChunks;link.reply(request,{});}
    else if(method==='harness.remote.transfer.chunk'){assert.equal(params.transferId,id);assert.equal(params.index,chunks.length);chunks.push(Buffer.from(params.data,'base64'));link.reply(request,{});}
    else if(method==='harness.remote.transfer.commit'){commits++;link.reply(request,{kind:'chunked',transferId:id,totalBytes:response.length,totalChunks:Math.ceil(response.length/CHUNK)});}
    else if(method==='harness.remote.transfer.read')link.reply(request,{transferId:id,index:params.index,data:Buffer.from(response.slice(params.index*CHUNK,(params.index+1)*CHUNK)).toString('base64')});
    else link.reply(request,{});
  };
  const value=JSON.parse(await tunnel.rpc('session/prompt',JSON.stringify({request:{text:'x'.repeat(2*1024*1024)}})));
  assert.equal(value.result.length,CHUNK+20);assert.equal(commits,1);assert.equal(chunks.length,chunksExpected);
  const request=Buffer.concat(chunks);assert.equal(request.length,bytesExpected);assert.equal(JSON.parse(request).endpoint,'session/prompt');
  assert(!methods(link).includes('harness.remote.call'));assert.equal(methods(link).at(-1),'harness.remote.transfer.close');tunnel.close();
});
test('oversized calls without transfer capability fail before a business write',async()=>{
  const {tunnel,link}=await connected();
  await assert.rejects(tunnel.rpc('session/prompt',JSON.stringify({text:'x'.repeat(2*1024*1024)})),/FRAME_TOO_LARGE/);
  assert.deepEqual(methods(link),['harness.transport.describe']);tunnel.close();
});
test('malformed envelope/duplicate keys close Link; stale callback epochs cannot revive it',async()=>{
  const {tunnel,link,clock}=await connected();link.hold=true;const previous=link.onMessage;
  const pending=tunnel.rpc('session/list','{}');
  link.onMessage(new Uint8Array(Buffer.from('{"v":1,"v":1,"id":"bad","timestamp":1,"type":"event","payload":{}}')));
  await assert.rejects(pending,/TRANSPORT_CLOSED/);assert(link.closed);
  previous(encode({v:1,id:'late',timestamp:1,type:'event',payload:{event:'harness.remote.frame',data:{streamId:'x',hasValue:true,value:{}}}}));
  await assert.rejects(tunnel.connect(),/CLIENT_CLOSED/);assert.equal(clock.entries.size,0);
});
test('close rejects a connect waiting inside Link.connect',async()=>{
  const {tunnel,link}=setup();const gate=deferred();link.connect=()=>gate.promise;
  const pending=tunnel.connect();tunnel.close();await assert.rejects(pending,/CLIENT_CLOSED/);
  gate.resolve();await flush();assert.equal(link.sent.length,0);
});
