import Foundation
import RemoteForgeRelay
import RemoteForgeRelayNIO

/// Stable user-facing errors; never format a raw network error or invitation.
enum RelayErrorMessage {
    static func message(_ error: Error) -> String {
        if let error = error as? RelayCredentialError { return error.localizedDescription }
        if let error = error as? RelayError {
            switch error {
            case .invalidEndpoint: return "Relay 入口无效，请使用完整的 HTTPS 域名。"
            case .invalidInvitation: return "配对邀请无效，请重新扫码、粘贴链接或导入邀请文件。"
            case .invitationExpired: return "配对邀请已过期，请在电脑上生成新的邀请。"
            case .invalidCredential: return "Relay 凭据已过期或不可用，请重新配对。"
            case .invalidName: return "设备名称过长或包含无效字符，请修改后重试。"
            case .httpStatus(401): return "Relay 授权已失效，请重新配对。"
            case .httpStatus(403): return "Relay 拒绝访问，邀请可能已使用或过期，请生成新的邀请。"
            case .httpStatus(429): return "Relay 当前连接或配对数量已达上限，请稍后重试。"
            case .httpStatus(503): return "Relay 目标设备离线或服务暂不可用，请确认电脑 Agent 正在运行。"
            case .httpStatus(let code): return "Relay 请求失败（HTTP \(code)）。"
            case .networkFailure: return "无法连接 Relay，请检查当前网络和中继服务。"
            case .timedOut: return "连接 Relay 超时，请稍后重试。"
            case .closed: return "Relay 连接已关闭，请重新连接。"
            case .protocolViolation: return "Relay 返回的数据格式不正确，连接已停止。"
            case .operationInProgress: return "Relay 通道当前忙，请重试连接。"
            case .writeClosed: return "Relay 通道的发送方向已关闭。"
            }
        }
        if let error = error as? RelayNIOError {
            switch error {
            case .bufferLimitExceeded: return "Relay 发送队列已满，连接已停止，请重新连接。"
            case .activationTimedOut: return "Relay 连接准备超时，请重新连接。"
            default: return "Relay 通道未能建立，请重试连接。"
            }
        }
        if error is CancellationError { return "已取消 Relay 配对。" }
        return "Relay 操作未完成，请重试。"
    }
    static func isRetryable(_ error: RelayError) -> Bool {
        switch error {
        case .networkFailure, .timedOut, .closed: return true
        case .httpStatus(let code): return code >= 500 || code == 429
        default: return false
        }
    }
}
