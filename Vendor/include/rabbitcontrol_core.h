// RabbitControl Core 移动端 FFI 头文件。
// 与 rabbitcontrol-apple-media `crates/rc-mobile-ffi` 的导出函数一一对应;
// 新增导出函数时同步更新本头文件。
#ifndef RABBITCONTROL_CORE_H
#define RABBITCONTROL_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 返回核心库版本字符串。返回值由 Rust 侧分配,用后必须 `rc_string_free` 释放。
char *rc_core_version(void);

/// 返回核心库完整构建与协议版本元数据 JSON 字符串(camelCase 字段:
/// coreVersion / gitCommit / buildTimestamp / sessionProtocolVersion /
/// punchVersion / beaconVersion / abiVersion)。
/// 返回值由 Rust 侧分配,用后必须 `rc_string_free` 释放。
char *rc_core_build_info_json(void);

/// 释放 Rust 侧分配的字符串(NULL 安全)。
void rc_string_free(char *ptr);

/// 启动局域网发现后台线程(幂等)。返回 1=已启动,0=参数非法。
int32_t rc_lan_discovery_start(uint64_t instance_id, const char *device_name);

/// 停止局域网发现线程(幂等)。
void rc_lan_discovery_stop(void);

/// 当前在线局域网节点快照,JSON 数组字符串,字段:
/// instance_id(u64)/ name(string)/ addr(string)/ requires_password(bool)/ device_id(string?)。
/// 未启动时返回 "[]"。用后必须 `rc_string_free` 释放。
char *rc_lan_peers_json(void);

// ── 统一结构化错误目录解析（iOS 平台）──

/// 按 iOS 平台解析规范错误码或 wire alias，返回标准 `UiError` JSON（camelCase 10 字段，
/// 与 `rabbitcontrol-spec` `RCUiError` 字节级对齐：
/// code / title / message / suggestion / severity / presentation / action / retryable / status? / detail?）。
/// 传入空指针或未知码时安全兜底为 `"common.unknown"`。
/// 返回值由 Rust 侧分配，用后必须 `rc_string_free` 释放。
char *rc_ui_error_resolve(const char *code, const char *detail);

// ── 认证与账号设备(全部阻塞式,禁止主线程调用;JSON 进/出)──
// 统一错误信封:{"error": "...", "kind": "unauthorized|token_reuse|password_change_required|registration_disabled|other", "ui_error": { ...RCUiError... }}

/// 探测服务器:{"server_host","api_port"?,"use_https"?,"ca_cert_pem"?,"expected_ca_fingerprint_sha256"?}
/// 返回 ServerProbeResult JSON。
char *rc_server_probe(const char *json);

/// 邮箱登录:{server..., "email","password","device_key"?,"hostname"?,"os"?,"device_pubkey"?}
/// 返回 AuthTokenResponse JSON(access_token/refresh_token/expires_in_sec/user?/device?)。
char *rc_auth_login(const char *json);

/// 邮箱注册:同 rc_auth_login,另含可选 "display_name"。
char *rc_auth_register(const char *json);

/// 轮换 Refresh Token:{server..., "refresh_token"}。
char *rc_auth_refresh(const char *json);

/// 修改密码:{server..., "access_token","current_password","new_password"};返回新令牌。
char *rc_auth_change_password(const char *json);

/// 设备重命名:{server..., "access_token","device_id","alias"}。
char *rc_auth_rename_device(const char *json);

/// 设备解绑:{server..., "access_token","device_id"}。
char *rc_auth_remove_device(const char *json);

/// 账号设备列表:{server..., "access_token"};返回 MyDeviceInfo 数组 JSON。
char *rc_auth_list_devices(const char *json);

/// Revoke this login using the access and refresh tokens supplied by Keychain.
char *rc_auth_logout(const char *json);

// ── 远控会话(非阻塞;open 后立即返回,进度经 poll 推送)──

/// 打开会话(直连模式):{"connect_addr":"ip:port","password"?,"watch_only"?,"width"?,"height"?,"fps"?,"bitrate_bps"?}
/// 返回 {"session_id": N} 或错误信封。
char *rc_session_open(const char *json);

/// 排空状态更新:{"session_id": N} →
/// {"updates":[...SessionUpdate...], "running": bool, "tool_permissions": {"allow_file_transfer": bool, "allow_terminal": bool, "allow_port_map": bool}}
/// updates 含 `tool_permissions_updated`、`tool_permission_denied`(带 iOS `ui_error`) 与 `ended`(带 iOS `ui_error`)。
char *rc_session_poll(const char *json);

/// 查询指定远控会话当前生效的工具通道权限 JSON:
/// {"allow_file_transfer": bool, "allow_terminal": bool, "allow_port_map": bool}。
/// 会话不存在时返回带 `ui_error` (`session.not_found`) 的统一错误信封。
/// 返回值由 Rust 侧分配，用后必须 `rc_string_free` 释放。
char *rc_session_tool_permissions_json(uint64_t session_id);

/// 低频指令:{"session_id": N, "command": {"type":"disconnect"|"set_bitrate"|"stage_rect"|"set_clipboard_enabled"|"set_audio_muted"|"set_stream_params"|"set_codec"|"lock_remote_screen", ...}}
/// 其中 `set_codec` 支持 `"codec": "h264"|"hevc"|"av1"`。
char *rc_session_command(const char *json);

/// 输入事件:{"session_id": N, "kind":"mouse_move|mouse_button|mouse_wheel|key", ...}
/// mouse_move: x,y 归一化 0..65535;mouse_button: button left/right/middle, pressed;
/// mouse_wheel: delta, horizontal;key: scancode, pressed, modifiers
char *rc_session_input(const char *json);

/// 关闭会话:{"session_id": N}
char *rc_session_close(const char *json);

// ── 视频通路 ──

/// 注册 Apple 媒体通路(VT 解码器+帧泵渲染器),幂等,返回 1 成功。
/// App 启动时调用一次;来自 rabbitcontrol-apple-media 仓(合并进本 xcframework)。
int rc_apple_media_init(void);
void rc_apple_clipboard_reset(void);
int rc_apple_clipboard_send(const char *json_text);
char *rc_apple_clipboard_take(void);
/// 帧链路诊断计数 JSON:{"presented_cvpb","presented_cpu","taken"}。用毕 rc_string_free。
char *rc_apple_media_stats(void);

/// 零分配帧取放结构体(与 Rust 侧 `RcAppleFrame` ABI 一致)。
typedef struct RcAppleFrame {
    uint64_t ptr;
    uint32_t width;
    uint32_t height;
    uint64_t seq;
} RcAppleFrame;

/// 零分配快速取走最新帧(所有权转移):无帧返回 false(零锁零堆分配),有帧写入 *out 返回 true。
/// out->ptr 即 CVPixelBufferRef;用毕必须调 rc_apple_media_frame_release(out->ptr)。
bool rc_apple_media_frame_take_raw(RcAppleFrame *out);

/// 取走最新帧(所有权转移):{"ptr": u64, "width", "height", "seq"},无帧返回 {}。
/// ptr 即 CVPixelBufferRef;用毕必须调 rc_apple_media_frame_release。
/// 返回字符串用毕调 rc_string_free 释放(同一分配器)。
char *rc_apple_media_frame_take(void);

/// 释放帧(仅限 rc_apple_media_frame_take / rc_apple_media_frame_take_raw 取走的 ptr,每帧一次)。
void rc_apple_media_frame_release(uint64_t ptr);

// ── 出站网络代理（进程级全局配置，可在 rc_runtime_init 前调用）──

/// 更新进程级活跃出站代理配置（ProxyConfig JSON，camelCase 字段：
/// mode("none"|"system"|"manual") / protocol?("http"|"socks5") / host / port / username? / password?）。
/// 校验合法后立即对后续认证、信令与中继生效；若配置发生变更且信令已启动，
/// 将自动触发信令快速重连切换至新代理路径。成功返回 {"ok":true}，
/// 失败返回统一错误信封（含 iOS `ui_error`，绝不泄露密码明文）。
/// 返回值由 Rust 侧分配，用后必须 `rc_string_free` 释放。
char *rc_proxy_set_config_json(const char *config_json);

// ── 运行时(有状态:认证会话+信令+一键连接;所有返回字符串均须 `rc_string_free` 释放)──
// 失败时一律返回统一错误信封:{"error": "...", "kind": "...", "ui_error": { ...RCUiError... }}（snake_case `ui_error`）。
char *rc_runtime_init(const char *json);
char *rc_runtime_login(const char *json);
char *rc_runtime_set_session(const char *json);
char *rc_runtime_status(void);
char *rc_runtime_logout(void);
char *rc_signal_start(const char *json);
/// 查询当前信令状态快照:
/// - 成功返回 `ServerStatusSnapshot` JSON（camelCase 字段，含可选 `uiError` 结构化错误对象）；
/// - 失败（如未初始化/未启动）返回统一错误信封（snake_case `ui_error`）。
/// 返回值由 Rust 侧分配，用后必须 `rc_string_free` 释放。
char *rc_signal_status(const char *json);
char *rc_signal_stop(void);
/// 向服务端发起 Wake-on-LAN 远程开机请求（阻塞等待 `wol_ack`，禁止主线程调用）。
/// - `target_device_id`: 目标 9 位设备码（允许带空格格式化）。
/// - `timeout_ms`: 等待超时毫秒数（传 0 默认 10000ms，上限 60000ms）。
/// 成功收到服务端应答时返回 `WolAckResult` JSON（camelCase 字段：
/// targetDeviceId / ok / method / code? / message / uiError?）；
/// 入参非法、运行时未初始化、信令未启动、超时或断线时返回统一错误信封（snake_case `ui_error`）。
/// 返回值由 Rust 侧分配，用后必须 `rc_string_free` 释放。
char *rc_signal_request_wol(const char *target_device_id, uint32_t timeout_ms);
/// 返回当前已缓存的同账号设备 Wake-on-LAN 能力快照 JSON 对象（键为 9 位规范设备码，值为 bool）。
/// 运行时未初始化或信令未启动时返回 "{}"。
/// 返回值由 Rust 侧分配，用后必须 `rc_string_free` 释放。
char *rc_signal_wol_capable_snapshot_json(void);
char *rc_runtime_connect(const char *json);

// ── 工具通道(文件/终端/端口映射;所有返回字符串均须 `rc_string_free` 释放)──
// 失败时一律返回统一错误信封:{"error": "...", "kind": "...", "ui_error": { ...RCUiError... }}。
char *rc_tools_call(uint64_t session_id, const char *json);
char *rc_tools_poll(uint64_t session_id);

#ifdef __cplusplus
}
#endif

#endif // RABBITCONTROL_CORE_H
