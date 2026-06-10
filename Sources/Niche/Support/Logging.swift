import os

/// 统一日志。文件操作等失败不静默吞(CLAUDE.md:不兜底、让问题正面暴露),至少落到
/// 系统日志便于诊断;面向用户的错误反馈在交互处另行处理。
enum Log {
    static let files = Logger(subsystem: "com.ccfco.Niche", category: "files")
    static let mirror = Logger(subsystem: "com.ccfco.Niche", category: "mirror")
    static let window = Logger(subsystem: "com.ccfco.Niche", category: "window")
    static let updates = Logger(subsystem: "com.ccfco.Niche", category: "updates")
}
