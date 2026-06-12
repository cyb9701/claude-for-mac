import Foundation

/// OAuth 토큰 관리자.
///
/// macOS Keychain의 "Claude Code-credentials" 항목에서 토큰을 로드한다.
/// 실제 Keychain JSON 구조:
/// {
///   "claudeAiOauth": {
///     "accessToken": "sk-ant-oat01-...",
///     "refreshToken": "sk-ant-ort01-...",
///     "expiresAt": 1774950761041,  // 밀리초 단위 Unix 타임스탬프
///     "scopes": [...],
///     "subscriptionType": "max",
///     "rateLimitTier": "..."
///   },
///   "organizationUuid": "..."
/// }
/// actor를 사용하여 Swift 6의 데이터 레이스 안전성을 보장한다.
actor OAuthTokenManager {

    static let shared = OAuthTokenManager()

    /// 토큰 만료 전 선제 갱신 여유 시간 (초).
    ///
    /// 만료 직전에 API 호출이 실패하는 것을 방지하기 위해
    /// 만료 시각보다 이 값만큼 앞서서 갱신을 시도한다.
    private static let tokenRefreshMarginSeconds: TimeInterval = 60

    /// OAuth 토큰 갱신 엔드포인트.
    private static let tokenRefreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// Claude Code CLI의 공개 OAuth 클라이언트 ID.
    ///
    /// Anthropic OAuth는 공개 클라이언트(public client) 방식이라 토큰 갱신 시
    /// client_id가 필수다. 누락하거나 form 인코딩으로 보내면 토큰 검증 전에
    /// 400 "Invalid request format"으로 거절되므로,
    /// Claude Code CLI가 사용하는 것과 동일한 ID를 JSON 본문으로 보낸다.
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Claude Code CLI가 자격증명을 저장하는 Keychain 서비스 이름.
    private static let keychainService = "Claude Code-credentials"

    // 메모리 캐시: 만료 전 tokenRefreshMarginSeconds까지 유효
    private var cachedToken: String?
    private var tokenExpiresAt: Date?
    private var cachedRefreshToken: String?

    /// 자격증명을 읽어온 저장소 위치.
    ///
    /// 토큰 갱신 성공 시 새 토큰을 같은 저장소에 다시 써서(write-back)
    /// Claude Code CLI와 토큰 상태를 동기화하기 위해 기억한다.
    private var credentialSource: CredentialSource?

    /// 마지막으로 읽은 자격증명 원본 JSON.
    ///
    /// write-back 시 scopes, subscriptionType, organizationUuid 등
    /// 앱이 해석하지 않는 필드까지 보존한 채 토큰 필드만 갱신하기 위해 보관한다.
    private var rawCredentialsJSON: Data?

    private init() {}

    // MARK: - 공개 메서드

    /// 유효한 access token 반환. 만료 시 자동 갱신.
    ///
    /// Keychain 접근 빈도를 최소화하여 비밀번호 팝업을 줄인다.
    /// 캐시 → refresh token으로 HTTP 갱신 → Keychain 순서로 시도한다.
    func getValidToken() async throws -> String {
        // 1단계: 캐시된 토큰이 아직 유효하면 즉시 반환
        // expiresAt이 nil이면 만료 시점을 알 수 없으므로 캐시된 토큰을 그대로 사용한다.
        // (단순 토큰 문자열 파싱 경로에서 expiresAt: nil로 반환될 수 있음)
        if let cached = cachedToken {
            guard let expiresAt = tokenExpiresAt else { return cached }
            if expiresAt.timeIntervalSinceNow > Self.tokenRefreshMarginSeconds {
                return cached
            }
        }

        // 2단계: 캐시된 refresh token으로 HTTP 갱신 시도 (Keychain 접근 없음)
        if let refreshToken = cachedRefreshToken, !refreshToken.isEmpty {
            if let newToken = try? await refreshAccessToken(using: refreshToken) {
                return newToken
            }
        }

        // 3단계: 저장된 자격증명 로드 (Keychain → 파일 폴백 순)
        let credentials = try loadCredentials()

        // HTTP 갱신 전에 refresh token을 먼저 캐시한다.
        // 갱신이 실패하더라도 이후 Stage 2에서 재시도할 수 있다.
        if !credentials.refreshToken.isEmpty {
            cachedRefreshToken = credentials.refreshToken
        }

        // 토큰 만료 여부 확인 후 갱신
        if let expiresAt = credentials.expiresAt,
           expiresAt.timeIntervalSinceNow < Self.tokenRefreshMarginSeconds,
           !credentials.refreshToken.isEmpty {
            return try await refreshAccessToken(using: credentials.refreshToken)
        }

        // 유효한 토큰 캐시 저장
        cachedToken = credentials.accessToken
        tokenExpiresAt = credentials.expiresAt

        return credentials.accessToken
    }

    // MARK: - 자격증명 로드

    private func loadCredentials() throws -> OAuthCredentials {
        let account = NSUserName()

        // 1순위: Keychain "Claude Code-credentials" (Claude Code CLI)
        if let loaded = try? readKeychain(
            service: Self.keychainService,
            account: account
        ) {
            credentialSource = .keychain(service: Self.keychainService, account: account)
            rawCredentialsJSON = loaded.rawJSON
            return loaded.credentials
        }

        // 2순위: ~/.claude/.credentials.json (Claude Code CLI의 파일 폴백).
        // Claude Code는 Keychain을 사용할 수 없는 환경에서 자격증명을
        // 이 파일에 저장하므로, 해당 사용자도 로그인 상태로 인식되어야 한다.
        if let loaded = try? readCredentialsFile() {
            credentialSource = .file(loaded.url)
            rawCredentialsJSON = loaded.rawJSON
            return loaded.credentials
        }

        // 3순위: 환경변수 (DEBUG 빌드 전용 테스트 폴백).
        // 릴리즈 빌드에서는 환경변수를 통한 토큰 우회를 차단하여
        // 의도치 않은 토큰 노출을 방지한다.
        #if DEBUG
        if let envToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"] {
            return OAuthCredentials(
                accessToken: envToken,
                refreshToken: "",
                expiresAt: Date().addingTimeInterval(3600)
            )
        }
        #endif

        throw ClaudeUsageError.credentialsNotFound
    }

    /// Claude Code CLI의 자격증명 파일을 읽는다.
    ///
    /// Claude Code는 Keychain 접근이 불가능한 환경에서
    /// `~/.claude/.credentials.json`에 Keychain 항목과 동일한
    /// JSON 구조(`claudeAiOauth` 래퍼)로 자격증명을 저장한다.
    /// Keychain 항목이 없어도 이 파일이 있으면 로그인 상태로 동작한다.
    private func readCredentialsFile() throws -> (credentials: OAuthCredentials, rawJSON: Data, url: URL) {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        let data = try Data(contentsOf: fileURL)
        return (try parseCredentialsData(data), data, fileURL)
    }

    /// Keychain 항목을 `/usr/bin/security` 서브프로세스로 읽는다.
    ///
    /// SecItemCopyMatching(네이티브 API)으로 직접 읽으면 macOS가
    /// "다른 앱의 비밀 정보 접근"으로 간주해 키체인 비밀번호 팝업을 띄운다.
    /// 이 항목은 Claude Code CLI가 `security` 도구로 생성·갱신하므로,
    /// 같은 `security` 도구를 통해 읽으면 항목 작성자와 접근자가 일치하여
    /// 토큰 갱신·재로그인·앱 재빌드와 무관하게 팝업이 발생하지 않는다.
    /// (claude CLI 자신이 팝업 없이 토큰을 읽는 것과 같은 원리)
    private func readKeychain(
        service: String,
        account: String
    ) throws -> (credentials: OAuthCredentials, rawJSON: Data) {
        // 항목 없음(item not found)을 나타내는 security 도구의 종료 코드.
        let securityExitCodeItemNotFound: Int32 = 44

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w",
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        // stderr의 진단 메시지는 사용하지 않으므로 버린다.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ClaudeUsageError.keychainReadFailed(-1)
        }

        // 파이프 버퍼가 가득 차 교착되지 않도록 종료 대기 전에 출력을 먼저 읽는다.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            if process.terminationStatus == securityExitCodeItemNotFound {
                throw ClaudeUsageError.credentialsNotFound
            }
            throw ClaudeUsageError.keychainReadFailed(OSStatus(process.terminationStatus))
        }

        // `-w` 출력 끝에 붙는 개행을 제거한 뒤 파싱한다.
        guard let raw = String(data: data, encoding: .utf8),
              let credentialsData = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                  .data(using: .utf8),
              !credentialsData.isEmpty else {
            throw ClaudeUsageError.invalidCredentials
        }

        return (try parseCredentialsData(credentialsData), credentialsData)
    }

    private func parseCredentialsData(_ data: Data) throws -> OAuthCredentials {
        // 래퍼 구조 파싱: { "claudeAiOauth": { "accessToken": ... } }
        if let wrapper = try? JSONDecoder().decode(CredentialsWrapper.self, from: data) {
            return wrapper.claudeAiOauth
        }

        // 래퍼 없는 직접 구조: { "accessToken": ... }
        if let direct = try? JSONDecoder().decode(OAuthCredentials.self, from: data) {
            return direct
        }

        // 단순 토큰 문자열
        if let tokenString = String(data: data, encoding: .utf8),
           tokenString.hasPrefix("sk-ant-") {
            return OAuthCredentials(
                accessToken: tokenString.trimmingCharacters(in: .whitespacesAndNewlines),
                refreshToken: "",
                expiresAt: nil
            )
        }

        throw ClaudeUsageError.invalidCredentials
    }

    // MARK: - 토큰 갱신

    private func refreshAccessToken(using refreshToken: String) async throws -> String {
        var request = URLRequest(
            url: Self.tokenRefreshURL,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Anthropic OAuth 토큰 엔드포인트는 RFC 6749 표준의 form 인코딩이 아닌
        // JSON 본문을 요구하며, 공개 클라이언트이므로 client_id가 필수다.
        // form 인코딩이나 client_id 누락 시 토큰 검증 전 단계에서
        // 400 "Invalid request format"으로 거절된다.
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientID,
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // 네트워크 계층 오류 (연결 없음, 타임아웃 등) — 재시도 가능
            throw ClaudeUsageError.tokenRefreshNetworkError
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // HTTP 4xx/5xx: 인증 오류 (토큰 무효, 서버 오류 등) — 재로그인 필요
            throw ClaudeUsageError.tokenRefreshFailed
        }

        let refreshed = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)

        cachedToken = refreshed.accessToken
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(refreshed.expiresIn ?? 3600))
        // 서버가 새 refresh token을 반환한 경우(토큰 로테이션) 캐시를 갱신한다.
        if let newRefreshToken = refreshed.refreshToken, !newRefreshToken.isEmpty {
            cachedRefreshToken = newRefreshToken
        }

        // 갱신된 토큰을 원래 저장소에 다시 쓴다(write-back).
        // 토큰 로테이션 시 저장소의 옛 refresh token은 무효화될 수 있으므로,
        // 써주지 않으면 Claude Code CLI가 다음 갱신에 실패해 로그아웃될 수 있다.
        persistRefreshedCredentials(
            accessToken: refreshed.accessToken,
            refreshToken: cachedRefreshToken ?? refreshToken,
            expiresAt: tokenExpiresAt
        )

        return refreshed.accessToken
    }

    // MARK: - 자격증명 저장 (write-back)

    /// 갱신된 토큰을 자격증명을 읽어온 저장소에 다시 쓴다.
    ///
    /// 원본 JSON의 토큰 관련 필드만 교체하고 나머지 필드(scopes,
    /// subscriptionType, organizationUuid 등)는 그대로 보존하여
    /// Claude Code CLI가 기대하는 구조를 깨뜨리지 않는다.
    /// 저장에 실패해도 메모리 캐시는 유효하므로 앱 동작에는 지장이 없고,
    /// 다음 갱신 성공 시 다시 시도된다.
    private func persistRefreshedCredentials(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date?
    ) {
        guard let source = credentialSource,
              let raw = rawCredentialsJSON,
              var root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return }

        func applyTokenFields(_ dict: inout [String: Any]) {
            dict["accessToken"] = accessToken
            dict["refreshToken"] = refreshToken
            if let expiresAt {
                // Claude Code CLI와 동일하게 밀리초 단위 Unix 타임스탬프로 저장한다.
                dict["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
            }
        }

        // 래퍼 구조({"claudeAiOauth": {...}})면 내부를, 직접 구조면 최상위를 갱신한다.
        if var oauth = root["claudeAiOauth"] as? [String: Any] {
            applyTokenFields(&oauth)
            root["claudeAiOauth"] = oauth
        } else {
            applyTokenFields(&root)
        }

        guard let merged = try? JSONSerialization.data(withJSONObject: root) else { return }

        do {
            switch source {
            case .keychain(let service, let account):
                guard let secret = String(data: merged, encoding: .utf8) else { return }
                try writeKeychainItem(service: service, account: account, secret: secret)
            case .file(let url):
                try writeCredentialsFile(url: url, data: merged)
            }
            rawCredentialsJSON = merged
        } catch {
            // 저장 실패는 치명적이지 않으므로 무시한다 (메모리 캐시로 계속 동작).
        }
    }

    /// Keychain 항목을 `/usr/bin/security` 서브프로세스로 쓴다.
    ///
    /// 읽기와 동일하게 `security` 도구를 사용해야 항목 작성자가 유지되어
    /// Claude Code CLI와 이 앱 모두 비밀번호 팝업 없이 계속 읽을 수 있다.
    /// 대화형 모드(-i)로 명령을 stdin에 전달하여 비밀값이
    /// 프로세스 인자(`ps` 출력)에 노출되지 않도록 한다.
    private func writeKeychainItem(service: String, account: String, secret: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]

        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // -U: 동일 항목이 이미 있으면 새 값으로 갱신한다.
        let command = "add-generic-password -U"
            + " -a \"\(escapedForSecurityCLI(account))\""
            + " -s \"\(escapedForSecurityCLI(service))\""
            + " -w \"\(escapedForSecurityCLI(secret))\"\n"

        do {
            try process.run()
        } catch {
            throw ClaudeUsageError.keychainWriteFailed(-1)
        }

        stdin.fileHandleForWriting.write(Data(command.utf8))
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ClaudeUsageError.keychainWriteFailed(OSStatus(process.terminationStatus))
        }
    }

    /// `security -i` 명령 문자열에 안전하게 넣기 위한 이스케이프.
    ///
    /// 큰따옴표로 감싼 인자 내부의 백슬래시와 큰따옴표를 이스케이프한다.
    private func escapedForSecurityCLI(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 자격증명 파일을 소유자 전용 권한으로 다시 쓴다.
    private func writeCredentialsFile(url: URL, data: Data) throws {
        try data.write(to: url, options: .atomic)
        // 자격증명 파일은 Claude Code CLI와 동일하게 0600 권한을 유지한다.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

/// 자격증명 저장소 종류.
///
/// 토큰 갱신 후 write-back 대상을 결정하기 위해 사용한다.
private enum CredentialSource {
    case keychain(service: String, account: String)
    case file(URL)
}

// MARK: - 내부 모델

/// Keychain 최상위 래퍼 구조.
private struct CredentialsWrapper: Decodable {
    let claudeAiOauth: OAuthCredentials
}

/// OAuth 자격증명. expiresAt은 밀리초 단위 Unix 타임스탬프.
///
/// OAuthTokenManager 내부에서만 사용되는 자격증명 모델.
/// 모듈 내부 접근으로 제한하여 API 표면을 최소화한다.
struct OAuthCredentials: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date?

    /// ISO 8601 문자열 파싱용 포맷터.
    ///
    /// ISO8601DateFormatter는 생성 비용이 높으므로 static으로 재사용한다.
    /// UsageWindow의 패턴과 동일하게 통일한다.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(accessToken: String, refreshToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        guard let token = try? c.decode(String.self, forKey: .accessToken) else {
            throw ClaudeUsageError.invalidCredentials
        }
        accessToken = token
        refreshToken = (try? c.decode(String.self, forKey: .refreshToken)) ?? ""

        // expiresAt: 밀리초 단위 Unix 타임스탬프 (예: 1774950761041)
        if let ms = try? c.decode(Double.self, forKey: .expiresAt) {
            // 2001-09-09 이후의 타임스탬프(13자리 이상)는 밀리초 단위로 판별한다.
            // 초 단위(10자리)와 밀리초 단위(13자리)를 구분하는 경계값.
            let millisecondsThreshold: Double = 1_000_000_000_000
            let seconds = ms > millisecondsThreshold ? ms / 1000 : ms
            expiresAt = Date(timeIntervalSince1970: seconds)
        } else if let isoStr = try? c.decode(String.self, forKey: .expiresAt) {
            expiresAt = Self.isoFormatter.date(from: isoStr)
        } else {
            expiresAt = nil
        }
    }
}

/// 토큰 갱신 API 응답.
///
/// OAuth 2.0 RFC 6749 ss6에 따라 서버는 새 refresh token을 반환할 수 있다(토큰 로테이션).
/// refreshToken이 nil이면 기존 캐시된 refresh token을 계속 사용한다.
/// OAuthTokenManager 내부에서만 사용되는 응답 모델.
struct TokenRefreshResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?
    /// 서버가 토큰 로테이션 시 반환하는 새 refresh token.
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}
