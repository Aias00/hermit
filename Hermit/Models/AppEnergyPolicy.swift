import Foundation

/// Adapt presentation and metadata cadence, never terminal input or parsing.
struct AppEnergyPolicy: Equatable {
    let terminalFramesPerSecond: Int
    let samplingInterval: TimeInterval

    init(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) {
        switch thermalState {
        case .nominal:
            terminalFramesPerSecond = lowPowerMode ? 30 : 60
            samplingInterval = lowPowerMode ? 4 : 2
        case .fair:
            terminalFramesPerSecond = 30
            samplingInterval = 4
        case .serious:
            terminalFramesPerSecond = 15
            samplingInterval = 6
        case .critical:
            terminalFramesPerSecond = 10
            samplingInterval = 10
        @unknown default:
            terminalFramesPerSecond = 30
            samplingInterval = 4
        }
    }

    static var current: Self {
        let info = ProcessInfo.processInfo
        return .init(lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState)
    }
}

@MainActor
final class EnergyPolicyObservation {
    private var tokens: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor () -> Void) {
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            })
        }
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
