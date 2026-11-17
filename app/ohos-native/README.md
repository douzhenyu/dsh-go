# dsh-Go · 原生 HarmonyOS / Native HarmonyOS

这是 dsh-Go 的独立 ArkUI/ArkTS 前端，优先通过 DSH Remote 的 Relay + Noise IK 连接主机。它不是 Flutter `app/ohos` 工程，也不在手机中打包 Android/PRoot 引擎。

This is the standalone ArkUI/ArkTS frontend for dsh-Go. It primarily connects through the existing DSH Remote Relay + Noise IK protocol. It is separate from the Flutter `app/ohos` project and does not bundle the Android/PRoot engine.

## 来源与分支 / Origin and branches

- 上游 / Upstream: https://github.com/ccch1mneyyy/dsh-Go
- 上游鸿蒙分支 / Upstream Harmony branch: `claude/harmonyos-ohos`, publication baseline `ed08dbdf7f86b2f801050879e5345a36e45f0c54`.
- 原生实现最初验证的基线 / Original verified implementation baseline: `6459f947835ef5e60d996066331aec1ccdba011a`.
- 本仓库保留上游分支历史，原生工作放在 `harmonyos-native-arkui`；这不代表上游已接受或维护本移植。
- This repository preserves the upstream Harmony history and keeps the native work on `harmonyos-native-arkui`. This does not imply upstream acceptance or maintenance of this port.

原有版权、AGPL、第三方许可及品牌/素材限制继续适用。见 [第三方来源说明](THIRD_PARTY_NOTICES.md)、根目录 [LICENSE](../../LICENSE) 和 [ASSETS.md](../../ASSETS.md)。

Existing copyright, AGPL, third-party license and branding/asset restrictions remain applicable. See the notices and repository-level license/asset policy linked above.

## 当前能力 / Current capabilities

- 真实主机目录、工作区、会话、历史、流式输出、审批和取消；Remote 授权、首次指纹确认及后续身份比对。
- 系统 AssetStoreKit 保存 Remote 授权、设备身份和已核验主机；启动恢复、有限重连、主动断开和旧连接回调隔离。普通偏好只保存服务器等非敏感元数据。
- 本机偏好、系统通知权限/测试通知、安全诊断，以及按主机能力提供的模型/权限/预设/配置/插件设置接口。写入结果以主机实际答复为准。
- HTTP 直连保留为手动登录入口，其临时授权不作为 Remote 安全存储的一部分。

- Real Host/workspace/session/history data, streaming, approvals and cancellation; Remote authorization, initial fingerprint confirmation and subsequent identity verification.
- Remote credentials, device identity and trusted pins use system AssetStoreKit. Startup recovery, finite reconnects and explicit-disconnect handling are independent of page lifetime. Ordinary preferences contain non-sensitive metadata only.
- Local preferences, system notification permission/test publication, safe diagnostics and Host-supported settings APIs. Host write acceptance is never inferred locally.
- Manual HTTP connection remains available. Its temporary launch credentials are separate from persistent Remote authorization.

不承诺后台常驻或开机自启。主机能力缺失、授权过期/撤销、身份变化和接口拒绝均应明确呈现。完整手机断电重启尚未作为本次真机测试覆盖；已验证真实应用强停后的跨进程恢复。

Background residency and boot auto-launch are not promised. Missing Host capabilities, expired/revoked authorization, changed identity and rejected writes remain explicit. The device tests cover real process termination/restart, not a full phone power-cycle.

## 构建 / Build

已验证工具链：DevEco Studio 26、HarmonyOS SDK/API 26.0.0、Hvigor CLI 6.26.8、SDK TypeScript 4.9.5；macOS arm64。工程不依赖本机的 Flutter、`.vendor` 或 Android 运行时产物。

Verified toolchain: DevEco Studio 26, HarmonyOS SDK/API 26.0.0, Hvigor CLI 6.26.8 and SDK TypeScript 4.9.5 on macOS arm64. The project does not require local Flutter, `.vendor` or Android runtime outputs.

1. 在 DevEco Studio 中打开本目录，安装匹配的 HarmonyOS SDK，并同步工程依赖。
2. 仓库里的构建配置不含签名材料，可构建 unsigned HAP。需要真机安装时，用你自己的开发者账号在 IDE 中配置本地调试签名；不要提交签名密码、证书、设备 Profile 或 IDE 写回的签名段。
3. 使用 IDE 的 Build HAP，或在配置好 DevEco/Hvigor 工具链的终端运行以下命令。`hvigorw` 来自你安装的工具链，不是本仓库内的包装脚本。

Open this directory in DevEco Studio, install the matching SDK and synchronize dependencies. The checked-in build profile is unsigned. Configure your own local debug signing only when installing on a device; do not commit credentials, certificates, provisioning profiles or IDE-generated signing sections. Use the IDE's Build HAP action or the configured toolchain CLI:

```bash
cd app/ohos-native
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物 / Output: `entry/build/default/outputs/default/entry-default-unsigned.hap`. Signed output is available only after local signing configuration. Build/cache/module directories and signing artifacts are ignored by this native project's `.gitignore`.

## 回归 / Regressions

测试依赖仓库中既有的 `packages/dsh_client/test/fixtures/`、`packages/dsh_remote/test/fixtures/noise-ik.json` 和 `packages/dsh_remote/test/fixtures/protocol-v1/`。请克隆完整仓库，不要只复制这个子目录。

The tests use existing client/Remote protocol fixtures elsewhere in this repository. Clone the full repository rather than copying this directory alone.

从仓库根目录运行 / Run from the repository root:

```bash
# If DevEco Studio is installed outside the default macOS path, set this first:
export SDK_TYPESCRIPT=/path/to/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js
node --test app/ohos-native/tests/*.test.cjs
node app/ohos-native/entry/src/main/ets/data/NativeContract.test.cjs "$SDK_TYPESCRIPT"
```

SDK 路径需按本机实际安装设置；在默认 macOS DevEco 路径下，Node 测试无需显式设置变量。Node.js 22 或更新版本。测试只替换平台/网络边界，不接触真实用户凭据。

Set the SDK path for your installation. The Node tests default to the standard macOS DevEco SDK path. Use Node.js 22 or newer. Tests substitute platform/network boundaries and use synthetic credentials.

详细范围见 [tests/README.md](tests/README.md)；真机结果与限制见 [VERIFICATION.md](VERIFICATION.md)。Node 测试不代替 ArkTS 编译或真实账号验证。

See the test coverage and verification record linked above. Node tests do not replace ArkTS compilation or real-account device verification.
