import Foundation

/// 提醒方式映射（对照 src/main/attention-policy.ts:3-20）。
public enum AttentionRequestKind: Equatable, Sendable {
    case none
    case edge
    case overlay(placement: AttentionPlacement)
}

public enum AttentionPlacement: String, Equatable, Sendable {
    case corner
    case center
    case edge
}

public enum AttentionPolicy {
    public static func request(for config: AppConfig, durationMs: Int? = nil) -> (kind: AttentionRequestKind, durationMs: Int) {
        let duration = durationMs ?? config.attentionDurationMs
        switch config.attentionMode {
        case .off:
            return (.none, duration)
        case .panelPulse:
            return (.edge, duration)
        case .cornerOverlay:
            return (.overlay(placement: .corner), duration)
        case .centerOverlay:
            return (.overlay(placement: .center), duration)
        }
    }
}
