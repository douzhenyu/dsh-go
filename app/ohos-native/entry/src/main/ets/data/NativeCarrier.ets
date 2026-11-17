// Transport seam shared by direct HTTP and authenticated remote tunnel adapters.
// Adapters own authentication/crypto and must never put credentials or raw network
// messages into errors. Error.message and onState.message carry stable codes only.
export interface NativeCarrier {
  onState?: (state: string, code: string) => void;
  // Establish the authenticated transport; Host $events ready is handled by NativeClient.
  connect(): Promise<void>;
  // Return JSON-encoded business value ("null" for a void result), not an RPC envelope.
  rpc(endpoint: string, argsJson: string): Promise<string>;
  // Deliver one JSON-encoded item at a time. End via Error('STREAM_ENDED');
  // streamId belongs to NativeClient and must not be replaced by the adapter.
  open(streamId: string, endpoint: string, argsJson: string,
    onItem: (valueJson: string) => void, onError: (error: Error) => void): void;
  cancel(streamId: string): void;
  // Idempotent; reject pending calls and release all owned sockets/stream handlers.
  close(): void;
}
