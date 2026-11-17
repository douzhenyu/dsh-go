// Wire DTOs deliberately independent of UI/common models. Raw JSON stays in memory.
export class NativeWorkspace {
  workspaceId: string = '';
  title: string = '';
  path: string = '';
  sessionIds: string[] = [];
}

export class NativeSession {
  sessionId: string = '';
  title: string = '';
  cwd: string = '';
  updatedAt: number = 0;
  running: boolean = false;
  blank: boolean = false;
  agentAvailable: boolean = false;
  parentSessionId: string = '';
  origin: string = '';
  projectionsJson: string = '{}';
}

export class NativePart {
  type: string = '';
  text: string = '';
}

export class NativeRecord {
  seq: number = -1;
  time: number = 0;
  type: string = '';
  // Normalized only for user/message and assistant/message.
  role: string = '';
  sourceKind: string = '';
  text: string = '';
  reasoning: string = '';
  dataJson: string = '{}';
}

export class NativeHistory {
  records: NativeRecord[] = [];
  hasMore: boolean = false;
}

export class NativeSessionUpdate {
  // snapshot | event | assistant-stream. Unknown frame types fail explicitly.
  type: string = '';
  sessionId: string = '';
  cursor: number = -1;
  records: NativeRecord[] = [];
  hasMore: boolean = false;
  title: string = '';
  cwd: string = '';
  projectionsJson: string = '{}';
  // Full assistant stream frame / snapshot assistantStream JSON for folding.
  streamJson: string = '{}';
  streamType: string = '';
  attemptId: string = '';
  deltaText: string = '';
  deltaReasoning: string = '';
  rawJson: string = '{}';
}

export class NativeQuestionOption {
  label: string = '';
  description: string = '';
}

export class NativeQuestion {
  id: string = '';
  question: string = '';
  detail: string = '';
  header: string = '';
  multiSelect: boolean = false;
  options: NativeQuestionOption[] = [];
}

export class NativeAnswer {
  id: string = '';
  selected: string[] = [];
  custom: string = '';
}

export class NativeHostEvent {
  // ready | emit | waterfall | cancel
  type: string = '';
  event: string = '';
  eventId: string = '';
  sessionId: string = '';
  toolName: string = '';
  callId: string = '';
  reason: string = '';
  questions: NativeQuestion[] = [];
  timed: boolean = false;
  waitCallId: string = '';
  running: boolean = false;
  // emit args and the original value, for non-core configuration surfaces.
  argsJson: string = '[]';
  rawJson: string = '{}';
}
