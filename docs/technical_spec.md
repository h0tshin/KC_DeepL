# KC DeepL Technical Specification

## 1. 프로젝트 형태

- 빌드 시스템: Swift Package Manager
- 실행 타깃: `KCDeepL`
- 공용 코어 타깃: `KCDeepLCore`
- 테스트 타깃: `KCDeepLCoreTests`
- 최소 OS: macOS 14
- UI: SwiftUI
- 네트워크: `URLSession`
- 설정 저장: `UserDefaults` + `@AppStorage`

## 2. 모듈 구조

```text
Sources/
  App/
    App/
      KCDeepLApp.swift
      AppDelegate.swift
    Views/
      ContentView.swift
      SettingsView.swift
    Support/
      Theme.swift
      TranslationViewModel.swift
  KCDeepLCore/
    AppDefaults.swift
    GeminiResponseParser.swift
    GeminiTranslationClient.swift
    LanguageOption.swift
    LLMProvider.swift
    TranslationHistoryItem.swift
    TranslationPromptBuilder.swift
    TranslationRequest.swift
```

## 3. 설정 모델

기본 설정은 `UserDefaults.registerKCDeepLDefaults()`에서 등록한다.

| 키 | 기본값 | 목적 |
| --- | --- | --- |
| `kc.advanced.provider` | `gemini` | LLM 공급자 |
| `kc.advanced.modelID` | `gemini-2.5-flash-lite` | 세부 모델 |
| `kc.advanced.geminiAPIKey` | 사용자 지정 기본 키 | Gemini API key |
| `kc.advanced.autoTranslate` | `true` | 자동 번역 설정 |
| `kc.advanced.temperature` | `0.2` | 번역 안정성 |
| `kc.files.historyEnabled` | `true` | 로컬 기록 저장 |

보안 개선 계획: API 키는 초기 요구에 따라 기본 저장되지만, 실제 배포 전 Keychain 저장소로 이전한다.

## 4. 번역 호출

`GeminiTranslationClient`는 다음 엔드포인트를 호출한다.

```http
POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
x-goog-api-key: <api-key>
Content-Type: application/json
```

요청 본문은 `contents[]`에 번역 프롬프트를 넣고 `generationConfig.temperature`, `maxOutputTokens`를 전달한다.

오류 처리:

- 빈 입력: `TranslationClientError.emptyInput`
- API 키 없음: `TranslationClientError.missingAPIKey`
- 잘못된 URL: `TranslationClientError.invalidURL`
- HTTP 실패: `TranslationClientError.badStatus`
- 응답 파싱 실패 또는 후보 없음: `TranslationClientError.emptyResponse`

응답 파서는 현재 Gemini `generateContent`의 `candidates[].content.parts[].text`와 일부 호환 응답의 `output_text`를 함께 처리한다.

## 5. UI 구성

메인 창:

- 상단 모드 바: 텍스트 번역, 글 작성, 파일 번역, 기록
- 언어 바: 원문 언어, 전환 버튼, 대상 언어
- 작업 영역: 왼쪽 입력, 오른쪽 결과
- 하단 상태 바: 보안/상태/보조 아이콘
- 오른쪽 도구 패널: 편집 도구와 최근 기록

설정 창:

- `Settings` 씬으로 분리
- 왼쪽 카테고리 사이드바
- 카테고리별 상세 설정
- 고급 탭에 LLM 공급자/API 키/세부 모델/temperature 포함

## 6. 화면 캡처 설계

초기 구현:

- 입력 패널 하단의 캡처 버튼 제공
- 선택 영역 목업 시트 표시
- 캡처 완료 시 원문 필드에 캡처 안내 문구 삽입

다음 구현:

- `ScreenCaptureKit` 또는 `CGWindowListCreateImage` 기반 캡처
- macOS Screen Recording 권한 체크
- Vision `VNRecognizeTextRequest` OCR
- OCR 결과를 원문 필드에 삽입 후 자동 번역

## 7. 테스트 전략

현재 테스트:

- 번역 프롬프트가 언어와 원문을 포함하는지 검증
- 기본 Gemini 설정 등록 검증
- Gemini 응답 파싱 검증
- 빈 응답 오류 검증

추가 예정:

- `URLProtocol` 기반 네트워크 mock
- 설정 변경 시 모델 목록 동기화 검증
- 번역 기록 저장/삭제 검증
- OCR 권한 상태별 UI 검증
