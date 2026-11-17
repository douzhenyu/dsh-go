// Shapes mirror what the real app already has: sessions that belong to a workspace
// (project) on a host, a status the drawer already filters on (running / waiting for
// approval / unread) plus failed, and hosts of the kinds HostKind knows (DSH Remote,
// SSH, local engine).

export interface Session {
  id: string;
  title: string;
  preview: string;
  time: string;
  workspace: string;
  model: string;
  workspaceId?: string;
  cwd?: string;
  // 'idle' | 'running' | 'pending' | 'failed' | 'unread'
  status: string;
}

export interface Workspace {
  id: string;
  title: string;
  path: string;
  sessionIds: string[];
}

export interface SessionGroup {
  name: string;
  path: string;
  items: Session[];
}

export interface HostInfo {
  id: string;
  name: string;
  // 'relay' (DSH Remote) | 'ssh' | 'local'
  kind: string;
  address: string;
  // 'connected' | 'offline' | 'notinstalled'
  state: string;
  route: string;
  latency: string;
}

export interface Message {
  id: string;
  role: string;
  text: string;
  thinkSecs: number;
  thinkText: string;
  codeLang: string;
  code: string;
  toolName: string;
  toolDetail: string;
  toolStatus: string;
  time: string;
  seq?: number;
  streaming?: boolean;
  notice?: boolean;
}

export function statusLabel(status: string): string {
  if (status === 'running') {
    return '运行中';
  } else if (status === 'pending') {
    return '等你确认';
  } else if (status === 'failed') {
    return '出错';
  } else if (status === 'unread') {
    return '已完成 · 未读';
  }
  return '';
}

export function hostKindLabel(kind: string): string {
  if (kind === 'direct') {
    return 'DSH 直连';
  }
  if (kind === 'remote' || kind === 'relay') {
    return 'DSH Remote';
  } else if (kind === 'ssh') {
    return 'SSH';
  }
  return '本机引擎';
}
