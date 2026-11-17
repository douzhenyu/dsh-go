# 原生端第三方来源 / Native third-party notices

本目录是 dsh-Go 的 ArkUI 原生实现。上游项目、许可证与素材限制继续适用，见仓库根目录的 [LICENSE](../../LICENSE)、[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) 和 [ASSETS.md](../../ASSETS.md)。本目录不改变上游品牌和素材的授权范围。

This directory contains the native ArkUI implementation of dsh-Go. The repository's license, third-party notices and asset restrictions continue to apply. This port does not grant additional rights to upstream branding or artwork.

## ds-harness-remote — MIT

- 上游 / Upstream: https://github.com/liguobao/ds-harness-remote
- Copyright (c) 2026 DSH Remote contributors
- Dart 移植基线 / Dart port baseline: repository commit `6459f947835ef5e60d996066331aec1ccdba011a`, `packages/dsh_remote/`.
- 原始第三方版本与来源映射 / Original third-party version and source map: the repository-level ds-harness-remote notice (`7e387df`, with later protocol references listed there).
- ArkTS 对应文件 / ArkTS adaptation: `entry/src/main/ets/remote/`, including `RemoteNoise.ets` (Noise revision 34 state machine) and `RemoteTunnel.ets` (logical mux carrier), plus the protocol/account/transport adapters. These are adaptations for HarmonyOS system crypto, HTTP and WebSocket APIs; WebRTC is not included in this native transport.
- 完整 MIT 文本随原生资源附带 / Full MIT text included with the native resource inputs: [ds-harness-remote-MIT.txt](entry/src/main/resources/rawfile/licenses/ds-harness-remote-MIT.txt). It is copied verbatim from `packages/dsh_remote/LICENSE-ds-harness-remote`.

公开的 RFC 7748 测试向量和合成凭据仅用于密码学自检和回归，不是用户凭据。Node.js/OpenSSL 仅用于主机侧测试，不作为本原生应用的运行时打包。

Public RFC 7748 vectors and synthetic credentials are used for crypto self-checks and regressions. They are not user credentials. Node.js/OpenSSL are host-side test dependencies and are not bundled as the native application's runtime.
