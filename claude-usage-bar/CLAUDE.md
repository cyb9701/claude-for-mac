# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

ClaudeUsageBar는 macOS 메뉴바에서 Claude Pro 사용량(토큰 소모율)을 실시간으로 표시하는 네이티브 SwiftUI 앱입니다. Dock 아이콘 없이 메뉴바 전용(`LSUIElement = YES`)으로 동작합니다.

## 빌드 및 실행 명령어

```bash
# 최초 빌드 + ~/Applications 에 앱 설치 + 실행
make install

# 코드 수정 후 핫 교체 (실행 중인 앱 재시작 없이 업데이트)
make update

# 터미널에서 직접 실행 (개발 모드)
make run

# 앱 제거
make uninstall

# 빌드 캐시 정리
make clean
```

Xcode 프로젝트 파일이 없으며, SPM(Swift Package Manager) + Makefile 조합으로만 빌드합니다.

코드서명 인증서는 `Makefile.local`(gitignore 적용)에서 설정합니다:

```makefile
# Makefile.local (버전 관리 제외)
CERT_NAME = Developer ID Application: Your Name (TEAMID)
```

## 아키텍처

### 레이어 구조

```
ClaudeUsageBarApp (@main)
    └── AppState (Core/AppState.swift)          ← 전역 상태, 타이머 오케스트레이션
         ├── UsageFetching (protocol)            ← Usage API 추상화 (DIP)
         │    └── OAuthUsageFetcher (Features/ProUsage/) ← 구현체
         ├── MetricsPolling (protocol)           ← OTel 메트릭 추상화 (DIP)
         │    └── PrometheusPoller (Features/OTel/)      ← 구현체 (선택)
         └── OAuthTokenManager (Auth/)           ← Keychain 토큰 읽기/갱신 (actor)

UI/
    ├── DisplayFormatters.swift                 ← 포맷팅 유틸리티 (SRP 분리)
    └── LiquidGlassModifier.swift               ← macOS 26+ Liquid Glass 효과
```

### 상태 관리

- `AppState`가 `@Observable`(Swift 5.9+) 기반 유일한 상태 소스. `@ObservableObject`/`@Published`를 사용하지 않음
- 뷰에서는 `@Environment` 또는 직접 참조로 주입받고 별도 `@StateObject` 불필요
- 갱신 주기: Pro 사용량 5분, OTel 메트릭 1분, 카운트다운 1초

### 인증 흐름

1. macOS Keychain에서 `"Claude Code-credentials"` 항목 읽기 (Claude Code CLI가 저장)
   - `/usr/bin/security find-generic-password` 서브프로세스로 읽음 — 항목 작성자(`security` 도구)와 접근자가 일치하여 키체인 비밀번호 팝업이 발생하지 않음 (네이티브 `SecItemCopyMatching`은 팝업 유발)
2. Keychain 항목이 없으면 `~/.claude/.credentials.json` 파일 폴백 (Claude Code가 Keychain 미사용 환경에서 저장하는 동일 구조의 JSON)
3. JSON 디코딩 → `accessToken`, `refreshToken`, `expiresAt`(ms) 추출
4. 만료 60초 전 자동 갱신: `POST https://platform.claude.com/v1/oauth/token`
   - 요청은 **JSON 본문 + `client_id`**(Claude Code 공개 OAuth 클라이언트 ID) 필수 — form 인코딩이나 `client_id` 누락 시 토큰 검증 전에 400 "Invalid request format"으로 거절됨
5. 갱신 성공 시 새 토큰을 원래 저장소에 write-back (Keychain은 `security -i` stdin 방식, 파일은 0600 권한 유지) — 토큰 로테이션으로 Claude Code CLI가 로그아웃되는 것을 방지하며, 토큰 외 필드(scopes, subscriptionType 등)는 보존
6. 테스트 폴백: 환경 변수 `CLAUDE_CODE_OAUTH_TOKEN` (`#if DEBUG` 빌드 한정)

**전제 조건**: Claude Code CLI가 설치되고 로그인된 상태여야 함

### API 엔드포인트

| 용도 | 엔드포인트 |
|------|-----------|
| Pro 사용량 | `GET https://api.anthropic.com/api/oauth/usage` |
| 토큰 갱신 | `POST https://platform.claude.com/v1/oauth/token` |
| OTel 메트릭 | `GET http://localhost:9464/metrics` (선택) |

Usage API 요청 시 반드시 헤더 `anthropic-beta: oauth-2025-04-20` 포함 필요.

### 핵심 모델 (`Core/UsageModel.swift`)

- `ClaudeUsageData`: 5시간/7일/7일Sonnet 사용량 스냅샷
- `RateWindow`: 사용률(%), 리셋 시각, 카운트다운 포함 단위 창
- `CodeUsageMetrics`: Claude Code CLI OTel 텔레메트리
- `ClaudeUsageError`: Keychain/인증/API 오류 열거형

## OTel 메트릭 활성화 (선택)

Claude Code CLI에서 아래 환경 변수 설정 시 토큰/비용/세션 수치가 메뉴바에 표시됨:

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=prometheus
```

## 개발 환경 요구사항

- macOS 14+ (Sonoma)
- Xcode 15+ (Swift 5.9+)
- Claude Code CLI 로그인 상태
