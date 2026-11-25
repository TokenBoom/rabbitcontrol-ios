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

#ifdef __cplusplus
}
#endif

#endif // RABBITCONTROL_CORE_H
