import os

/// 统一日志。文件操作等失败不静默吞(CLAUDE.md:不兜底、让问题正面暴露),至少落到
/// 系统日志便于诊断;面向用户的错误反馈在交互处另行处理。
enum Log {
    static let files = Logger(subsystem: "com.ccfco.Niche", category: "files")
    static let mirror = Logger(subsystem: "com.ccfco.Niche", category: "mirror")
    static let window = Logger(subsystem: "com.ccfco.Niche", category: "window")
    static let updates = Logger(subsystem: "com.ccfco.Niche", category: "updates")
    /// 触发链路(热区进出/dwell/present 各守卫吞弃):偶现「呼不出」全靠它归因,
    /// 排查口令:log show --last 5m --info --predicate 'subsystem == "com.ccfco.Niche" AND category == "trigger"'
    static let trigger = Logger(subsystem: "com.ccfco.Niche", category: "trigger")
}
