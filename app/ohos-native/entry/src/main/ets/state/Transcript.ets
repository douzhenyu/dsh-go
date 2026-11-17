import { Message } from '../common/Models';
import { NativeRecord, NativeSessionUpdate } from '../data/NativeDto';
import { obj, arr, str, num, parseObject } from '../data/NativeDecode';

function item(id: string, role: string, text: string): Message {
  return { id: id, role: role, text: text, thinkSecs: 0, thinkText: '', codeLang: '', code: '',
    toolName: '', toolDetail: '', toolStatus: '', time: '' };
}

// This fold owns durable seq identities. Stream drafts never become invented log records.
export class Transcript {
  private log: Map<number, NativeRecord> = new Map();
  private draftId: string = '';
  private draftText: string = '';
  private draftReasoning: string = '';
  private draftTurn: number = -1;
  private draftStep: number = -1;
  private committedSeq: number = -1;
  cursor: number = -1;
  hasMore: boolean = false;
  running: boolean = false;
  statusText: string = '';

  reset(): void {
    this.log.clear(); this.clearDraft(); this.cursor = -1; this.hasMore = false;
    this.running = false; this.statusText = '';
  }
  private clearDraft(): void {
    this.draftId = ''; this.draftText = ''; this.draftReasoning = '';
    this.draftTurn = -1; this.draftStep = -1; this.committedSeq = -1;
  }
  oldest(): number {
    const keys = Array.from(this.log.keys());
    return keys.length > 0 ? Math.min(...keys) : this.cursor + 1;
  }
  merge(records: NativeRecord[]): void {
    for (const record of records) { if (record.seq >= 0) this.log.set(record.seq, record); }
  }
  apply(update: NativeSessionUpdate): void {
    if (update.type === 'snapshot') {
      this.log.clear(); this.merge(update.records); this.cursor = update.cursor;
      this.hasMore = update.hasMore; this.clearDraft();
      this.running = false;
      for (const record of update.records) this.observe(record);
      const stream: ESObject = parseObject(update.streamJson);
      const attempt: ESObject = obj(stream.activeAttempt);
      if (str(attempt.attemptId)) {
        this.draftId = str(attempt.attemptId); this.draftTurn = num(attempt.turn, -1);
        this.draftStep = num(attempt.step, -1); this.running = true;
        { const jsonRows0: ESObject[] = arr(attempt.stream); for (let jsonIndex0 = 0; jsonIndex0 < jsonRows0.length; jsonIndex0++) { const record: ESObject = jsonRows0[jsonIndex0];
          if (record.type === 'text-chunks') this.draftText += arr(record.texts).map((v: ESObject): string => str(v)).join('');
          else if (record.type === 'reasoning-chunks') this.draftReasoning += arr(record.texts).map((v: ESObject): string => str(v)).join('');
          else if (record.type === 'chunk') this.chunk(obj(record.chunk));
        } }
      }
    } else if (update.type === 'event') {
      this.merge(update.records); this.cursor = update.cursor;
      for (const record of update.records) this.observe(record);
    } else if (update.type === 'assistant-stream') {
      const frame: ESObject = parseObject(update.streamJson);
      if (update.streamType === 'start') {
        this.clearDraft(); this.draftId = update.attemptId;
        this.draftTurn = num(frame.turn, -1); this.draftStep = num(frame.step, -1); this.running = true;
      } else if (update.streamType === 'chunk' && update.attemptId === this.draftId) {
        this.chunk(obj(frame.chunk));
      } else if (update.streamType === 'end' && update.attemptId === this.draftId) {
        const outcome: ESObject = obj(frame.outcome);
        this.committedSeq = num(outcome.seq, -1);
        if (outcome.kind === 'abandoned' || this.log.has(this.committedSeq)) this.clearDraft();
      }
    }
  }
  private chunk(chunk: ESObject): void {
    if (chunk.type === 'text-delta') this.draftText += str(chunk.text);
    else if (chunk.type === 'reasoning-delta') this.draftReasoning += str(chunk.text);
  }
  private observe(record: NativeRecord): void {
    const data: ESObject = parseObject(record.dataJson);
    if (record.type === 'turn/start') { this.running = true; this.statusText = '正在生成'; }
    if (record.type === 'turn/end') {
      this.running = false; this.statusText = ''; this.clearDraft();
    }
    if (record.type === 'tool/call') this.statusText = '正在调用 ' + str(data.name);
    if (record.type === 'assistant/message' && this.draftId &&
      ((num(data.turn, -2) === this.draftTurn && num(data.step, -2) === this.draftStep) ||
       record.seq === this.committedSeq)) this.clearDraft();
  }
  messages(): Message[] {
    const rows: Message[] = [];
    const tools: Map<string, Message> = new Map();
    const approvals: Map<string, string> = new Map();
    const ordered = Array.from(this.log.values()).sort((a: NativeRecord, b: NativeRecord): number => a.seq - b.seq);
    for (const record of ordered) {
      const data: ESObject = parseObject(record.dataJson);
      if (record.role === 'user' && record.sourceKind && record.sourceKind !== 'user') continue;
      if (record.role === 'user' || record.role === 'assistant') {
        const message = item('event-' + record.seq, record.role, record.text);
        message.seq = record.seq; message.thinkText = record.reasoning;
        const rawMessage: ESObject = record.role === 'assistant' ? obj(data.message) : data;
        { const jsonRows1: ESObject[] = arr(rawMessage.content); for (let jsonIndex1 = 0; jsonIndex1 < jsonRows1.length; jsonIndex1++) { const part: ESObject = jsonRows1[jsonIndex1];
          if (part.type === 'image') message.text += '\n[图片附件]';
          if (part.type === 'file') message.text += '\n[文件附件] ' + str(part.name);
        } }
        if (message.text || message.thinkText) rows.push(message);
      } else if (record.type === 'tool/call') {
        const callId = str(data.callId);
        const message = item('tool-' + callId, 'assistant', '');
        message.seq = record.seq; message.toolName = str(data.name);
        message.toolDetail = str(data.arguments); message.toolStatus = '运行中';
        tools.set(callId, message); rows.push(message);
      } else if (record.type === 'tool/result') {
        const rawMessage: ESObject = obj(data.message);
        const callId = str(rawMessage.toolCallId) || 'result-' + record.seq;
        let message = tools.get(callId);
        if (!message) {
          message = item('tool-' + callId, 'assistant', '');
          message.seq = record.seq; message.toolName = str(rawMessage.name) || '工具结果';
          tools.set(callId, message); rows.push(message);
        }
        if (message) {
          const text = arr(rawMessage.content).filter((v: ESObject): boolean => v.type === 'text')
            .map((v: ESObject): string => str(v.text)).join('\n');
          message.toolDetail = text || str(obj(data.error).reason) || message.toolDetail;
          message.toolStatus = rawMessage.isError === true || str(obj(data.error).name) ? '失败' : '完成';
        }
      } else if (record.type === 'turn/error' || record.type === 'session/error') {
        const message = item('notice-' + record.seq, 'assistant', str(data.message) || str(obj(data.error).message) || '主机返回错误');
        message.notice = true; message.seq = record.seq; rows.push(message);
      } else if (record.type === 'approval/asked') {
        approvals.set(str(data.id), str(data.callId));
        const tool = tools.get(str(data.callId));
        if (tool) tool.toolStatus = '等待授权';
      } else if (record.type === 'approval/decided') {
        const tool = tools.get(approvals.get(str(data.id)) || '');
        if (tool) tool.toolStatus = data.outcome === 'allowed-once' ? '运行中' : '未授权';
      } else if (record.type === 'llm/retry') {
        const message = item('notice-' + record.seq, 'assistant', '模型请求重试 ' + num(data.retry) + '/' + num(data.maxRetries));
        message.notice = true; message.seq = record.seq; rows.push(message);
      } else if (record.type === 'turn/end') {
        const reason: ESObject = obj(data.reason);
        const kind = str(reason.kind) || str(data.reason);
        for (const tool of tools.values()) {
          if (tool.toolStatus === '运行中' || tool.toolStatus === '等待授权') tool.toolStatus = kind === 'aborted' ? '已中断' : '未返回结果';
        }
        if (kind === 'aborted' || kind === 'error') {
          const failureKind = str(obj(reason.error).kind);
          const text = kind === 'aborted' ? '本轮生成已停止' : '模型请求失败' + (failureKind ? '（' + failureKind + '）' : '，请检查主机模型配置');
          const message = item('notice-' + record.seq, 'assistant', text);
          message.notice = true; message.seq = record.seq; rows.push(message);
        }
      }
    }
    if (this.draftId && (this.draftText || this.draftReasoning)) {
      const draft = item('draft-' + this.draftId, 'assistant', this.draftText);
      draft.thinkText = this.draftReasoning; draft.streaming = true; rows.push(draft);
    }
    return rows;
  }
}
