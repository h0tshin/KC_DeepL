# KC DeepL Technical Specification

## 1. 프로젝트 형태

- 빌드 시스템: Swift Package Manager
- 실행 타깃: `KCDeepL`
- 공용 코어 타깃: `KCDeepLCore`
- 테스트 타깃: `KCDeepLCoreTests`, `KCDeepLAppTests`
- 최소 OS: macOS 14
- UI: SwiftUI
- 네트워크: `URLSession`
- 설정 및 API 키 저장: `UserDefaults` + `@AppStorage`
- 번역 기록 저장: Application Support의 `KCDeepL/translation-history.json`

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
    TranslationHistoryStore.swift
    TranslationPromptBuilder.swift
    TranslationRequest.swift
```

## 3. 설정 모델

기본 설정은 `UserDefaults.registerKCDeepLDefaults()`에서 등록한다.

| 키 | 기본값 | 목적 |
| --- | --- | --- |
| `kc.main.sourceLanguage` | `en` | 메인 번역 원문 언어 |
| `kc.main.targetLanguage` | `ko` | 메인 번역 대상 언어 |
| `kc.advanced.provider` | `gemini` | LLM 공급자 |
| `kc.advanced.modelID` | `gemini-2.5-flash-lite` | 세부 모델 |
| `kc.advanced.geminiAPIKey` | 등록하지 않음 | 사용자가 입력한 Gemini API 키 |
| `kc.advanced.autoTranslate` | `true` | 자동 번역 설정 |
| `kc.advanced.temperature` | `0.2` | 번역 안정성 |
| `kc.files.historyEnabled` | `true` | 로컬 기록 저장 |

API 키는 기본값을 제공하지 않는다. 사용자가 설정 화면에서 입력한 텍스트/Live 키는 다른 일반 설정과 동일하게 `UserDefaults`에 평문으로 저장한다.

## 4. 번역 호출

`GeminiTranslationClient`는 다음 엔드포인트를 호출한다.

```http
POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
x-goog-api-key: <api-key>
Content-Type: application/json
```

요청 본문은 번역 정책을 `systemInstruction`에, 원문을 `contents[]`의 user part에 분리하고 `generationConfig.temperature`, `maxOutputTokens`를 전달한다. 요청 제한 시간은 30초이며 429와 선택된 5xx 응답은 취소 가능한 bounded backoff로 최대 두 번 재시도한다.

오류 처리:

- 빈 입력: `TranslationClientError.emptyInput`
- API 키 없음: `TranslationClientError.missingAPIKey`
- 잘못된 URL: `TranslationClientError.invalidURL`
- HTTP 실패: `TranslationClientError.badStatus`
- 응답 파싱 실패 또는 후보 없음: `TranslationClientError.emptyResponse`

응답 파서는 현재 Gemini `generateContent`의 `candidates[].content.parts[].text`와 일부 호환 응답의 `output_text`를 함께 처리한다.

## 5. 실시간 오디오 안정성

- 입력 PCM: 16kHz mono, 100ms 청크
- 출력 PCM: 24kHz mono
- 네트워크 송신: 최대 약 1초의 bounded queue, 지연 시 가장 오래된 미전송 음성 폐기
- 출력 재생: 최대 2초 버퍼, 초과 시 새 청크 거부
- By Pass: 20ms 청크, 최대 0.5초 버퍼
- 연결은 방향별 generation으로 식별하여 OFF/재시작 뒤 늦게 끝난 연결을 폐기한다.
- setup timeout, receive 종료, 송신 실패, event overflow는 terminal 오류로 처리하고 오디오/UI를 함께 정리한다.
- Live 화면을 벗어나거나 앱이 종료되면 캡처, By Pass, WebSocket을 먼저 정지해 백그라운드 마이크 사용과 API 소비를 막는다.

## 6. UI 구성

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

## 7. 화면 캡처 설계

초기 구현:

- 입력 패널 하단의 캡처 버튼 제공
- 선택 영역 목업 시트 표시
- 캡처 완료 시 원문 필드에 캡처 안내 문구 삽입

다음 구현:

- `ScreenCaptureKit` 또는 `CGWindowListCreateImage` 기반 캡처
- macOS Screen Recording 권한 체크
- Vision `VNRecognizeTextRequest` OCR
- OCR 결과를 원문 필드에 삽입 후 자동 번역

## 8. 테스트 전략

현재 테스트:

- 번역 프롬프트가 언어와 원문을 포함하는지 검증
- 기본 Gemini 설정 등록 검증
- URLProtocol 기반 Gemini 성공, 오류, 재시도, 취소 검증
- Gemini 차단, 안전성, 출력 잘림 응답 파싱 검증
- Live transcript 언어 라우팅, 증분 조립, 문장 분할 회귀 검증
- 파일 기반 번역 기록 저장/로드 검증
- 초기 비동기 load와 종료 flush의 merge 검증

추가 권장:

- 설정 변경 시 모델 목록 동기화 검증
- 번역 기록 저장/삭제 검증
- OCR 권한 상태별 UI 검증

번역 기록과 Live 대화 기록은 Application Support에 atomic JSON으로 저장하며 현재 암호화하지 않는다. 앱 수명의 단일 ViewModel이 actor 저장소를 소유하고 빠른 연속 변경을 합쳐 MainActor의 파일 I/O를 피한다. 종료 시 신규 번역·Live 이벤트를 먼저 중단하고 초기 load를 기다린 뒤, generation이 안정될 때까지 최신 snapshot을 직렬 저장한다.
