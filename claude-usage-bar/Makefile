APP_NAME     = Claude UsageBar
BINARY_NAME  = ClaudeUsageBar
BUNDLE_ID    = com.claudeusagebar.app
INSTALL_DIR  = $(HOME)/Applications
APP_BUNDLE   = $(INSTALL_DIR)/$(APP_NAME).app
BINARY_SRC   = .build/release/$(BINARY_NAME)
ICON_SRC     = Resources/icon.png
ICONSET_DIR  = /tmp/AppIcon.iconset
ICNS_FILE    = /tmp/AppIcon.icns
# 빌드 간 코드서명 일관성을 위해 Apple Developer 인증서 사용.
# 인증서가 없으면 ad-hoc(-) 서명으로 자동 폴백된다.
# 환경 변수 또는 Makefile.local에서 오버라이드 가능 (개인정보 보호).
CERT_NAME    ?= $(CODESIGN_CERT_NAME)
ENTITLEMENTS = ClaudeUsageBar.entitlements

# Makefile.local이 존재하면 로드하여 CERT_NAME 등을 오버라이드한다.
-include Makefile.local

# ─── 기본 타겟 ────────────────────────────────────────────

.PHONY: all build install update uninstall run clean help _icon _codesign

all: help

## 도움말 출력
help:
	@echo ""
	@echo "Claude UsageBar — Claude 사용량 메뉴바 앱"
	@echo ""
	@echo "  make install         빌드 후 ~/Applications 에 설치 (최초 1회)"
	@echo "  make update          재빌드 후 기존 설치 업데이트"
	@echo "  make run             빌드 후 터미널에서 직접 실행 (개발용)"
	@echo "  make uninstall       ~/Applications 에서 삭제"
	@echo "  make clean           빌드 캐시 삭제"
	@echo ""

# ─── 빌드 ────────────────────────────────────────────────

## 릴리즈 바이너리 빌드
build:
	@echo "▶ 빌드 중..."
	@swift build -c release
	@echo "✓ 빌드 완료: $(BINARY_SRC)"

# ─── 공통 내부 타겟 ──────────────────────────────────────

## PNG → ICNS 변환 후 Resources 에 복사 (install, update 공용)
_icon:
	@echo "▶ 아이콘 변환 중..."
	@rm -rf "$(ICONSET_DIR)" && mkdir -p "$(ICONSET_DIR)"
	@sips -z 16   16   "$(ICON_SRC)" --out "$(ICONSET_DIR)/icon_16x16.png"      2>/dev/null
	@sips -z 32   32   "$(ICON_SRC)" --out "$(ICONSET_DIR)/icon_16x16@2x.png"   2>/dev/null
	@sips -z 32   32   "$(ICON_SRC)" --out "$(ICONSET_DIR)/icon_32x32.png"      2>/dev/null
	@sips -z 64   64   "$(ICON_SRC)" --out "$(ICONSET_DIR)/icon_32x32@2x.png"   2>/dev/null
	@sips -z 128  128  "$(ICON_SRC)" --out "$(ICONSET_DIR)/icon_128x128.png"    2>/dev/null
	@sips -z 256  256  "$(ICON_SRC)" --out "$(ICONSET_DIR)/icon_128x128@2x.png" 2>/dev/null
	@sips -z 256  256  "$(ICON_SRC)" --out "$(ICONSET_DIR)/icon_256x256.png"    2>/dev/null
	@sips -z 512  512  "$(ICON_SRC)" --out "$(ICONSET_DIR)/icon_256x256@2x.png" 2>/dev/null
	@sips -z 512  512  "$(ICON_SRC)" --out "$(ICONSET_DIR)/icon_512x512.png"    2>/dev/null
	@sips -z 1024 1024 "$(ICON_SRC)" --out "$(ICONSET_DIR)/icon_512x512@2x.png" 2>/dev/null
	@iconutil -c icns "$(ICONSET_DIR)" -o "$(ICNS_FILE)"
	@cp "$(ICNS_FILE)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@echo "✓ 아이콘 적용 완료"

## Apple Developer 인증서로 코드서명, 미존재 시 ad-hoc 폴백 (install, update 공용)
_codesign:
	@codesign --force --deep \
	    --sign "$(CERT_NAME)" \
	    --entitlements "$(ENTITLEMENTS)" \
	    "$(APP_BUNDLE)" 2>/dev/null || \
	  codesign --force --deep --sign - "$(APP_BUNDLE)" 2>/dev/null || true

# ─── 설치 ────────────────────────────────────────────────

## .app 번들 생성 후 ~/Applications 에 설치
install: build
	@echo "▶ 설치 중: $(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BINARY_SRC)" "$(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)"
	@cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@$(MAKE) _icon
	@$(MAKE) _codesign
	@echo ""
	@echo "✅ 설치 완료!"
	@echo ""
	@echo "실행 방법:"
	@echo "  open $(APP_BUNDLE)"
	@echo ""
	@echo "로그인 시 자동 실행 설정:"
	@echo "  시스템 설정 → 일반 → 로그인 항목 → Claude UsageBar 추가"
	@echo ""
	@open "$(APP_BUNDLE)"

## 재빌드 후 실행 중인 앱 교체 (업데이트)
update: build
	@echo "▶ 업데이트 중..."
	@pkill -x "$(BINARY_NAME)" 2>/dev/null || true
	@sleep 0.5
	@cp "$(BINARY_SRC)" "$(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)"
	@cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@$(MAKE) _icon
	@$(MAKE) _codesign
	@open "$(APP_BUNDLE)"
	@echo "✅ 업데이트 완료"

# ─── 실행 (개발용) ────────────────────────────────────────

## 빌드 후 터미널에서 직접 실행 (Dock에 표시될 수 있음)
run: build
	@echo "▶ 실행 중 (개발 모드)..."
	@"$(BINARY_SRC)"

# ─── 제거 ────────────────────────────────────────────────

## 설치된 앱 삭제
uninstall:
	@pkill -x "$(BINARY_NAME)" 2>/dev/null || true
	@rm -rf "$(APP_BUNDLE)"
	@echo "✅ 삭제 완료: $(APP_BUNDLE)"

# ─── 정리 ────────────────────────────────────────────────

## 빌드 캐시 삭제
clean:
	@rm -rf .build
	@echo "✅ 빌드 캐시 삭제 완료"
