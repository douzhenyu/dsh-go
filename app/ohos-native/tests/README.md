# Native state contract tests

Run from the repository root with Node.js 22 or newer:

```bash
node --test app/ohos-native/tests/*.test.cjs
```

The loader uses DevEco Studio's installed SDK TypeScript by default. Override it when the SDK is installed elsewhere:

```bash
SDK_TYPESCRIPT=/absolute/path/to/typescript/lib/typescript.js node --test app/ohos-native/tests/*.test.cjs
```

These tests transpile and execute the unchanged `Transcript.ets`, `AppStore.ets`, `NativeDecode.ets`, and DTO source. Transpilation is not an ArkTS compiler/type check. They do not invoke hvigor, contact any host, or require a phone. All writes are confined to in-memory preference substitutes; credentials used in tests are synthetic.

## Protocol evidence

The recorded fixture source is `packages/dsh_client/test/fixtures/`; its README describes capture versions and redaction. Fixture instruction text is protocol data only.

- `follow_reply_ok.jsonl`: draft text appears before durable commit; commit replaces it, duplicate seq delivery stays deduplicated, hidden runtime/catalog messages stay hidden. A second test changes only delivery order to place the recorded stream-end before the recorded durable event.
- `follow_approval_with_resync.jsonl`: an actual reconnect snapshot restores compact active-attempt reasoning; subsequent recorded frames settle the draft and display the tool output. Its recorded tool result is also replayed without its earlier call to exercise a paginated history boundary.
- `follow_cancel.jsonl`: the actual object-shaped aborted reason clears the draft and displays a stopped notice.

Synthetic boundaries are explicitly labeled in test names/comments: compact text-chunks alongside reasoning-chunks, a turn/end error object with failure kind, denial instead of the capture's allowed-once decision, and foreign/abandoned stream attempts. They supplement missing capture cases rather than claiming to be recorded evidence.

## Store seams and limits

Only NativeClient and HarmonyOS platform dependencies are substituted. Deferred promises drive stale authentication, baseline refresh, follow callbacks, history pagination, and send completion without sleeps. In-memory AppStorage and preferences observe production state publications and metadata persistence; deterministic UUIDs let tests compare request identities. Timer callbacks are retained without execution, so these tests do not verify automatic refresh timer delivery.

Store assertions cover connection/session generations, stale error callbacks, preservation of a new send's busy state, same-text retry request IDs after unknown network results, fresh IDs for subsequent prompts, persisted endpoint query/fragment removal, absence of token/cookie values in preference writes, metadata host reauthentication, and preference flush failure.

Native HTTP/cookie handling and actual RPC correlation remain the responsibility of `entry/src/main/ets/data/NativeContract.test.cjs`; this suite intentionally does not duplicate that transport harness. Run it separately:

```bash
node app/ohos-native/entry/src/main/ets/data/NativeContract.test.cjs /Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js
```

## Settings coverage

`host-settings.test.cjs` executes the real namespace/schema parser and adapters against a redacted captured description plus labeled synthetic mutations. It covers secret stripping, exact revision and atomic payloads, no write replay, preset/plugin contracts, session-only Auto exclusion and optional model features.

`native-client-carrier.test.cjs` exercises public NativeClient RPC with only connection readiness and the carrier substituted. It verifies bounded lower-case/slashed business errors survive the full client boundary and arbitrary messages/URLs do not.

`native-local-settings.test.cjs` substitutes HarmonyOS preferences, notificationManager, clipboard and bundle APIs. It checks flush/rollback, non-secret diagnostics, actual API-result handling and bounded status timeout. Store tests cover live-event notification deduplication and silent snapshot replay.

`host-settings-page.test.cjs` executes the actual page controller, excluding ArkUI builders, to verify state publication and write behavior under host changes and superseded reads. It does not emulate ArkUI rendering.

## Login recovery and Host status

`remote-crypto-adapter.test.cjs` models the SDK's `TextEncoder.encodeInto('') === undefined` contract and checks that production UTF-8 returns empty bytes. This covers the actual first-login `lastHostId=''` failure, which non-empty storage fixtures missed.

`remote-session-vault.test.cjs` executes the actual AssetStore adapter with the system API substituted. It covers server isolation, chunk/head commit ordering, failures, clearing and fixed non-secret restore status. `remote-account.test.cjs` covers secret snapshot validation, rotated-token persistence, expiration/revocation and consecutive exports without mutating an SDK-owned key encoding.

`remote-connection-manager.test.cjs` executes the actual coordinator against account/vault/carrier seams. It covers automatic startup restore, coalesced finite reconnects, explicit disconnect/direct-switch cancellation, old callbacks, identity changes, logout and foreground recovery. It provides no RPC-write replay surface.

`remote-page-lifecycle.test.cjs` executes the real page controller for authorized-target continuation, sole-Host OAuth continuation, bounded directory retries and safe HTTP errors. `host-status.test.cjs` extracts the real HostTab/HostCard controllers to check a ready carrier against frozen stale endpoint metadata and connected-row navigation. Builder/rendering code is excluded, so those tests do not emulate ArkUI dependency tracking.

A green result does not validate ArkUI rendering, device networking, background notification delivery, or real Host acceptance. Those checks require the signed HAP and an authorized device/Host session. A device AssetStore test using synthetic tokens proves platform storage behavior, not successful real-account OAuth or Host connection.
