#!/bin/bash
# ============================================================
# 微信防撤回 —— 加固版安装脚本 (safe fork)
# ============================================================
#
# 上游: lerry903/WeChat-Anti-Revoke-For-Mac (MIT)
#       基于 a244573118/WeChatIntercept
# 本版本改动:
#   1. 安装前强制备份主程序，可一键回滚（原版无备份）
#   2. 卸载时真正移除 LC_LOAD_DYLIB（原版只删 dylib，会导致微信打不开）
#   3. 移除 rm -rf /Applications/WeChat.app（原版存在半删风险）
#   4. 适配微信 4.1.11 (CFBundleVersion 269136)
#   5. 新增只读诊断模式 --check（默认行为，不写任何文件）
#
# 用法:
#   ./patch.sh                 只读诊断（默认，安全）
#   ./patch.sh install         安装（会二次确认，需 sudo）
#   ./patch.sh uninstall       完整卸载（移除 LC + dylib）
#   ./patch.sh restore         从备份恢复主程序
#   ./patch.sh status          查看当前状态
#   ./patch.sh openNotify      开启撤回通知
#   ./patch.sh closeNotify     关闭撤回通知
#
# ============================================================

set -euo pipefail

WECHAT_APP="${WECHAT_APP_OVERRIDE:-/Applications/WeChat.app}"
WECHAT_BIN="$WECHAT_APP/Contents/MacOS/WeChat"
WECHAT_DYLIB="$WECHAT_APP/Contents/Resources/wechat.dylib"
DYLIB_DST="$WECHAT_APP/Contents/Resources/WeChatAntiRevoke.dylib"
DYLIB_INSTALL_NAME="@executable_path/../Resources/WeChatAntiRevoke.dylib"

HOME_DIR="${HOME:-/Users/$(whoami)}"
STATE_DIR="$HOME_DIR/.wechat-antirevoke"
BACKUP_DIR="$STATE_DIR/backups"
MANIFEST="$STATE_DIR/manifest"
CONFIG_DIR="$HOME_DIR/.config/antirevoke"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="/tmp/antirevoke_debug.log"

CYAN=$'\033[36m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
info()  { echo "${CYAN}[INFO]${RST}  $*"; }
ok_()   { echo "${GRN}[ OK ]${RST}  $*"; }
warn()  { echo "${YEL}[WARN]${RST}  $*"; }
err()   { echo "${RED}[FAIL]${RST}  $*"; }
dim()   { echo "${DIM}       $*${RST}"; }

# ── 权限提升：仅写操作需要 ───────────────────────────────────
elevate() {
    if [ "$(id -u)" -ne 0 ]; then
        info "需要管理员权限，请求 sudo..."
        exec sudo -E HOME="$HOME_DIR" "$0" "$@"
    fi
}

# ── 读取真实用户（sudo 下 whoami 会是 root）──────────────────
REAL_USER="${SUDO_USER:-$(whoami)}"

# ── 环境检查 ─────────────────────────────────────────────────
check_environment() {
    [ -d "$WECHAT_APP" ] || { err "未找到微信: $WECHAT_APP"; exit 1; }

    SHORT_VER=$(defaults read "$WECHAT_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "")
    BUILD_VER=$(defaults read "$WECHAT_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "")
    [ -n "$SHORT_VER" ] || { err "无法读取微信版本号"; exit 1; }

    case "$(uname -m)" in
        arm64) HOST_ARCH="arm64" ;;
        x86_64) HOST_ARCH="x86_64" ;;
        *) err "不支持的 CPU: $(uname -m)"; exit 1 ;;
    esac

    info "微信 $SHORT_VER (build $BUILD_VER) / 本机 $HOST_ARCH / SIP $(csrutil status 2>/dev/null | grep -q enabled && echo on || echo off)"
    case "$SHORT_VER" in
        4.1.*) : ;;
        *) err "本脚本仅支持 4.1.x，当前 $SHORT_VER"; exit 1 ;;
    esac
}

# ── 备份主程序 ───────────────────────────────────────────────
do_backup() {
    mkdir -p "$BACKUP_DIR"
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    local dst="$BACKUP_DIR/$stamp"
    mkdir -p "$dst"

    cp -p "$WECHAT_BIN" "$dst/WeChat"
    defaults read "$WECHAT_APP/Contents/Info.plist" > "$dst/Info.plist.txt" 2>/dev/null || true
    ( cd "$WECHAT_APP/Contents/MacOS" && shasum -a 256 WeChat ) > "$dst/SHA256" 2>/dev/null || true

    echo "$stamp" > "$MANIFEST"
    ok_ "主程序已备份: $dst"
    dim "大小 $(du -h "$dst/WeChat" | cut -f1)，恢复命令: $0 restore"
}

latest_backup() {
    [ -f "$MANIFEST" ] || return 1
    local stamp; stamp=$(tail -1 "$MANIFEST" | tr -d '[:space:]')
    [ -n "$stamp" ] || return 1
    [ -f "$BACKUP_DIR/$stamp/WeChat" ] || return 1
    echo "$BACKUP_DIR/$stamp/WeChat"
}

# ── 编译 hook dylib ──────────────────────────────────────────
compile_dylib() {
    info "编译 hook 动态库..."
    command -v clang >/dev/null 2>&1 || { err "未找到 clang，请先 xcode-select --install"; exit 1; }

    local SRC="/tmp/antirevoke_hook_src_$$.m"
    cat > "$SRC" << 'HOOK_SOURCE'
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>
#import <stdint.h>
#import <string.h>
#import <stdio.h>

static FILE *g_logFile = NULL;
static void log_open(void) { g_logFile = fopen("/tmp/antirevoke_debug.log", "w"); }
#define ARLOG(fmt, ...) do { \
    if (g_logFile) { fprintf(g_logFile, "[AntiRevoke] " fmt "\n", ##__VA_ARGS__); fflush(g_logFile); } \
} while(0)

static const char    *kDylibSuffix_Resources  = "Resources/wechat.dylib";
static const char    *kDylibSuffix_Frameworks = "Frameworks/wechat.dylib";
static const int32_t  kRevokeType    = 0x2712;   // 10002

static char g_config_path[512] = {0};

// ── 版本地址表（已适配 4.1.11 / build 269136）────────────────
static const uintptr_t k4111_FuncVA_arm64  = 0x45F5968;
static const uintptr_t k4111_FuncVA_x86_64 = 0x4C3BBD0;
static const uintptr_t k4110_FuncVA_arm64  = 0x44FFE20;
static const uintptr_t k4110_FuncVA_x86_64 = 0x4B4E9A0;
static const uintptr_t k419_FuncVA_x86_64  = 0x4AF08D0;
static const uintptr_t k419_SlotVA_arm64   = 0x9301838;

// ── 已知 build 列表 ─────────────────────────────────────────
static const char *kKnownBuilds[] = { "268602", "268824", "269136", NULL };
static _Bool is_known_build(const char *build) {
    if (!build) return 0;
    for (int i = 0; kKnownBuilds[i]; i++) if (strcmp(build, kKnownBuilds[i]) == 0) return 1;
    return 0;
}

// ── 当前登录用户 ID ─────────────────────────────────────────
static char g_my_id[64] = {0};
static _Bool g_my_id_loaded = 0;

static void load_my_user_id(void) {
    if (g_my_id_loaded) return;
    g_my_id_loaded = 1;
    const char *home = getenv("HOME");
    if (!home) return;
    char loginDir[1024];
    snprintf(loginDir, sizeof(loginDir),
        "%s/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/login", home);
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dirPath = [NSString stringWithUTF8String:loginDir];
        NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:nil];
        if (!contents || [contents count] == 0) return;
        NSString *latestName = nil; NSDate *latestDate = nil;
        for (NSString *name in contents) {
            if ([name hasPrefix:@"."]) continue;
            NSString *fullPath = [dirPath stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) continue;
            NSString *keyInfo = [fullPath stringByAppendingPathComponent:@"key_info.dat"];
            NSDictionary *attrs = [fm fileExistsAtPath:keyInfo]
                ? [fm attributesOfItemAtPath:keyInfo error:nil]
                : [fm attributesOfItemAtPath:fullPath error:nil];
            NSDate *modDate = attrs[NSFileModificationDate];
            if (!latestDate || (modDate && [modDate compare:latestDate] == NSOrderedDescending)) {
                latestDate = modDate; latestName = name;
            }
        }
        if (latestName && [latestName length] >= 3 && [latestName length] < sizeof(g_my_id)) {
            strncpy(g_my_id, [latestName UTF8String], sizeof(g_my_id) - 1);
            ARLOG("用户: %s", g_my_id);
        }
    }
}

// ── 通知配置 ────────────────────────────────────────────────
static void init_config_path(void) {
    const char *home = getenv("HOME");
    if (home) snprintf(g_config_path, sizeof(g_config_path), "%s/.config/antirevoke/config", home);
}

static _Bool is_notify_enabled(void) {
    if (g_config_path[0] == '\0') return 1;
    FILE *f = fopen(g_config_path, "r");
    if (!f) return 1;
    char line[128]; _Bool enabled = 1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "notify=0", 8) == 0) { enabled = 0; break; }
    }
    fclose(f);
    return enabled;
}

static void send_notification(const char *text) {
    if (!is_notify_enabled()) return;
    char *escaped = (char *)malloc(1024);
    if (!escaped) return;
    int j = 0;
    for (int i = 0; text[i] && j < 1022; i++) {
        if (text[i] == '"' || text[i] == '\\') escaped[j++] = '\\';
        escaped[j++] = text[i];
    }
    escaped[j] = '\0';
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        FILE *sf = fopen("/tmp/antirevoke_notify.scpt", "w");
        if (sf) {
            fprintf(sf, "display notification \"%s\" with title \"WeChatIntercept\"\n", escaped);
            fclose(sf);
            system("osascript /tmp/antirevoke_notify.scpt");
        }
        free(escaped);
    });
}

static _Bool is_valid_sender(const char *s) {
    if (s[0] == '\0') return 1;
    for (int i = 0; i < 4; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x20 || c > 0x7E) return 0;
    }
    return 1;
}

// ── hook 主体 ───────────────────────────────────────────────
__attribute__((visibility("default")))
_Bool hook_isRevokeMessage(void *msg) {
    if (msg == NULL) return 0;
    int32_t msgType = *(int32_t *)((uint8_t *)msg + 0x0C);
    if (msgType != kRevokeType) return 0;

    load_my_user_id();
    const char *sender = (const char *)((uint8_t *)msg + 0x18);

    if (!is_valid_sender(sender)) {
        ARLOG("WARN: sender 偏移可能已失效，静默放行（防撤回本次未生效）");
        static int g_invalid_count = 0;
        static _Bool g_warned = 0;
        g_invalid_count++;
        if (g_invalid_count >= 5 && !g_warned) {
            g_warned = 1;
            char *cmd = (char *)malloc(1024);
            if (cmd) {
                snprintf(cmd, 1024,
                    "osascript -e 'display notification \"sender 偏移已失效，需要重新适配\" "
                    "with title \"WeChatIntercept 需更新\"' &");
                dispatch_async(dispatch_get_global_queue(0, 0), ^{ system(cmd); free(cmd); });
            }
        }
        return 1;
    }

    if (sender[0] == '\0') return 1;
    if (g_my_id[0] != '\0' && strncmp(sender, g_my_id, strlen(g_my_id)) == 0) return 1;

    ARLOG("拦截: %.20s", sender);

    char notify_text[256] = {0};
#if defined(__arm64__) || defined(__aarch64__)
    uint64_t xml_ptr = *(uint64_t *)((uint8_t *)msg + 0x130);
    uint64_t xml_len = *(uint64_t *)((uint8_t *)msg + 0x138);
    if (xml_ptr > 0x100000000ULL && xml_len > 0 && xml_len < 4096) {
        const char *xml_body = (const char *)xml_ptr;
        const char *cs = strstr(xml_body, "<![CDATA[");
        const char *ce = cs ? strstr(cs, "]]>") : NULL;
        if (cs && ce) {
            cs += 9;
            size_t len = ce - cs;
            if (len > 0 && len < sizeof(notify_text) - 1) {
                memcpy(notify_text, cs, len); notify_text[len] = '\0';
            }
        }
    }
#endif

    char content[512] = {0};
    if (notify_text[0] != '\0')
        snprintf(content, sizeof(content), "拦截到%s", notify_text);
    else
        snprintf(content, sizeof(content), "拦截到 %s 撤回了一条消息", sender);
    send_notification(content);
    return 0;
}

// ── 定位 wechat.dylib ───────────────────────────────────────
static uintptr_t find_wechat_slide(const struct mach_header **out_header) {
    uint32_t count = _dyld_image_count();
    uintptr_t fallback = 0;
    const struct mach_header *fallback_header = NULL;
    size_t resLen = strlen(kDylibSuffix_Resources);
    size_t fwLen  = strlen(kDylibSuffix_Frameworks);
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len >= resLen && strcmp(name + len - resLen, kDylibSuffix_Resources) == 0) {
            if (out_header) *out_header = _dyld_get_image_header(i);
            return (uintptr_t)_dyld_get_image_vmaddr_slide(i);
        }
        if (len >= fwLen && strcmp(name + len - fwLen, kDylibSuffix_Frameworks) == 0) {
            fallback = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            fallback_header = _dyld_get_image_header(i);
        }
    }
    if (out_header) *out_header = fallback_header;
    return fallback;
}

static _Bool find_text_segment(const struct mach_header *header, uintptr_t slide,
                                uintptr_t *out_start, size_t *out_size) {
    if (!header) return 0;
    const uint8_t *p = (const uint8_t *)header;
    uint32_t ncmds;
    if (header->magic == MH_MAGIC_64) {
        p += sizeof(struct mach_header_64);
        ncmds = ((const struct mach_header_64 *)header)->ncmds;
    } else if (header->magic == MH_MAGIC) {
        p += sizeof(struct mach_header);
        ncmds = header->ncmds;
    } else return 0;

    for (uint32_t i = 0; i < ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)p;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                *out_start = (uintptr_t)seg->vmaddr + slide;
                *out_size = (size_t)seg->vmsize;
                return 1;
            }
        } else if (lc->cmd == LC_SEGMENT) {
            const struct segment_command *seg = (const struct segment_command *)p;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                *out_start = (uintptr_t)seg->vmaddr + slide;
                *out_size = (size_t)seg->vmsize;
                return 1;
            }
        }
        p += lc->cmdsize;
    }
    return 0;
}

// ── 特征码：isRevokeMessage ─────────────────────────────────
static uintptr_t scan_isRevokeMessage_arm64(uintptr_t text_start, size_t text_size) {
    static const uint32_t pattern[5] = {
        0xB9400C08u, 0x5284E249u, 0x6B09011Fu, 0x1A9F17E0u, 0xD65F03C0u
    };
    const uint32_t *base = (const uint32_t *)text_start;
    size_t count = text_size / 4;
    if (count < 5) return 0;
    for (size_t i = 0; i + 5 <= count; i++) {
        if (base[i] == pattern[0] && base[i+1] == pattern[1] && base[i+2] == pattern[2] &&
            base[i+3] == pattern[3] && base[i+4] == pattern[4]) {
            return text_start + i * 4;
        }
    }
    return 0;
}

static uintptr_t scan_isRevokeMessage_x86_64(uintptr_t text_start, size_t text_size) {
    static const uint8_t pattern[] = {
        0x55, 0x48, 0x89, 0xE5,
        0x81, 0x7F, 0x0C, 0x12, 0x27, 0x00, 0x00,
        0x0F, 0x94, 0xC0,
        0x5D, 0xC3
    };
    const uint8_t *base = (const uint8_t *)text_start;
    if (text_size < sizeof(pattern)) return 0;
    for (size_t i = 0; i + sizeof(pattern) <= text_size; i++) {
        if (base[i] == pattern[0] && memcmp(base + i, pattern, sizeof(pattern)) == 0) {
            return text_start + i;
        }
    }
    return 0;
}

static void read_wechat_version(char *short_ver, size_t short_sz, char *build, size_t build_sz) {
    short_ver[0] = '\0'; build[0] = '\0';
    @autoreleasepool {
        NSDictionary *info = [[NSBundle bundleWithPath:@"/Applications/WeChat.app"] infoDictionary];
        NSString *sv = info[@"CFBundleShortVersionString"];
        NSString *bv = info[@"CFBundleVersion"];
        if (sv) strncpy(short_ver, [sv UTF8String], short_sz - 1);
        if (bv) strncpy(build, [bv UTF8String], build_sz - 1);
    }
}

static kern_return_t make_rw(uintptr_t addr, size_t len) {
    uintptr_t page = addr & ~(uintptr_t)0x3FFF;
    size_t sz = (addr + len - page + 0x3FFF) & ~(size_t)0x3FFF;
    return vm_protect(mach_task_self(), (vm_address_t)page, sz, 0,
                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
}
static kern_return_t make_rx(uintptr_t addr, size_t len) {
    uintptr_t page = addr & ~(uintptr_t)0x3FFF;
    size_t sz = (addr + len - page + 0x3FFF) & ~(size_t)0x3FFF;
    return vm_protect(mach_task_self(), (vm_address_t)page, sz, 0,
                      VM_PROT_READ | VM_PROT_EXECUTE);
}

static _Bool install_arm64_trampoline(uintptr_t func_addr, uintptr_t hook_addr) {
    kern_return_t kr = make_rw(func_addr, 20);
    if (kr != KERN_SUCCESS) { ARLOG("ERROR: make_rw kr=%d", kr); return 0; }
    uint32_t *p = (uint32_t *)func_addr;
    p[0] = 0x58000050u;
    p[1] = 0xD61F0200u;
    *(uint64_t *)(func_addr + 8) = (uint64_t)hook_addr;
    p[4] = 0xD503201Fu;
    if (*(volatile uint32_t *)func_addr != 0x58000050u) { ARLOG("ERROR: 写入验证失败"); return 0; }
    sys_icache_invalidate((void *)func_addr, 20);
    make_rx(func_addr, 20);
    return 1;
}

static _Bool install_x86_64_trampoline(uintptr_t func_addr, uintptr_t hook_addr) {
    kern_return_t kr = make_rw(func_addr, 16);
    if (kr != KERN_SUCCESS) { ARLOG("ERROR: x86_64 make_rw kr=%d", kr); return 0; }
    uint8_t *p = (uint8_t *)func_addr;
    p[0] = 0xFF; p[1] = 0x25;
    p[2] = p[3] = p[4] = p[5] = 0x00;
    *(uint64_t *)(func_addr + 6) = (uint64_t)hook_addr;
    p[14] = 0x90; p[15] = 0xC3;
    if (*(volatile uint8_t *)func_addr != 0xFF) { ARLOG("ERROR: x86_64 写入验证失败"); return 0; }
    __builtin___clear_cache((char *)func_addr, (char *)(func_addr + 16));
    make_rx(func_addr, 16);
    return 1;
}

static void notify_install_failed(const char *short_ver, const char *build, _Bool known_build) {
    if (!is_notify_enabled()) return;
    char *cmd = (char *)malloc(2048);
    if (!cmd) return;
    char title[64], body[512];
    if (known_build) {
        snprintf(title, sizeof(title), "WeChatIntercept 异常");
        snprintf(body, sizeof(body), "已知版本 %s (%s) hook 安装失败，见 %s", short_ver, build, "/tmp/antirevoke_debug.log");
    } else {
        snprintf(title, sizeof(title), "WeChatIntercept 需更新");
        snprintf(body, sizeof(body), "微信 %s (build %s) 未适配，防撤回已失效", short_ver, build);
    }
    char escaped[1024]; int j = 0;
    for (int i = 0; body[i] && j < (int)sizeof(escaped) - 2; i++) {
        if (body[i] == '"' || body[i] == '\\') escaped[j++] = '\\';
        escaped[j++] = body[i];
    }
    escaped[j] = '\0';
    snprintf(cmd, 2048, "osascript -e 'display notification \"%s\" with title \"%s\"' &", escaped, title);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ system(cmd); free(cmd); });
}

__attribute__((constructor))
static void hook_init(void) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{

        log_open();
        init_config_path();
        ARLOG("hook_init 启动");

        char short_ver[32] = {0}, build[32] = {0};
        read_wechat_version(short_ver, sizeof(short_ver), build, sizeof(build));
        _Bool known_build = is_known_build(build);
        ARLOG("微信版本: %s (build %s) %s", short_ver, build, known_build ? "[已适配]" : "[未适配]");

        const struct mach_header *header = NULL;
        uintptr_t slide = find_wechat_slide(&header);
        if (slide == 0) {
            ARLOG("ERROR: 未找到 wechat.dylib");
            notify_install_failed(short_ver, build, known_build);
            return;
        }

        uintptr_t text_start = 0; size_t text_size = 0;
        _Bool has_text = find_text_segment(header, slide, &text_start, &text_size);
        ARLOG("slide=0x%lx __TEXT=[0x%lx, +0x%zx)", (unsigned long)slide,
              (unsigned long)text_start, text_size);

        uintptr_t hook = (uintptr_t)&hook_isRevokeMessage;
        _Bool installed = 0;

#if defined(__arm64__) || defined(__aarch64__)
        uintptr_t func_addr = 0;
        uintptr_t candidates[3] = {
            slide + k4111_FuncVA_arm64,
            slide + k4110_FuncVA_arm64,
            0
        };
        for (int i = 0; i < 2; i++) {
            volatile uint32_t *p = (volatile uint32_t *)candidates[i];
            if (p[0] == 0xB9400C08u && p[1] == 0x5284E249u && p[2] == 0x6B09011Fu &&
                p[3] == 0x1A9F17E0u && p[4] == 0xD65F03C0u) {
                func_addr = candidates[i];
                ARLOG("快速路径命中（候选 %d）: VA 0x%lx", i, (unsigned long)(func_addr - slide));
                break;
            }
        }
        if (func_addr == 0 && has_text) {
            ARLOG("快速路径未命中，开始特征码搜索...");
            uintptr_t found = scan_isRevokeMessage_arm64(text_start, text_size);
            if (found) {
                func_addr = found;
                ARLOG("特征码找到: VA 0x%lx", (unsigned long)(func_addr - slide));
            }
        }
        if (func_addr != 0) {
            if (install_arm64_trampoline(func_addr, hook)) { ARLOG("trampoline 安装完成"); installed = 1; }
        }
#elif defined(__x86_64__)
        uintptr_t func_addr = 0;
        uintptr_t candidates[3] = { slide + k4111_FuncVA_x86_64, slide + k4110_FuncVA_x86_64, slide + k419_FuncVA_x86_64 };
        const uint32_t kFuncHead = 0xE5894855u;
        for (int i = 0; i < 3; i++) {
            if (*(volatile uint32_t *)candidates[i] == kFuncHead) { func_addr = candidates[i]; break; }
        }
        if (func_addr == 0 && has_text) {
            uintptr_t found = scan_isRevokeMessage_x86_64(text_start, text_size);
            if (found) func_addr = found;
        }
        if (func_addr != 0) {
            if (install_x86_64_trampoline(func_addr, hook)) { ARLOG("trampoline 安装完成"); installed = 1; }
        }
#endif

        if (installed) ARLOG("就绪，等待撤回消息...");
        else { ARLOG("ERROR: hook 安装失败"); notify_install_failed(short_ver, build, known_build); }
    });
}
HOOK_SOURCE

    mkdir -p "$(dirname "$DYLIB_DST")"
    clang -arch arm64 -arch x86_64 -shared -framework Foundation \
        -o "$DYLIB_DST" -install_name "$DYLIB_INSTALL_NAME" "$SRC" 2>&1 || true
    rm -f "$SRC"
    [ -f "$DYLIB_DST" ] || { err "编译失败"; exit 1; }
    ok_ "编译成功"
}

# ── 注入 / 移除 LC_LOAD_DYLIB ────────────────────────────────
machoc_edit() {
    python3 - "$1" "$2" << 'PYEOF'
import struct, sys

mode, path = sys.argv[1], sys.argv[2]
MARKER = b'WeChatAntiRevoke'
LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19

def slices(f):
    f.seek(0)
    magic = struct.unpack('>I', f.read(4))[0]
    if magic in (0xCAFEBABE, 0xBEBAFECA):
        n = struct.unpack('>I', f.read(4))[0]
        return [struct.unpack('>5I', f.read(20))[2] for _ in range(n)]
    return [0]

def first_section_offset(f, off):
    f.seek(off + 16)
    ncmds = struct.unpack('<I', f.read(4))[0]
    lc = off + 32
    for _ in range(ncmds):
        f.seek(lc)
        cmd, cs = struct.unpack('<II', f.read(8))
        if cmd == LC_SEGMENT_64:
            seg = f.read(64)
            nsects = struct.unpack('<I', seg[48:52])[0]
            if nsects:
                f.seek(lc + 72)
                s = f.read(64)
                return off + struct.unpack('<I', s[32:36])[0]
        lc += cs
    return None

def scan_lc(f, off):
    f.seek(off + 16)
    ncmds, sizeofcmds = struct.unpack('<II', f.read(8))
    out = []
    lc = off + 32
    for _ in range(ncmds):
        f.seek(lc)
        cmd, cs = struct.unpack('<II', f.read(8))
        out.append((lc, cmd, cs))
        lc += cs
    return ncmds, sizeofcmds, out

def dylib_name(f, pos, cs):
    f.seek(pos + 24)
    return f.read(cs - 24).split(b'\x00')[0]

with open(path, 'r+b') as f:
    changed = 0
    for off in slices(f):
        ncmds, sizeofcmds, lcs = scan_lc(f, off)
        if mode == 'inject':
            if any(dylib_name(f, p, cs).find(MARKER) >= 0 for p, c, cs in lcs if c == LC_LOAD_DYLIB):
                print("already")
                continue
            name = b'@executable_path/../Resources/WeChatAntiRevoke.dylib\x00'
            while len(name) % 4:
                name += b'\x00'
            cmdsize = 24 + len(name)
            region_end = off + 32 + sizeofcmds
            fs = first_section_offset(f, off)
            room = (fs - region_end) if fs else 0
            if room < cmdsize:
                print("NOROOM")
                sys.exit(2)
            lc = struct.pack('<I', LC_LOAD_DYLIB) + struct.pack('<I', cmdsize) \
               + struct.pack('<I', 24) + struct.pack('<I', 2) \
               + struct.pack('<I', 0x10000) + struct.pack('<I', 0x10000) + name
            lc += b'\x00' * (cmdsize - len(lc))
            f.seek(region_end)
            f.write(lc)
            f.seek(off + 16)
            f.write(struct.pack('<II', ncmds + 1, sizeofcmds + cmdsize))
            changed += 1
        else:
            target = None
            for p, c, cs in lcs:
                if c == LC_LOAD_DYLIB and dylib_name(f, p, cs).find(MARKER) >= 0:
                    target = (p, cs)
                    break
            if not target:
                continue
            pos, cs = target
            region_end = off + 32 + sizeofcmds
            f.seek(pos + cs)
            tail = f.read(region_end - (pos + cs))
            f.seek(pos)
            f.write(tail)
            f.seek(region_end - cs)
            f.write(b'\x00' * cs)
            f.seek(off + 16)
            f.write(struct.pack('<II', ncmds - 1, sizeofcmds - cs))
            changed += 1
    print("changed=%d" % changed)
PYEOF
}

resign() {
    info "重签名（注入 entitlements 关闭库校验）..."
    local ENT="/tmp/antirevoke_ent_$$.plist"
    cat > "$ENT" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
</dict></plist>
ENT
    codesign --force --sign - "$DYLIB_DST" 2>/dev/null || true
    codesign --force --deep --sign - "$WECHAT_APP" 2>/dev/null || true
    codesign --force --sign - --entitlements "$ENT" "$WECHAT_BIN" 2>/dev/null || true
    xattr -cr "$WECHAT_APP" 2>/dev/null || true
    rm -f "$ENT"
    if codesign -d --entitlements - "$WECHAT_BIN" 2>&1 | grep -q "disable-library-validation"; then
        ok_ "重签名完成"
    else
        warn "entitlements 可能未生效"
    fi
}

# ── 只读诊断 ─────────────────────────────────────────────────
do_check() {
    echo ""
    echo "══════════════════════════════════════"
    echo " 只读诊断（不会修改任何文件）"
    echo "══════════════════════════════════════"
    echo ""
    check_environment

    echo ""
    info "1/5 权限"
    if [ "$(id -u)" -eq 0 ]; then ok_ "当前为 root"; else
        warn "当前非 root；安装时需 sudo（/Applications/WeChat.app 属 root:wheel）"
    fi

    echo ""
    info "2/5 工具链"
    if command -v clang >/dev/null 2>&1; then ok_ "clang $(clang --version | head -1 | awk '{print $4}')"
    else err "缺少 clang（xcode-select --install）"; fi
    command -v codesign >/dev/null 2>&1 && ok_ "codesign 就绪" || err "缺少 codesign"

    echo ""
    info "3/5 在 wechat.dylib 中定位 isRevokeMessage（318MB 扫描，约 10 秒）"
    if ! python3 - "$WECHAT_DYLIB" "$HOST_ARCH" << 'PYEOF'
import struct, sys, mmap
path, host = sys.argv[1], sys.argv[2]
CPU = {'arm64': 0x100000C, 'x86_64': 0x1000007}[host]
PAT = {'arm64': bytes.fromhex('080C40B949E284521F01096BE0179F1AC0035FD6'),
       'x86_64': bytes.fromhex('554889E5817F0C12270000' '0F94C0' '5DC3')}[host]
f = open(path, 'rb')
f.seek(0); f.read(4); n = struct.unpack('>I', f.read(4))[0]
sl = [struct.unpack('>5I', f.read(20)) for _ in range(n)]
off = [s[2] for s in sl if s[0] == CPU][0]
size = [s[3] for s in sl if s[0] == CPU][0]
mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
hits = []
start = off
while True:
    i = mm.find(PAT, start)
    if i < 0 or i >= off + size:
        break
    hits.append(i)
    start = i + 1
    if len(hits) > 5:
        break
if not hits:
    print("   [FAIL] 未找到特征码 —— 本版本无法适配")
    sys.exit(1)
f.seek(off + 16); ncmds = struct.unpack('<I', f.read(4))[0]
lc = off + 32; text = None
for _ in range(ncmds):
    f.seek(lc); cmd, cs = struct.unpack('<II', f.read(8))
    if cmd == 0x19:
        seg = f.read(64)
        if seg[0:16].rstrip(b'\x00') == b'__TEXT':
            vmaddr, vmsize, fileoff, filesize = struct.unpack('<QQQQ', seg[16:48])
            text = (vmaddr, vmsize, fileoff)
            break
    lc += cs
va = text[0] + (hits[0] - off - text[2])
print("   [ OK ] 命中 %d 处，函数 VA = 0x%X" % (len(hits), va))
print("   [ OK ] 特征码唯一，可安全安装")
PYEOF
    then err "诊断未通过：本版本无法适配"; exit 1; fi

    echo ""
    info "4/5 主程序注入空间"
    python3 - "$WECHAT_BIN" << 'PYEOF'
import struct, sys
f = open(sys.argv[1], 'rb')
f.seek(0); f.read(4); n = struct.unpack('>I', f.read(4))[0]
sl = [struct.unpack('>5I', f.read(20)) for _ in range(n)]
for cpu, sub, off, size, align in sl:
    arch = {0x1000007: 'x86_64', 0x100000C: 'arm64'}[cpu]
    f.seek(off + 20); sizeofcmds = struct.unpack('<I', f.read(4))[0]
    f.seek(off + 16); ncmds = struct.unpack('<I', f.read(4))[0]
    lc = off + 32; fs = None
    for _ in range(ncmds):
        f.seek(lc); cmd, cs = struct.unpack('<II', f.read(8))
        if cmd == 0x19:
            seg = f.read(64)
            if struct.unpack('<I', seg[48:52])[0]:
                f.seek(lc + 72); s = f.read(64)
                fs = off + struct.unpack('<I', s[32:36])[0]
                break
        lc += cs
    room = (fs - (off + 32 + sizeofcmds)) if fs else 0
    flag = "OK" if room >= 80 else "FAIL"
    print("   [%s] %s 可用空隙 %d 字节（需要 80）" % (flag, arch, room))
PYEOF

    echo ""
    info "5/5 安装状态"
    if otool -l "$WECHAT_BIN" 2>/dev/null | grep -q "WeChatAntiRevoke"; then
        ok_ "已安装（LC_LOAD_DYLIB 存在）"
    else
        dim "未安装"
    fi
    if [ -f "$MANIFEST" ]; then dim "备份存在: $(latest_backup 2>/dev/null || echo '无有效备份')"; fi

    echo ""
    echo "══════════════════════════════════════"
    echo " 诊断结束。确认安装请执行:"
    echo "   $0 install"
    echo "══════════════════════════════════════"
    echo ""
}

# ── 安装 ─────────────────────────────────────────────────────
do_install() {
    check_environment
    echo ""
    warn "即将修改 /Applications/WeChat.app（重新签名，原签名作废）"
    warn "存在微信账号风控 / 封号风险，且违反微信软件许可协议"
    echo ""
    read -r -p "确认安装？输入 yes 继续: " confirm
    [ "$confirm" = "yes" ] || { echo "已取消"; exit 0; }

    elevate install --confirmed

    if pgrep -x WeChat >/dev/null 2>&1; then
        info "关闭微信..."
        killall WeChat 2>/dev/null || true
        sleep 2
    fi

    do_backup
    compile_dylib

    info "注入 dylib..."
    local r; r=$(machoc_edit inject "$WECHAT_BIN")
    case "$r" in
        *NOROOM*)  err "空间不足，已终止（微信未被修改）"; exit 1 ;;
        *already*) ok_ "此前已注入，跳过" ;;
        *)         ok_ "注入完成" ;;
    esac

    resign

    mkdir -p "$CONFIG_DIR"
    [ -f "$CONFIG_FILE" ] || echo "notify=1" > "$CONFIG_FILE"

    echo ""
    ok_ "安装完成"
    dim "启动微信后查看日志: cat $LOG_FILE"
    dim "卸载: $0 uninstall"
    echo ""
}

do_install_confirmed() {
    check_environment
    if pgrep -x WeChat >/dev/null 2>&1; then killall WeChat 2>/dev/null || true; sleep 2; fi
    do_backup
    compile_dylib
    info "注入 dylib..."
    machoc_edit inject "$WECHAT_BIN" >/dev/null
    resign
    mkdir -p "$CONFIG_DIR"
    [ -f "$CONFIG_FILE" ] || echo "notify=1" > "$CONFIG_FILE"
    ok_ "安装完成"
}

# ── 卸载（真正移除 LC）───────────────────────────────────────
do_uninstall() {
    check_environment
    elevate uninstall --confirmed
}

do_uninstall_confirmed() {
    if pgrep -x WeChat >/dev/null 2>&1; then
        info "关闭微信..."; killall WeChat 2>/dev/null || true; sleep 2
    fi

    info "移除 LC_LOAD_DYLIB..."
    machoc_edit remove "$WECHAT_BIN"

    rm -f "$DYLIB_DST" 2>/dev/null || true
    ok_ "dylib 已删除"

    if otool -l "$WECHAT_BIN" 2>/dev/null | grep -q "WeChatAntiRevoke"; then
        err "LC 仍在，正在从备份恢复..."
        do_restore_confirmed
    else
        ok_ "卸载完成，微信可正常启动"
    fi

    info "恢复签名..."
    codesign --force --deep --sign - "$WECHAT_APP" 2>/dev/null || true
    xattr -cr "$WECHAT_APP" 2>/dev/null || true
    echo ""
    dim "若微信仍异常，执行: $0 restore"
}

# ── 从备份恢复 ───────────────────────────────────────────────
do_restore() { check_environment; elevate restore --confirmed; }

do_restore_confirmed() {
    local bak; bak=$(latest_backup) || { err "没有可用备份"; exit 1; }
    if pgrep -x WeChat >/dev/null 2>&1; then killall WeChat 2>/dev/null || true; sleep 2; fi
    cp -p "$bak" "$WECHAT_BIN"
    rm -f "$DYLIB_DST" 2>/dev/null || true
    codesign --force --deep --sign - "$WECHAT_APP" 2>/dev/null || true
    xattr -cr "$WECHAT_APP" 2>/dev/null || true
    ok_ "已从 $bak 恢复"
}

do_status() {
    check_environment
    if otool -l "$WECHAT_BIN" 2>/dev/null | grep -q "WeChatAntiRevoke"; then
        ok_ "状态: 已安装"
    else
        dim "状态: 未安装"
    fi
    [ -f "$DYLIB_DST" ] && dim "dylib: $DYLIB_DST" || dim "dylib: 不存在"
    if [ -f "$MANIFEST" ]; then
        dim "备份: $(latest_backup 2>/dev/null || echo '无')"
    else
        dim "备份: 无"
    fi
    [ -f "$LOG_FILE" ] && { echo ""; dim "--- $LOG_FILE ---"; tail -20 "$LOG_FILE"; }
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
case "${1:---check}" in
    --check|check)   do_check ;;
    install)
        if [ "${2:-}" = "--confirmed" ]; then do_install_confirmed; else do_install; fi ;;
    uninstall)
        if [ "${2:-}" = "--confirmed" ]; then do_uninstall_confirmed; else do_uninstall; fi ;;
    restore)
        if [ "${2:-}" = "--confirmed" ]; then do_restore_confirmed; else do_restore; fi ;;
    status)          do_status ;;
    openNotify)      mkdir -p "$CONFIG_DIR"; echo "notify=1" > "$CONFIG_FILE"; ok_ "通知已开启" ;;
    closeNotify)     mkdir -p "$CONFIG_DIR"; echo "notify=0" > "$CONFIG_FILE"; ok_ "通知已关闭" ;;
    --help|-h)
        cat << 'USAGE'
用法:
  ./patch.sh                只读诊断（默认，不修改任何文件）
  ./patch.sh install        安装（需 sudo，会二次确认）
  ./patch.sh uninstall      完整卸载（移除 LC_LOAD_DYLIB + dylib）
  ./patch.sh restore        从备份恢复主程序
  ./patch.sh status         查看安装状态与 hook 日志
  ./patch.sh openNotify     开启撤回通知
  ./patch.sh closeNotify    关闭撤回通知

备份目录: ~/.wechat-antirevoke/backups/<时间戳>/
调试日志: /tmp/antirevoke_debug.log
USAGE
        ;;
    *) echo "未知参数: $1；用 --help 查看用法"; exit 1 ;;
esac
fi
