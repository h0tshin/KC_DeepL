# KC DeepL Technical Specification

## 1. 프로젝트 형태

- 빌드 시스템: Swift Package Manager
- 실행 타깃: `KCDeepL`
- 공용 코어 타깃: `KCDeepLCore`
- 테스트 타깃: `KCDeepLCoreTests`, `KCDeepLAppTests`
- 최소 OS: macOS 14
- UI: SwiftUI
- 네트워크: `URLSession`
- 로컬 LLM 연결: 설치된 Codex의 JSONL stdio App Server
- 설정 및 API 키 저장: `UserDefaults` + `@AppStorage`
- 번역 기록 저장: Application Support의 `KCDeepL/translation-history.json`
- Codex 전용 작업 폴더: Application Support의 `KCDeepL/CodexTranslation`

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
    Services/
      CodexAppServerTransport.swift
    Support/
      Theme.swift
      TranslationViewModel.swift
  KCDeepLCore/
    AppDefaults.swift
    GeminiResponseParser.swift
    GeminiTranslationClient.swift
    LanguageOption.swift
    LLMProvider.swift
    TranslationBackend.swift
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
| `kc.advanced.translationBackend` | `llmAPI` | 텍스트 번역 경로 (`llmAPI` / `codexAppServer`) |
| `kc.advanced.provider` | `gemini` | LLM 공급자 |
| `kc.advanced.modelID` | `gemini-2.5-flash-lite` | 세부 모델 |
| `kc.advanced.codexModelID` | 빈 문자열 | Codex App Server에서 선택한 모델 ID |
| `kc.advanced.codexThreadID` | 등록하지 않음 | 재사용할 `KC DeepL 번역` Codex 작업 ID |
| `kc.advanced.geminiAPIKey` | 등록하지 않음 | 사용자가 입력한 Gemini API 키 |
| `kc.advanced.autoTranslate` | `true` | 자동 번역 설정 |
| `kc.advanced.temperature` | `0.2` | 번역 안정성 |
| `kc.files.historyEnabled` | `true` | 로컬 기록 저장 |

기존 API 동작을 바꾸지 않기 위해 텍스트 번역 백엔드의 등록 기본값은 `llmAPI`다. API 공급자, API 모델, API 키는 Codex 모델 및 작업 ID와 서로 다른 키에 저장하므로 백엔드를 왕복해도 각 선택이 유지된다. API 키는 기본값을 제공하지 않으며, 사용자가 설정 화면에서 입력한 텍스트/Live 키는 다른 일반 설정과 동일하게 `UserDefaults`에 평문으로 저장한다.

`kc.advanced.codexThreadID`는 고정 작업을 다시 찾기 위한 식별자일 뿐 대화 본문 저장소가 아니다. Codex 작업 대화 내역은 Codex가 관리하며, `kc.files.historyEnabled`가 제어하는 KC DeepL의 로컬 `translation-history.json`과 수명 주기 및 삭제 정책이 독립적이다.

## 4. 텍스트 번역 호출

### 4.1 백엔드 라우팅

메인 텍스트 번역 요청은 `TranslationBackend` 값으로 라우팅한다.

- `llmAPI`: 기존 `GeminiTranslationClient`와 기존 API 설정을 사용한다.
- `codexAppServer`: 공유 Codex App Server actor에 요청하고 선택한 Codex 모델과 고정 작업을 사용한다.

백엔드나 모델이 바뀌거나 더 최신 원문에 대한 자동 번역이 시작되면 진행 중인 이전 요청을 취소한다. 취소된 요청의 늦은 응답은 결과 패널과 로컬 기록에 반영하지 않는다. 이 선택은 텍스트 번역에만 적용하며 Gemini Live 번역의 연결, 모델, API 키, 오디오 경로는 변경하지 않는다.

### 4.2 LLM API

`GeminiTranslationClient`는 기존과 동일하게 다음 엔드포인트를 호출한다.

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

### 4.3 Codex App Server

Codex 경로는 이 Mac에 설치된 `codex` 실행 파일을 찾아 다음 장기 실행 자식 프로세스를 하나만 유지한다.

```bash
codex app-server --listen stdio://
```

프로세스는 기존 Codex 로그인 상태를 사용하므로 Gemini API 키와 별도의 Codex API 키 입력을 요구하지 않는다. 실행 시 shell/exec, 브라우저, 컴퓨터 제어, 앱/플러그인, 다중 에이전트, MCP, 웹 검색 기능을 비활성화해 번역 원문이 도구 실행을 유도하지 못하게 한다. 요청과 이벤트는 stdin/stdout의 JSONL RPC로 교환하고 stderr는 진단 메시지로 별도 수집한다. 프로세스가 종료되면 대기 중인 요청을 모두 명시적인 오류로 끝내며 앱 종료 시 프로세스도 정리한다.

초기화 후 `model/list`를 `nextCursor`가 끝날 때까지 조회하여 현재 설치된 Codex App Server가 제공하는 모델을 설정 picker에 표시한다. 목록을 하드코딩하지 않으며 선택한 모델 ID는 `kc.advanced.codexModelID`에 API 모델과 별도로 저장한다.

모든 번역은 이름이 정확히 `KC DeepL 번역`인 작업을 사용한다.

1. 저장된 `kc.advanced.codexThreadID`가 있으면 해당 작업을 resume한다.
2. 저장 ID가 없거나 유효하지 않으면 기존 고정 이름 작업을 찾거나 새 작업을 시작한다.
3. 새 작업은 이름을 `KC DeepL 번역`으로 지정하고 ID를 저장한다.
4. 작업 start/resume과 turn에는 `approvalPolicy: "never"`, `sandbox: "read-only"`를 적용하고 현재 작업 폴더를 `Application Support/KCDeepL/CodexTranslation`으로 고정한다.

원문과 목표 언어는 강한 번역 지침과 분리해 전달한다. `turn/start`에는 `{ "translation": string }`만 허용하는 엄격한 `outputSchema`를 지정한다. 스트리밍 delta는 진행 상태에만 사용할 수 있으며 번역 결과로 확정하지 않는다. `turn/completed` 뒤 완료된 agent message의 `phase == "final_answer"`를 우선 추출하고, 필요한 호환 경로에서만 마지막 phase 미지정 메시지를 사용한 뒤 schema를 JSON decode한다. 이렇게 얻은 `translation`만 기존 오른쪽 결과 패널과 로컬 기록 경로에 전달한다.

자동 번역 갱신, 수동 취소, 백엔드 변경 또는 앱 종료로 작업이 취소되면 active turn에 `turn/interrupt`를 보내고 terminal 이벤트를 확인한 뒤 다음 turn을 시작한다. 고정 작업에서 이전 turn이 활성 상태로 남아 새 원문과 섞이는 것을 방지한다.

Codex 작업에는 원문과 결과가 누적될 수 있다. 이는 KC DeepL의 로컬 번역 기록 저장 여부와 독립적이며, 전용 작업 폴더, 읽기 전용/무승인 정책, 도구 비활성화는 번역 요청이 사용자 프로젝트나 연결 서비스에 접근하지 않도록 실행 범위를 제한한다.

## 5. 실시간 오디오 안정성

이 절의 Gemini Live 동작은 텍스트 번역 백엔드 선택의 영향을 받지 않는다.

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
- **LLM 번역**에 `LLM API 사용` / `Codex App Server 사용` 번역 방식 picker 제공
- LLM API 선택 시 기존 공급자/API 키/세부 모델/temperature 설정 제공
- Codex App Server 선택 시 `model/list`에서 동적으로 받은 모델 picker 제공
- **LLM Live** 설정과 동작은 텍스트 백엔드 선택과 분리

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
- 기존 `llmAPI`/Gemini 기본 설정과 Codex 전용 설정 키 등록 검증
- URLProtocol 기반 Gemini 성공, 오류, 재시도, 취소 검증
- Gemini 차단, 안전성, 출력 잘림 응답 파싱 검증
- Codex JSONL partial/CRLF/복수 줄 framing과 최대 줄 크기 검증
- Codex 초기화, 페이지네이션 모델 목록, 고정 작업 resume/start 검증
- Codex turn 취소/interrupt와 terminal 이벤트 대기 검증
- Codex final output 선택, `{translation:string}` output schema, 정상 JSON decode 검증
- ViewModel의 백엔드 라우팅과 취소된 결과 배제 검증
- Live transcript 언어 라우팅, 증분 조립, 문장 분할 회귀 검증
- 파일 기반 번역 기록 저장/로드 검증
- 초기 비동기 load와 종료 flush의 merge 검증

추가 권장:

- 실제 설치된 Codex 로그인으로 opt-in App Server smoke test
- 번역 기록 저장/삭제 검증
- OCR 권한 상태별 UI 검증

번역 기록과 Live 대화 기록은 Application Support에 atomic JSON으로 저장하며 현재 암호화하지 않는다. 앱 수명의 단일 ViewModel이 actor 저장소를 소유하고 빠른 연속 변경을 합쳐 MainActor의 파일 I/O를 피한다. 종료 시 신규 번역·Live 이벤트를 먼저 중단하고 초기 load를 기다린 뒤, generation이 안정될 때까지 최신 snapshot을 직렬 저장한다.
