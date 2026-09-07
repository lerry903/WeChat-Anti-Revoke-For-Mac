# Supported Versions

| WeChat Version | CFBundleVersion | Arch | Status | isRevokeMessage VA | Notes |
|---|---|---|---|---|---|
| 4.1.9 | 268602 | arm64 / x86_64 | supported | `0x44FFE20` (arm64) | Slot fallback + trampoline |
| 4.1.10 | 268824 | arm64 / x86_64 | supported | `0x44FFE20` / `0x4B4E9A0` | Inline trampoline |
| 4.1.11 | 269136 | arm64 / x86_64 | supported | `0x45F5968` / `0x4C3BBD0` | Verified by signature scan |

## Notes

- 当前补丁通过 **5 条指令特征码扫描** 定位 `isRevokeMessage`，硬编码地址仅作为快速路径。
  - arm64 特征：`LDR W8,[X0,#0xC]; MOV W9,#0x2712; CMP W8,W9; CSET W0,EQ; RET`
  - 命中后记录实际 VA 到 `/tmp/antirevoke_debug.log`。
- 特征码未命中时，安装会失败并弹通知，不会静默打个错误的补丁。
- 微信升级后，若 `CFBundleVersion` 变化：
  1. 先运行 `./patch.sh --check` 确认特征码是否仍命中；
  2. 若命中，把日志里的实际 VA 更新到 `patch.sh` 的 `k*_FuncVA_*` 常量与 `kKnownBuilds` 即可。
- 遗留的 `Resources/patch_targets.json` 版本表仅适用于 3.x 时代链路（`install.sh` / `patch_wechat.py`），与 `patch.sh` 无关。
