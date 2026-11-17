// Ordered authenticated plaintext pipe. Implementations own Noise, framing and
// physical transport; consumers never receive unverified plaintext.
export interface RemoteMessageLink {
  onMessage?: (message: Uint8Array) => void;
  onClosed?: (code: string) => void;
  connect(): Promise<void>;
  send(message: Uint8Array, canSend?: () => boolean): Promise<void>;
  close(): void;
}
