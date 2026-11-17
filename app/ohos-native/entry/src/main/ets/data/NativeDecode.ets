import { NativeWorkspace, NativeSession, NativeRecord, NativeHistory, NativeSessionUpdate, NativeHostEvent, NativeQuestion, NativeQuestionOption } from './NativeDto';

// ESObject is restricted to the untrusted JSON boundary; public DTOs are typed.
export function parseObject(text: string): ESObject {
  let value: ESObject;
  try { value = JSON.parse(text); } catch (_) { throw new Error('PROTOCOL: invalid JSON'); }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('PROTOCOL: expected object');
  }
  return value;
}
export function str(value: ESObject): string { return typeof value === 'string' ? value : ''; }
export function num(value: ESObject, fallback: number = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}
export function obj(value: ESObject): ESObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : {};
}
export function arr(value: ESObject): ESObject[] { return Array.isArray(value) ? value : []; }
export function strings(value: ESObject): string[] {
  const result: string[] = [];
  arr(value).forEach((item: ESObject) => { if (typeof item === 'string') result.push(item); });
  return result;
}
export function workspace(value: ESObject): NativeWorkspace {
  const row: ESObject = obj(value);
  const result = new NativeWorkspace();
  result.workspaceId = str(row.workspaceId); result.title = str(row.title);
  result.path = str(row.path); result.sessionIds = strings(row.sessionIds);
  return result;
}
export function session(value: ESObject): NativeSession {
  const row: ESObject = obj(value);
  const result = new NativeSession();
  result.sessionId = str(row.sessionId); result.cwd = str(row.cwd);
  result.updatedAt = num(row.updatedAt); result.running = row.running === true;
  result.blank = row.blank === true; result.agentAvailable = row.agentAvailable === true;
  result.parentSessionId = str(row.parentSessionId); result.origin = str(row.origin);
  const projections: ESObject = obj(row.projections);
  result.projectionsJson = JSON.stringify(projections);
  result.title = str(obj(projections.values).title);
  return result;
}
export function record(value: ESObject): NativeRecord {
  const row: ESObject = obj(value);
  const result = new NativeRecord();
  result.seq = num(row.seq, -1); result.time = num(row.time); result.type = str(row.type);
  const data: ESObject = obj(row.data);
  result.dataJson = JSON.stringify(data);
  if (result.type === 'user/message' || result.type === 'assistant/message') {
    const message: ESObject = result.type === 'assistant/message' ? obj(data.message) : data;
    result.role = result.type === 'assistant/message' ? 'assistant' : 'user';
    result.sourceKind = str(obj(message.source).kind);
    arr(message.content).forEach((part: ESObject) => {
      if (part.type === 'text') result.text += str(part.text);
      if (part.type === 'reasoning') result.reasoning += str(part.text);
    });
  }
  return result;
}
export function history(value: ESObject): NativeHistory {
  const row: ESObject = obj(value);
  const result = new NativeHistory();
  result.hasMore = row.hasMore === true;
  arr(row.records).forEach((item: ESObject) => { result.records.push(record(obj(item).event)); });
  return result;
}
export function sessionUpdate(sessionId: string, value: ESObject): NativeSessionUpdate {
  const row: ESObject = obj(value);
  const result = new NativeSessionUpdate();
  result.type = str(row.type); result.sessionId = sessionId;
  result.rawJson = JSON.stringify(row);
  if (result.type === 'snapshot') {
    result.cursor = num(row.cursor, -1); result.hasMore = row.hasMore === true;
    result.records = history(row).records; result.cwd = str(obj(row.header).cwd);
    result.projectionsJson = JSON.stringify(obj(row.projections));
    result.title = str(obj(obj(row.projections).values).title);
    result.streamJson = JSON.stringify(obj(row.assistantStream));
  } else if (result.type === 'event') {
    const event = record(row.event);
    result.records = [event]; result.cursor = event.seq;
  } else if (result.type === 'assistant-stream') {
    const frame: ESObject = obj(row.frame);
    result.streamJson = JSON.stringify(frame); result.streamType = str(frame.type);
    result.attemptId = str(frame.attemptId);
    const chunk: ESObject = obj(frame.chunk);
    if (chunk.type === 'text-delta') result.deltaText = str(chunk.text);
    if (chunk.type === 'reasoning-delta') result.deltaReasoning = str(chunk.text);
  } else { throw new Error('UNSUPPORTED: session follow frame'); }
  return result;
}
export function hostEvent(value: ESObject): NativeHostEvent {
  const row: ESObject = obj(value);
  const result = new NativeHostEvent();
  result.type = str(row.type); result.event = str(row.event);
  result.eventId = str(row.eventId); result.sessionId = str(row.agentId);
  result.rawJson = JSON.stringify(row); result.argsJson = JSON.stringify(arr(row.args));
  if (result.type === 'emit') {
    const args: ESObject[] = arr(row.args);
    if (args.length > 0) result.sessionId = str(args[0]);
    if (result.event === 'api-session/status' && args.length > 1) result.running = args[1] === true;
  }
  const request: ESObject = obj(row.request);
  result.toolName = str(request.toolName); result.callId = str(request.callId);
  const display: ESObject = obj(request.displayReason);
  result.reason = str(display.zh) || str(display.en) || str(request.reason);
  result.timed = obj(request.wait).timed === true;
  result.waitCallId = str(obj(request.wait).callId);
  arr(request.questions).forEach((raw: ESObject) => {
    const q = new NativeQuestion();
    q.id = str(raw.id); q.question = str(raw.question); q.detail = str(raw.detail);
    q.header = str(raw.header); q.multiSelect = raw.multiSelect === true;
    arr(raw.options).forEach((option: ESObject) => {
      const o = new NativeQuestionOption();
      o.label = str(option.label); o.description = str(option.description); q.options.push(o);
    });
    result.questions.push(q);
  });
  return result;
}
