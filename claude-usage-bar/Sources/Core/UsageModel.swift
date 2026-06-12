import Foundation

// MARK: - 사용량 데이터 모델

/// Claude Pro 전체 사용량 스냅샷.
///
/// OAuth API 응답과 OTel 메트릭을 통합하여
/// 메뉴바에 표시할 모든 사용량 정보를 담는다.
struct ClaudeUsageData {
    let fiveHour: RateWindow
    let sevenDay: RateWindow?
    let sevenDaySonnet: RateWindow?
    let fetchedAt: Date
}

/// 특정 기간의 사용량 윈도우.
///
/// OAuth API는 used/limit 대신 utilization(0~100 퍼센트)을 반환하므로
/// ratio를 기반으로 표시한다.
struct RateWindow {
    /// 사용률 (0.0 ~ 1.0).
    let ratio: Double

    /// 리셋 시각. nil이면 서버에서 미반환.
    let resetAt: Date?

    /// 남은 시간 (초).
    var secondsUntilReset: TimeInterval? {
        guard let resetAt else { return nil }
        return max(0, resetAt.timeIntervalSinceNow)
    }

    /// 퍼센트 정수값 (표시용).
    var percentInt: Int { Int(ratio * 100) }
}

/// OTel Prometheus에서 수집한 Claude Code CLI 메트릭.
struct CodeUsageMetrics {
    let inputTokens: Double
    let outputTokens: Double
    let cacheReadTokens: Double
    let costUSD: Double
    let sessionCount: Double
}

// MARK: - API 응답 디코딩 모델

/// OAuth Usage API 실제 응답 구조.
///
/// GET https://api.anthropic.com/api/oauth/usage
/// Header: anthropic-beta: oauth-2025-04-20
///
/// 실제 응답 예시:
/// {
///   "five_hour": { "utilization": 50.0, "resets_at": "2026-03-31T05:00:01Z" },
///   "seven_day": { "utilization": 45.0, "resets_at": "2026-04-04T14:00:00Z" },
///   "seven_day_sonnet": { "utilization": 12.0, "resets_at": "..." },
///   ...
/// }
struct OAuthUsageAPIResponse: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDaySonnet: UsageWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    /// API 응답을 도메인 모델로 변환.
    func toUsageData() -> ClaudeUsageData? {
        guard let fiveHour, let window = fiveHour.toRateWindow() else { return nil }
        return ClaudeUsageData(
            fiveHour: window,
            sevenDay: sevenDay?.toRateWindow(),
            sevenDaySonnet: sevenDaySonnet?.toRateWindow(),
            fetchedAt: Date()
        )
    }
}

/// API 응답의 개별 윈도우.
struct UsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    // ISO8601DateFormatter 생성 비용이 높으므로 static으로 재사용한다.
    // API 응답마다 최대 3회(fiveHour, sevenDay, sevenDaySonnet) 호출되므로
    // 매번 생성하면 불필요한 할당이 반복된다.

    /// "2026-03-31T05:00:01.160872+00:00" 소수초 포함 형식용.
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// "2026-03-31T05:00:01Z" 소수초 미포함 형식용.
    private static let isoFormatterBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// ISO 8601 + timezone 문자열을 Date로 변환하여 RateWindow 생성.
    func toRateWindow() -> RateWindow? {
        guard let utilization else { return nil }

        var resetDate: Date?
        if let resetsAt {
            resetDate = Self.isoFormatterWithFractional.date(from: resetsAt)
                ?? Self.isoFormatterBasic.date(from: resetsAt)
        }

        return RateWindow(ratio: utilization / 100.0, resetAt: resetDate)
    }
}

// MARK: - 에러 정의

enum ClaudeUsageError: LocalizedError {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case credentialsNotFound
    case invalidCredentials
    case tokenRefreshFailed
    case tokenRefreshNetworkError
    case apiError(Int, String)
    case unexpectedResponseFormat(String)

    var errorDescription: String? {
        switch self {
        case .keychainReadFailed(let status):
            return "Keychain 읽기 실패 (오류: \(status))"
        case .keychainWriteFailed(let status):
            return "Keychain 쓰기 실패 (오류: \(status))"
        case .credentialsNotFound:
            return "Claude Code 자격증명을 찾을 수 없습니다. Claude Code를 먼저 로그인해주세요."
        case .invalidCredentials:
            return "자격증명 형식이 올바르지 않습니다."
        case .tokenRefreshFailed:
            return "OAuth 토큰 갱신에 실패했습니다. Claude Code 재로그인이 필요할 수 있습니다."
        case .tokenRefreshNetworkError:
            return "네트워크 연결을 확인해주세요. 잠시 후 자동으로 재시도합니다."
        case .apiError(let code, let message):
            // 서버 응답에 내부 경로나 디버그 정보가 포함될 수 있으므로 길이를 제한한다.
            return "API 오류 \(code): \(String(message.prefix(100)))"
        case .unexpectedResponseFormat(let raw):
            return "예상치 못한 응답 형식: \(raw.prefix(200))"
        }
    }
}
