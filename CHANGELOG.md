# Changelog

## v0.2.0 - 2026-09-07

### 新增
- 适配微信 4.1.11（CFBundleVersion 269136）。`isRevokeMessage` 地址：arm64 `0x45F5968`、x86_64 `0x4C3BBD0`。
- 新增只读诊断模式 `./patch.sh --check`（默认行为），不修改任何文件即可确认版本、权限、特征码命中与注入空间。
- 新增 `restore` 命令，可从备份恢复主程序。
- 新增 `status` 命令，查看安装状态与 hook 日志尾部。

### 修复（重要）
- **修复卸载后微信无法启动**：旧版 `uninstall` 仅删除 dylib，Mach-O 中残留的 `LC_LOAD_DYLIB` 会让 dyld 加载失败。现改为完整移除该 load command 并回退 `ncmds` / `sizeofcmds`，实测「注入 → 移除」后二进制 sha256 与原始文件完全一致。
- **移除 `rm -rf /Applications/WeChat.app`**：旧版 `remove_provenance()` 会先删除再重建微信本体，在 `Contents` 为 `root:wheel` 权限时会失败并留下半删状态。现仅使用 `xattr` 处理。
- 安装前强制备份主程序与 SHA256 清单，写入 `~/.wechat-antirevoke/backups/<时间戳>/`。

### 变更
- 默认行为从「直接安装」改为「只读诊断」。
- 安装需手动输入 `yes` 确认，并显式提示封号风险。
- 写操作自动请求 sudo 提升。

## v0.1.0 - 2026-04-21

- 首次独立发布。
- 重构为全新项目结构与命名。
- 新增 `patch_wechat.py` 二进制补丁安装/卸载链路。
- 为 `CFBundleVersion 37342` 适配运行时 revoke hook。
- 实现消息保留，不再因撤回直接消失。
- 实现消息下方撤回提示。
- 修复提示需要切换会话后才显示的问题。
- 修复提示出现后聊天页不自动滚动到底部的问题。
