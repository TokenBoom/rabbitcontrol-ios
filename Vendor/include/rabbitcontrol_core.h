// RabbitControl Core 移动端 FFI 头文件。
// 与 rabbitcontrol-core `crates/rc-mobile-ffi` 的导出函数一一对应;
// 新增导出函数时同步更新本头文件。
#ifndef RABBITCONTROL_CORE_H
#define RABBITCONTROL_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 返回核心库版本字符串。返回值由 Rust 侧分配,用后必须 `rc_string_free` 释放。
char *rc_core_version(void);

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

// ── 认证与账号设备(全部阻塞式,禁止主线程调用;JSON 进/出)──
// 统一错误信封:{"error": "...", "kind": "unauthorized|token_reuse|password_change_required|registration_disabled|other"}

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

// ── 远控会话(非阻塞;open 后立即返回,进度经 poll 推送)──

/// 打开会话(直连模式):{"connect_addr":"ip:port","password"?,"watch_only"?,"width"?,"height"?,"fps"?,"bitrate_bps"?}
/// 返回 {"session_id": N} 或错误信封。
char *rc_session_open(const char *json);

/// 排空状态更新:{"session_id": N} → {"updates":[...SessionUpdate...], "running": bool}
char *rc_session_poll(const char *json);

/// 低频指令:{"session_id": N, "command": {"type":"disconnect"|"set_bitrate"|"stage_rect"|"set_clipboard_enabled"|"set_audio_muted"|"set_stream_params"|"lock_remote_screen", ...}}
char *rc_session_command(const char *json);

/// 输入事件:{"session_id": N, "kind":"mouse_move|mouse_button|mouse_wheel|key", ...}
/// mouse_move: x,y 归一化 0..65535;mouse_button: button left/right/middle, pressed;
/// mouse_wheel: delta, horizontal;key: scancode, pressed, modifiers
char *rc_session_input(const char *json);

/// 关闭会话:{"session_id": N}
char *rc_session_close(const char *json);

#ifdef __cplusplus
}
#endif

#endif // RABBITCONTROL_CORE_H
