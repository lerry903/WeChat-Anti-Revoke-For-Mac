# WeChat Anti-Revoke For Mac

macOS 微信消息防撤回工具，当前版本为 `v4.1.11`。

仓库地址：
- https://github.com/lerry903/WeChat-Anti-Revoke-For-Mac

克隆：

```bash
git clone https://github.com/lerry903/WeChat-Anti-Revoke-For-Mac.git
```

## 最新版本（v4.1.11）

**支持微信 4.1.9 / 4.1.10 / 4.1.11**，适配微信全新 C++ 架构，通过 DYLD 运行时注入实现防撤回，一键生效。

### 原理

通过注入一个运行时 hook 动态库（`WeChatAntiRevoke.dylib`），在运行时对微信内建的 `isRevokeMessage()` 函数打 inline trampoline。

### 适用范围

| 微信版本 | CFBundleVersion | 架构 |
|---|---|---|
| 4.1.9  | 268602 | arm64 / x86_64 |
| 4.1.10 | 268824 | arm64 / x86_64 |
| 4.1.11 | 269136 | arm64 / x86_64 |

### 使用

```bash
cd WeChat-Anti-Revoke-For-Mac # 跳转到项目目录
chmod +x patch.sh          # 添加可执行权限
./patch.sh                 # 只读诊断（默认，不改动任何文件）
./patch.sh install         # 安装防撤回
./patch.sh uninstall       # 卸载
./patch.sh restore         # 从备份恢复主程序
./patch.sh status          # 查看状态与 hook 日志
./patch.sh --help          # 帮助
```

安装需要 sudo（`/Applications/WeChat.app` 属 `root:wheel`），并需手动输入 `yes` 确认。

### 依赖

macOS 系统自带工具，无需额外安装：
- clang（Xcode Command Line Tools）
- python3
- codesign
- otool

如未安装 Xcode Command Line Tools，运行：xcode-select --install

---

## v4.1.11 安全性加固

本版本重点修复了旧版的**可逆性缺陷**：

| 项目 | v4.1.10 及以前 | v4.1.11 |
|---|---|---|
| 卸载 | 只删除 dylib，Mach-O 中的 `LC_LOAD_DYLIB` 残留 → **微信无法启动** | 完整移除 load command，实测字节级可逆 |
| 备份 | 无 | 安装前自动备份主程序与 SHA256 清单 |
| 回滚 | 只能重装微信 | `./patch.sh restore` 一键回滚 |
| `rm -rf` 微信本体 | 存在（解除 provenance），中断会留半删状态 | 已移除，仅使用 `xattr` |
| 默认行为 | 直接安装 | 默认只读诊断，不写任何文件 |
| 安装确认 | 无 | 需手动输入 `yes` |

备份位于 `~/.wechat-antirevoke/backups/<时间戳>/`，包含原始主程序与校验值。

### 已知限制

- **无聊天内撤回提示**：当前方案仅静默保留原消息，不会在聊天窗口中显示"对方撤回了一条消息"的提示。拦截事件通过 macOS 通知中心提示。
- **为什么不能像旧版那样在聊天框内显示提示？**

  旧版微信 macOS（3.x）使用 Objective-C 构建，核心逻辑暴露为 ObjC 方法，可以通过 Method Swizzling 在运行时拦截撤回处理函数，保留原消息的同时调用微信内部的消息插入 API 写入一条提示。

  当前版本（4.x）的底层架构已完全不同：核心逻辑迁移到 C++ 实现（仅剩 65 个 ObjC 类，而代码段超过 90MB 均为 C++ 且符号已 strip）。撤回处理不再是独立的"删除旧消息"+"插入提示"两步操作，而是将整个消息对象替换为新的视图模型。在纯二进制补丁方式下，无法构造复杂的函数调用链来插入一条新消息到聊天记录中。

---

## 风险说明

- 微信每次升级后，地址、结构体字段、运行时行为都可能变化，补丁可能立即失效。
- 安装会**重新签名微信**，原签名作废并关闭 library validation。
- 本项目只承诺仓库内标明的支持版本，不承诺自动兼容未来版本。
- 本工具违反《微信软件许可及服务协议》，存在账号风控 / 封号风险。
- 本项目仅用于技术研究与兼容性分析，禁止用于商业用途，请自行承担使用风险。
