// Host-side contract check. Runs without contacting a Host or invoking hvigor.
// Usage: node NativeContract.test.cjs /path/to/typescript/lib/typescript.js
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../../../../../../..');
const modules = new Map();
const requests = [];
const sockets = [];
let uuid = 0;
let socketFailure = null;
class FakeRequest {
  on(name, callback) { this[name] = callback; }
  request(url, options, callback) { this.url = url; this.options = options; this.callback = callback; requests.push(this); }
  destroy() { this.destroyed = true; }
}
class FakeSocket {
  constructor() { this.handlers = {}; this.sent = []; sockets.push(this); }
  on(name, callback) { this.handlers[name] = callback; }
  async connect(url, options) { this.url = url; this.options = options; if (socketFailure) throw socketFailure; this.handlers.open(); return true; }
  async send(frame) { this.sent.push(JSON.parse(frame)); return true; }
  async close() { this.closed = true; return true; }
  item(id, value) { this.handlers.message(null, JSON.stringify({type:'item',streamId:id,value})); }
}
const network = {
  http: {createHttp:()=>new FakeRequest(), RequestMethod:{GET:'GET',POST:'POST'}, HttpDataType:{STRING:0}},
  webSocket: {createWebSocket:()=>new FakeSocket()}
};
function load(name) {
  if (modules.has(name)) return modules.get(name);
  const source = fs.readFileSync(path.join(__dirname, name + '.ets'), 'utf8');
  const output = ts.transpileModule(source, {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021},reportDiagnostics:true});
  assert.equal((output.diagnostics || []).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0);
  const exports = {};
  const imports = name => name === '@kit.NetworkKit' ? network : name === '@kit.ArkTS' ? {util:{generateRandomUUID:()=>String(++uuid)}} : name === '@kit.BasicServicesKit' ? {deviceInfo:{sdkApiVersion:23}} : load(name.replace('./',''));
  vm.runInNewContext(output.outputText,{exports,require:imports,setTimeout,clearTimeout,console});
  modules.set(name,exports); return exports;
}
function fixture(name) {
  return fs.readFileSync(path.join(root,'packages/dsh_client/test/fixtures',name),'utf8').trim().split('\n').map(JSON.parse);
}
async function flush() { await Promise.resolve(); await Promise.resolve(); }
async function connect(client, host) {
  const pending = client.connect('http://' + host + '/?token=synthetic-test-token');
  const request = requests.at(-1);
  assert.equal(request.options.maxRedirects,0); assert.equal(request.options.usingCache,false);
  request.headersReceive({'set-cookie':'dsh-auth-fixture=synthetic-cookie; Path=/; HttpOnly'});
  request.callback({code:2300047},undefined);
  await flush();
  const socket = sockets.at(-1); const opening = socket.sent[0];
  assert.equal(opening.endpoint,'$events');
  assert.equal(socket.options.header.Cookie,'dsh-auth-fixture=synthetic-cookie');
  assert.equal(socket.options.header.Host,host);
  assert.equal(socket.options.header['Content-Type'],undefined);
  assert.equal(socket.options.header.Origin,undefined);
  socket.item(opening.streamId,{type:'ready',clientId:'fixture-client',host:{home:'/fixture'}});
  await pending;
  return socket;
}
async function main() {
  const d = load('NativeDecode');
  const blank = fixture('follow_blank_session.jsonl');
  const snapshot = d.sessionUpdate('s',blank[0]);
  assert.equal(snapshot.cursor,2); assert.equal(snapshot.records.length,3);
  let count=0, approvals=0, text='';
  for (const row of fixture('mux_raw_approval.jsonl')) {
    if (row.dir !== 'in' || row.frame.type !== 'item') continue;
    const value = row.frame.value;
    if (['snapshot','event','assistant-stream'].includes(value.type)) {
      const u = d.sessionUpdate('s',value); count++; text += u.deltaText;
    } else {
      const h = d.hostEvent(value);
      if (h.event === 'approval/request') { approvals++; assert(h.eventId); assert.equal(h.toolName,'bash'); }
    }
  }
  assert(count>100); assert.equal(approvals,1); assert.equal(text,'hi');
  assert.equal(d.session({sessionId:'s',projections:{kind:'sequenced',values:{title:'Hello'}}}).title,'Hello');
  assert.equal(d.record({seq:1,type:'user/message',data:{source:{kind:'user'},content:[{type:'text',text:'hello'}]}}).text,'hello');
  assert.equal(d.record({seq:2,type:'assistant/message',data:{message:{content:[{type:'text',text:'answer'}]}}}).text,'answer');
  assert.throws(()=>d.parseObject('[]'),/PROTOCOL/);
  assert.throws(()=>d.sessionUpdate('s',{type:'unsupported'}),/UNSUPPORTED/);
  const {NativeClient} = load('NativeClient');
  const failedClient = new NativeClient();
  let diagnosticState = '';
  failedClient.onState = (_state, message) => diagnosticState = message;
  const failedLogin = failedClient.connect('http://diagnostic.invalid/?token=synthetic-test-token');
  requests.at(-1).callback({code:2300006,message:'sensitive-sentinel'},undefined);
  await assert.rejects(failedLogin,/CONNECTION_FAILED: login-http code=2300006 status=0/);
  assert.equal(diagnosticState,'CONNECTION_FAILED: login-http code=2300006 status=0');
  const refusedLogin = failedClient.connect('http://diagnostic.invalid/?token=synthetic-test-token');
  requests.at(-1).callback(null,{responseCode:401});
  await assert.rejects(refusedLogin,/login-http code=0 status=401/);
  socketFailure = {code:2302002,message:'sensitive-sentinel'};
  const failedUpgrade = failedClient.connect('http://diagnostic.invalid/?token=synthetic-test-token');
  requests.at(-1).callback(null,{responseCode:303,header:{'set-cookie':'dsh-auth-fixture=synthetic-cookie'}});
  await assert.rejects(failedUpgrade,/ws-upgrade code=2302002 status=0/);
  assert(!diagnosticState.includes('sensitive-sentinel'));
  socketFailure = null;
  const client = new NativeClient();
  const first = await connect(client,'host-one.invalid:1234');
  const call = client.rpc('session/list','{"_request":{}}');
  const request = requests.at(-1);
  assert.equal(request.options.maxRedirects,0);
  const envelope=JSON.parse(request.options.extraData);
  assert.equal(envelope.payload.args._request.constructor,Object);
  request.callback(null,{responseCode:200,result:JSON.stringify({type:'server-response',rpcId:'wrong',result:{ok:true,value:{items:[]}}})});
  await assert.rejects(call,/correlation/);
  const pending=client.send('fixture-session','fixture prompt');
  const retired=requests.at(-1);
  client.disconnect();
  await assert.rejects(pending,/DISCONNECTED/); assert(retired.destroyed); assert(first.closed);
  const second=await connect(client,'host-two.invalid:5678');
  assert(second.url.startsWith('ws://host-two.invalid:5678/'));
  let received=0;
  const id=client.follow('s',()=>received++,()=>{});
  first.item(first.sent[0].streamId,{type:'waterfall',eventId:'old',event:'approval/request',request:{}});
  second.item(id,blank[0]); assert.equal(received,1);
  second.item(id,{type:'event',event:{type:'turn/start',seq:10,data:{}}});
  assert(second.sent.some(frame=>frame.type==='cancel' && frame.streamId===id));
  await assert.rejects(client.respondApproval('old','allowed-once'),/STALE_REQUEST/);
  let genericValue = '';
  const genericId = client.subscribe('workspace/follow','{}', value => genericValue = value, ()=>{});
  second.item(genericId,[1,'two']);
  assert.equal(genericValue,'[1,"two"]');
  client.unfollow(genericId);
  const q = d.hostEvent({type:'waterfall',event:'user-questions/request',eventId:'question',agentId:'s',request:{wait:{timed:true,callId:'wait-call'},questions:[{id:'q',question:'Choose',options:[]}]}});
  assert.equal(q.timed,true); assert.equal(q.waitCallId,'wait-call');
  second.item(second.sent[0].streamId,JSON.parse(q.rawJson));
  let remaining = -1;
  const waitId = client.claimQuestionWait(q.sessionId,q.waitCallId, value => remaining = value, ()=>{});
  const waitOpen = second.sent.at(-1);
  assert.equal(waitOpen.endpoint,'userQuestions/attachWait');
  assert.equal(waitOpen.payload.args.agentId,'s'); assert.equal(waitOpen.payload.args.callId,'wait-call');
  second.item(waitId,{remainingMs:1234}); assert.equal(remaining,1234);
  client.unfollow(waitId);
  const declined = client.rejectQuestion('question',true);
  const declineRequest = requests.at(-1); const declineEnvelope = JSON.parse(declineRequest.options.extraData);
  assert.equal(declineEnvelope.payload.args.outcome.error.code,'ASK_TIMED_OUT');
  assert.equal(declineEnvelope.payload.args.clientId,'fixture-client');
  declineRequest.callback(null,{responseCode:200,result:JSON.stringify({type:'server-response',rpcId:declineEnvelope.rpcId,result:{ok:true}})});
  await declined;
  client.disconnect();
  class FakeCarrier {
    constructor() { this.opens = []; this.calls = []; this.cancelled = []; }
    async connect() {}
    open(id, endpoint, args, onItem, onError) {
      this.opens.push({id,endpoint,args,onItem,onError});
      if (endpoint === '$events') onItem(JSON.stringify({type:'ready',clientId:'remote-fixture'}));
      if (endpoint === 'workspace/follow') onItem(JSON.stringify({type:'baseline',value:{items:[],archivedSessionIds:[]}}));
    }
    async rpc(endpoint, args) {
      this.calls.push({endpoint,args:JSON.parse(args)});
      if (endpoint === 'session/list') return '{"items":[]}';
      if (endpoint === 'session/cancel') return new Promise(()=>{});
      return 'null';
    }
    cancel(id) { this.cancelled.push(id); }
    close() { this.closed = true; }
  }
  const requestCount = requests.length;
  const remote = new FakeCarrier();
  await client.connectCarrier(remote);
  assert.equal(requests.length, requestCount, 'remote connect must not perform launch-token login');
  assert.equal((await client.sessions()).length,0);
  const remoteEvents = remote.opens.find(row=>row.endpoint==='$events');
  remoteEvents.onItem(JSON.stringify({type:'waterfall',event:'approval/request',eventId:'remote-approval',agentId:'s',request:{toolName:'bash'}}));
  await flush();
  await client.respondApproval('remote-approval','allowed-once');
  const responseCall = remote.calls.find(row=>row.endpoint==='$events/result');
  assert.equal(responseCall.args.clientId,'remote-fixture');
  const remoteFollow = client.follow('s',()=>received++,()=>{});
  const remoteStream = remote.opens.find(row=>row.id===remoteFollow);
  remoteStream.onItem(JSON.stringify(blank[0])); await flush(); assert.equal(received,2);
  client.unfollow(remoteFollow); assert(remote.cancelled.includes(remoteFollow));
  const remotePending = client.cancel('s');
  client.disconnect(); await assert.rejects(remotePending,/DISCONNECTED/); assert(remote.closed);
  const remoteNext = new FakeCarrier(); await client.connectCarrier(remoteNext);
  remoteEvents.onItem(JSON.stringify({type:'waterfall',event:'approval/request',eventId:'retired-remote',request:{}}));
  await flush(); await assert.rejects(client.respondApproval('retired-remote','allowed-once'),/STALE_REQUEST/);
  remoteNext.onState('error','BAD: sensitive-sentinel');
  assert.equal(remoteNext.closed,true);
  client.disconnect();
  console.log('PASS: '+count+' recorded session frames; direct auth/diagnostics/epochs; cookie-free carrier ready/RPC/approval/follow/cancellation/retired epochs');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
