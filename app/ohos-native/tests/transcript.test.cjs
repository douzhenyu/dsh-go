const test = require('node:test');
const assert = require('node:assert/strict');
const { createLoader, fixture } = require('./ets-loader.cjs');

function harness() {
  const load = createLoader();
  const { Transcript } = load('state/Transcript');
  const decode = load('data/NativeDecode');
  const transcript = new Transcript();
  return { transcript, apply: frame => transcript.apply(decode.sessionUpdate('fixture-session', frame)), decode };
}
function event(seq, type, data) { return { type: 'event', event: { seq, type, time: 1, data } }; }
function stream(type, values = {}) { return { type: 'assistant-stream', frame: { type, attemptId: 'synthetic-attempt', ...values } }; }
const assistants = transcript => transcript.messages().filter(m => m.role === 'assistant' && !m.toolName && !m.notice);

test('recorded reply: a visible draft settles to one durable answer; duplicate durable delivery stays deduplicated', () => {
  const { transcript, apply } = harness();
  const frames = fixture('follow_reply_ok.jsonl');
  const durable = frames.find(f => f.event?.type === 'assistant/message');
  const durableIndex = frames.indexOf(durable);
  for (const frame of frames.slice(0, durableIndex)) apply(frame);
  assert.equal(assistants(transcript).length, 1);
  assert.equal(assistants(transcript)[0].text, 'OK');
  assert.equal(assistants(transcript)[0].streaming, true);
  apply(durable);
  assert.equal(assistants(transcript).length, 1);
  assert.equal(assistants(transcript)[0].text, 'OK');
  assert.notEqual(assistants(transcript)[0].streaming, true);
  apply(durable);
  for (const frame of frames.slice(durableIndex + 1)) apply(frame);
  assert.equal(assistants(transcript).length, 1);
  assert.equal(transcript.running, false);
  assert.equal(transcript.messages().filter(m => m.role === 'user').length, 1, 'runtime and skill catalog are not user prompts');
});

test('recorded reply: stream-end before durable commit retains the draft until its recorded seq arrives', () => {
  // Only transport delivery order is changed; all frames remain the recorded protocol payloads.
  const { transcript, apply } = harness();
  const frames = fixture('follow_reply_ok.jsonl');
  const durable = frames.find(f => f.event?.type === 'assistant/message');
  const end = frames.find(f => f.frame?.type === 'end');
  for (const frame of frames.slice(0, frames.indexOf(durable))) apply(frame);
  apply(end);
  assert.equal(assistants(transcript)[0].streaming, true);
  apply(durable);
  assert.equal(assistants(transcript).length, 1);
  assert.equal(assistants(transcript)[0].seq, durable.event.seq);
  assert.notEqual(assistants(transcript)[0].streaming, true);
});

test('recorded reconnect snapshot restores compact activeAttempt reasoning and later settles it', () => {
  const { transcript, apply } = harness();
  const frames = fixture('follow_approval_with_resync.jsonl');
  const reconnect = frames.find(f => f.type === 'snapshot' && f.assistantStream?.activeAttempt);
  assert.ok(reconnect, 'fixture must contain an actual mid-stream reconnect snapshot');
  const reasoning = reconnect.assistantStream.activeAttempt.stream
    .filter(f => f.type === 'reasoning-chunks').flatMap(f => f.texts).join('');
  assert.ok(reasoning.length > 0, 'recorded compact reasoning must exercise recovery');
  apply(reconnect);
  assert.equal(assistants(transcript).length, 1);
  assert.equal(assistants(transcript)[0].thinkText, reasoning);
  assert.equal(assistants(transcript)[0].streaming, true);
  assert.equal(transcript.running, true);
  for (const frame of frames.slice(frames.indexOf(reconnect) + 1)) apply(frame);
  assert.equal(transcript.running, false);
  assert.equal(transcript.messages().filter(m => m.streaming).length, 0);
  assert.equal(transcript.messages().filter(m => m.toolName).length, 1);
  assert.equal(transcript.messages().find(m => m.toolName).toolDetail, 'hi\n');
  assert.equal(assistants(transcript).at(-1).text, 'hi');
});

test('recorded cancel clears drafts and reports the object-shaped aborted reason', () => {
  const { transcript, apply } = harness();
  for (const frame of fixture('follow_cancel.jsonl')) apply(frame);
  assert.equal(transcript.running, false);
  assert.equal(transcript.messages().filter(m => m.streaming).length, 0);
  assert.ok(transcript.messages().some(m => m.notice && m.text.includes('已停止')));
});

test('synthetic boundary: compact snapshot restores text chunks as well as reasoning chunks', () => {
  // Captured reconnect covers reasoning only; this boundary adds the documented text-chunks sibling.
  const { transcript, apply } = harness();
  apply({ type: 'snapshot', cursor: 2, records: [], hasMore: true, assistantStream: {
    activeAttempt: { attemptId: 'synthetic-attempt', turn: 1, step: 1, stream: [
      { type: 'reasoning-chunks', texts: ['think ', 'once'] }, { type: 'text-chunks', texts: ['part', 'ial'] }
    ] }
  } });
  assert.equal(assistants(transcript)[0].text, 'partial');
  assert.equal(assistants(transcript)[0].thinkText, 'think once');
  assert.equal(transcript.hasMore, true);
});

test('synthetic boundary: object-shaped turn/end error preserves its failure kind and stops unfinished tools', () => {
  const { transcript, apply } = harness();
  apply(event(1, 'turn/start', { turn: 1 }));
  apply(event(2, 'tool/call', { callId: 'tool-1', name: 'bash', arguments: '{}' }));
  apply(event(3, 'turn/end', { turn: 1, reason: { kind: 'error', error: { kind: 'rate-limit' } } }));
  assert.equal(transcript.running, false);
  assert.match(transcript.messages().find(m => m.notice).text, /rate-limit/);
  assert.equal(transcript.messages().find(m => m.toolName).toolStatus, '未返回结果');
});

test('recorded tool result remains visible when history pagination excludes its earlier call', () => {
  const { transcript, apply } = harness();
  const result = fixture('follow_approval_with_resync.jsonl').find(f => f.event?.type === 'tool/result');
  apply({ type: 'snapshot', cursor: result.event.seq, records: [result], hasMore: true });
  assert.equal(transcript.messages().length, 1);
  assert.equal(transcript.messages()[0].toolDetail, 'hi\n');
  assert.equal(transcript.messages()[0].toolStatus, '完成');
});

test('synthetic denied approval preserves a non-success tool status through turn completion', () => {
  // The recorded approval is allowed-once; denied is a deliberate synthetic outcome boundary.
  const { transcript, apply } = harness();
  const recorded = fixture('follow_approval_with_resync.jsonl');
  const call = recorded.find(f => f.event?.type === 'tool/call');
  const asked = recorded.find(f => f.event?.type === 'approval/asked');
  const decision = structuredClone(recorded.find(f => f.event?.type === 'approval/decided'));
  decision.event.data.outcome = 'denied';
  apply(call); apply(asked);
  assert.equal(transcript.messages()[0].toolStatus, '等待授权');
  apply(decision);
  assert.equal(transcript.messages()[0].toolStatus, '未授权');
  apply(event(decision.event.seq + 1, 'turn/end', { reason: { kind: 'completed' } }));
  assert.equal(transcript.messages()[0].toolStatus, '未授权');
});

test('synthetic abandoned and foreign attempts cannot leak stale draft text', () => {
  const { transcript, apply } = harness();
  apply(stream('start', { turn: 1, step: 1 }));
  apply(stream('chunk', { chunk: { type: 'text-delta', text: 'draft' } }));
  apply(stream('chunk', { attemptId: 'retired', chunk: { type: 'text-delta', text: 'WRONG' } }));
  assert.equal(assistants(transcript)[0].text, 'draft');
  apply(stream('end', { outcome: { kind: 'abandoned' } }));
  assert.equal(assistants(transcript).length, 0);
});
