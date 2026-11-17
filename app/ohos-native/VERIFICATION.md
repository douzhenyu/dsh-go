# 验证记录 / Verification record

## 原生实现 / Native implementation

这套原生实现对应已安装验证的 v2.19 开发产物（应用内部版本仍为 1.0.0 / 1000000）。该编号不是 GitHub Release；此源码提交不包含安装包、签名材料、设备序列号、账号记录、诊断日志或构建缓存。

This native implementation corresponds to the device-verified v2.19 development artifact (application version 1.0.0 / 1000000). It is not a GitHub Release. This source commit excludes installable binaries, signing material, device identifiers, account records, diagnostic logs and build caches.

已验证产物的 SHA-256 / Verified artifact SHA-256:
`046aa927da1088777f52eb85e1919827529fe83fd8ad7d2747791d0100bb3c9a`.

导出源码后仅增加了无签名构建配置、构建/测试说明、完整第三方许可资源与忽略规则，并排除了未被引用的原型 MockData。生产 ArkTS 逻辑与已验证实现一致。移植最初基线是 `6459f947835ef5e60d996066331aec1ccdba011a`；发布分支在上游当前鸿蒙基线之上单独提交。

The source export adds an unsigned build profile, build/test documentation, complete third-party license resources and ignore rules, and omits an unreferenced prototype MockData module. Production ArkTS logic is unchanged from the verified implementation. The initial port baseline was `6459f947835ef5e60d996066331aec1ccdba011a`; the publication branch adds the port on top of the current upstream Harmony baseline.

## 回归与协议 / Regression and protocol checks

- Node tests: **169 passed, 0 failed, 0 skipped** in the final verified implementation.
- Native HTTP/mux contract harness: **PASS**, including 130 recorded session frames, direct authentication/diagnostics/epochs, and cookie-free carrier ready/RPC/approval/follow/cancellation/retired epochs.
- ArkTS type/compile and signed debug HAP assembly succeeded with SDK warnings.
- The exported source on upstream Harmony baseline `ed08dbdf7f86b2f801050879e5345a36e45f0c54` was independently checked again before push: **169/169 Node tests**, the **130-frame native contract harness**, and an **unsigned HAP build** all passed. The clean source export contains no signing configuration or generated artifacts.
- 测试执行生产控制器与适配器，平台/网络使用明确替身。它们不冒充真实 OAuth、主机写入接受或 ArkUI 渲染验证。
- Tests execute production controllers and adapters against explicit platform/network substitutes. They do not stand in for real OAuth, Host write acceptance or ArkUI rendering.

首次登录故障有单独红绿回归：HarmonyOS TextEncoder 对空字符串返回 undefined，初次保存的 lastHostId 为空时读取字节长度抛出 TypeError。适配器现统一返回空 Uint8Array。另覆盖 SDK 私钥编码先复制再清零、保存失败后复用当前授权重试且不重放设备注册、令牌轮换保存、退出清理和旧回调隔离。

A red/green regression covers the first-login failure: HarmonyOS TextEncoder returns undefined for an empty string, so the initial empty lastHostId caused a TypeError before storage. The adapter now returns an empty Uint8Array. Regressions also cover SDK-owned key-buffer safety, retrying a failed save without another device registration, token-rotation persistence, logout clearing and retired callbacks.

## 适用真机结果 / Applicable device results

Pura 70 Pro / HarmonyOS, API 26:

- 真实账号授权后明确显示安全保存成功，并通过 Relay + Noise IK 连接真实主机。
- 应用被强停并以新进程启动；没有点击登录或连接，主机自动恢复 ready，卡片显示“已连接”，并读取实际会话/工作区目录。
- “已连接”筛选保留 ready 主机；点击已连接卡片直接进入对话，不重新打开授权。
- 手动断开保持断开；随后选择保存的目标可使用同一登录态再次连接，不重新 OAuth、不再要求第二次点击连接。
- 离开 Remote 页面后连接仍由 Store 持有。
- 系统 AssetStore 与原生密钥的合成账号跨进程自检通过，既测试 RFC 导入身份，也测试新生成身份。合成数据已清理，临时自检入口/跟踪均已从源码和 HAP 移除。

Real authorization and secure save succeeded. Force-stop/reopen in a different process restored the real Host without another login/connect click. The connected filter, conversation navigation, explicit disconnect, another connection using the same login and page-lifetime carrier ownership were checked. Real AssetStore/native-key tests also covered synthetic accounts across processes, using both imported and freshly generated identities; synthetic data and temporary probes were removed.

## 限制 / Limits

完整手机断电重启未执行；测试覆盖真实应用强停后的跨进程恢复。OS 资产设置为 DEVICE_FIRST_UNLOCKED，整机重启后需先解锁再恢复应用。没有承诺后台常驻或开机自启。

A full phone power-cycle was not performed. Tests cover real process termination/restart. OS assets use DEVICE_FIRST_UNLOCKED; after a phone restart, unlock the device before reopening. Background residency and boot auto-launch are not promised.

显式断开会暂停自动重连。授权过期/撤销或主机身份变化仍需介入。卸载应用会清理应用私有安全凭据。设置写入是否接受以主机真实答复为准；已有一次同值默认模型写入得到 `settings/rejected`，不能将此类拒绝描述为成功写入。

Explicit disconnect pauses reconnects. Expired/revoked authorization or changed Host identity requires intervention. Uninstalling clears app-private secure credentials. Host settings acceptance remains authoritative: a previous same-value default-model write returned `settings/rejected`, and is not reported as an accepted write.
