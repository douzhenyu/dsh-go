// Explicit wire classes keep nested outbound literals compatible with strict ArkTS.
import { NativeAnswer } from './NativeDto';
export class WirePayload {
  args: ESObject;
  constructor(args: ESObject) { this.args = args; }
}
export class WireFrame {
  type: string;
  streamId: string;
  endpoint?: string;
  payload?: WirePayload;
  constructor(type: string, streamId: string, endpoint: string = '', args: ESObject = JSON.parse('{}')) {
    this.type = type; this.streamId = streamId;
    if (endpoint) { this.endpoint = endpoint; this.payload = new WirePayload(args); }
  }
}
export class WireItem {
  type: string = 'item';
  streamId: string;
  value: ESObject;
  constructor(streamId: string, value: ESObject) { this.streamId = streamId; this.value = value; }
}
export class WireRpc {
  type: string = 'client-request';
  rpcId: string;
  method: string;
  payload: WirePayload;
  constructor(id: string, method: string, args: ESObject) {
    this.rpcId = id; this.method = method; this.payload = new WirePayload(args);
  }
}
export class WireRequest {
  request: ESObject;
  constructor(request: ESObject) { this.request = request; }
}
export class WireAddress {
  kind: string = 'session';
  sessionId: string;
  constructor(sessionId: string) { this.sessionId = sessionId; }
}
export class WireTurnWindow {
  minMessages: number = 50;
  minTurns: number = 2;
}
export class WireFollow {
  address: WireAddress;
  assistantStream: boolean = true;
  maxMessages: number = 500;
  turnWindow: WireTurnWindow = new WireTurnWindow();
  constructor(sessionId: string) { this.address = new WireAddress(sessionId); }
}
export class WirePage {
  address: WireAddress;
  throughSeq: number;
  beforeSeq?: number;
  maxMessages: number = 500;
  constructor(sessionId: string, throughSeq: number, beforeSeq: number) {
    this.address = new WireAddress(sessionId); this.throughSeq = throughSeq;
    if (beforeSeq >= 0) this.beforeSeq = beforeSeq;
  }
}
export class WireText {
  type: string = 'text';
  text: string;
  constructor(text: string) { this.text = text; }
}
export class WirePrompt {
  requestId: string;
  sessionId: string;
  mode: string;
  content: WireText[];
  constructor(id: string, sessionId: string, mode: string, text: string) {
    this.requestId = id; this.sessionId = sessionId; this.mode = mode; this.content = [new WireText(text)];
  }
}
export class WireAnswers {
  answers: NativeAnswer[];
  constructor(answers: NativeAnswer[]) { this.answers = answers; }
}
export class WireOutcome {
  kind: string;
  value?: ESObject;
  error?: ESObject;
  constructor(kind: string, value?: ESObject, error?: ESObject) {
    this.kind = kind; this.value = value; this.error = error;
  }
}
