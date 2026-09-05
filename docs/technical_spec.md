# KC DeepL Technical Specification

## 1. 프로젝트 형태

- 빌드 시스템: Swift Package Manager
- 실행 타깃: `KCDeepL`
- 공용 코어 타깃: `KCDeepLCore`
- 테스트 타깃: `KCDeepLCoreTests`, `KCDeepLAppTests`
- 최소 OS: macOS 14
- UI: SwiftUI
- PDF/OCR: PDFKit + Vision + CoreText
- Typography: bundled Barlow + Noto Sans KR + D2Coding, CoreText process registration
- Apple 기기 내 번역: Translation 프레임워크(macOS 15+, weak-linked)
- 네트워크: `URLSession`
- 로컬 LLM 연결: 설치된 Codex의 JSONL stdio App Server
- 일반 설정 및 기존 텍스트/Live API 키 저장: `UserDefaults` + `@AppStorage` (파일 번역 키는 비영구 메모리 상태)
- 번역 기록 저장: Application Support의 `KCDeepL/translation-history.json`
- Codex 전용 작업 폴더: Application Support의 `KCDeepL/CodexTranslation`
- 로컬 개발 서명: `Apple Development`
- 직접 배포 서명: `Developer ID Application` + Hardened Runtime + timestamp

## 2. 모듈 구조

```text
Sources/
  App/
    App/
      KCDeepLApp.swift
      AppDelegate.swift
    Views/
      ContentView.swift
      FileTranslationWorkspace.swift
      SettingsView.swift
      TranslationComparisonView.swift
    Services/
      AppleDocumentTranslationClient.swift
      CodexAppServerTransport.swift
      PDFDocumentAnalysisService.swift
      PDFDocumentCompositionService.swift
      PDFDocumentTranslationModels.swift
    Support/
      AppFont.swift
      AppResourceLocator.swift
      FileTranslationOutputURLResolver.swift
      FileTranslationViewModel.swift
      Theme.swift
      TranslationComparisonViewModel.swift
      TranslationViewModel.swift
  KCDeepLCore/
    AppDefaults.swift
    DocumentPageTranslation.swift
    FileTranslationEngine.swift
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

### 2.1 글꼴 리소스와 등록

`Resources/Fonts`에는 수정하지 않은 정적 Barlow Regular/Italic/SemiBold/SemiBoldItalic, Noto Sans CJK KR Regular/Bold, D2Coding Regular/Bold와 각 OFL 전문을 포함한다. `AppFontRegistry`는 SwiftPM `Bundle.module`을 우선해 파일을 찾고 CoreText `.process` scope로 최초 한 번만 등록한다. 등록 결과는 thread-safe한 immutable static으로 캐시하며 개별 파일 실패는 앱 시작을 중단하지 않고 시스템 글꼴 fallback으로 이어진다. `AppFont`는 SwiftUI와 AppKit의 정책을 한곳에 두고 Barlow descriptor가 Noto Sans KR로 cascade되도록 해 혼합 영문/한글 문자열의 run별 주력 글꼴을 유지하며 마크다운 이탤릭도 실제 Barlow 정적 face로 보존한다. 코드·고정폭 경로는 D2Coding을 명시적으로 선택한다. 정확한 upstream commit과 SHA-256은 `Resources/Fonts/NOTICE.md`에 고정한다.

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
| `kc.files.translationEngine` | `apple` | PDF 파일 번역 엔진 |
| `kc.files.apiModelID` | `gemini-2.5-flash-lite` | PDF Gemini API 모델 |
| `kc.files.downloadLocation` | `desktop` | PDF 출력 기본 위치 |
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

요청 본문은 번역 정책을 `systemInstruction`에, 원문을 `contents[]`의 user part에 분리하고 `generationConfig.temperature`, `maxOutputTokens`를 전달한다. 일반 텍스트 요청 제한 시간은 30초이고 파일 번역은 조밀한 한 페이지 응답을 위해 120초를 허용한다. 선택 가능한 안정 Gemini 2.5 모델의 공식 출력 한도에 맞춰 최대 65,536토큰을 요청하되, 응답이 잘리면 부분 결과를 쓰지 않는다. 429와 선택된 5xx 응답은 취소 가능한 bounded backoff로 최대 두 번 재시도한다.

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

### 4.4 번역비교

상단의 `번역비교` 모드는 동일한 원문과 언어 설정으로 다음 모델을 고정 순서로 요청한다.

1. `gpt-5.6-sol`
2. `gpt-5.6-terra`
3. `gpt-5.6-luna`
4. `gpt-5.5`
5. `gpt-5.4`
6. `gpt-5.4-mini`
7. `gpt-5.3-codex-spark`

실행 전에 App Server의 `model/list`와 대조하여 없는 모델은 해당 탭에 사용 불가 상태로 표시한다. 사용 가능한 모델은 고정 `KC DeepL 번역` 작업의 turn 충돌을 피하도록 순차 실행하고, 개별 실패는 그 탭에만 표시한 뒤 다음 모델을 계속 처리한다. 원문 또는 언어가 바뀌거나 모드를 벗어나면 현재 비교를 취소하며 늦게 도착한 결과를 무시한다.

성공 결과는 탭별로 독립 보관하고 기록 설정이 켜져 있으면 각 결과를 `codexAppServer` 엔진과 실제 모델 ID로 로컬 기록에 추가한다.

## 5. PDF 파일 번역

### 5.1 분석과 위치 기억

`PDFDocumentAnalysisService`는 입력 확장자와 PDF 헤더를 확인하고 PDFKit으로 문서를 연다. 잠금, 변경/주석 금지, 전자 서명이 있는 문서는 원본 무결성을 위해 거부한다. PDFKit 재직렬화로 widget appearance가 사라질 수 있는 입력형 AcroForm PDF도 손상된 결과를 만들지 않고 거부하며 평면화한 사본 사용을 안내한다. 각 페이지에서 다음 정보를 불변 값으로 수집한다.

- media/crop/bleed/trim/art box의 effective bounds, 회전
- 텍스트 줄의 문자열, PDF 페이지 좌표, 글꼴 이름/크기, 전경색
- 주변 픽셀에서 추정한 배경색과 왼쪽/가운데/오른쪽 정렬
- 공간 읽기 순서, 열, 추출 출처(native 또는 Vision OCR)
- 인접 줄을 보수적으로 묶은 문단 블록

ID는 페이지 인덱스, 정규화한 좌표, 텍스트 등으로 결정적으로 생성한다. 같은 입력을 다시 분석하면 같은 페이지/블록/줄 ID가 만들어지며, 이 ID가 번역 결과를 원래 좌표로 돌려보내는 키다.

0/90/180/270도 페이지에서 Vision OCR을 실행한다. `PDFPage.transform(for: .cropBox)`로 page-to-display 변환과 표준화한 display bounds를 구하고, display 비율로 thumbnail 해상도를 결정한다. Vision의 lower-left 정규화 바운딩 박스를 display 좌표로 확장한 뒤 역변환하여 원래 crop box와 교차시킨다. 허용 각도, 유한 좌표, 행렬 determinant, display 비율, crop 교차 guard를 모두 통과한 결과만 사용한다. PDFKit 텍스트가 있으면 좌표 중첩과 정규화한 문자열로 OCR 중복을 제거하고 이미지 안에서만 발견한 문장을 보충하며, 텍스트 레이어가 없으면 OCR 결과 전체를 사용한다. 배경 샘플링은 Device RGB context에서 PDFKit의 표시 변환을 역상쇄해 같은 page-space를 사용한다. guard 실패, OCR 실패·낮은 신뢰도, 텍스트 미검출은 추측 배치하지 않고 경고하며 사용자가 누락 가능성을 명시적으로 확인하기 전에는 엔진 호출을 시작하지 않는다.

합성 preflight는 모든 페이지 회전이 정확히 0°/90°/180°/270° 중 하나이고 MediaBox의 minX/minY가 허용 오차 내 (0, 0)인지 검사한다. 조건을 벗어나면 원격·유료 번역 엔진 호출 전에 명시적으로 실패하며 목적지 파일을 만들지 않는다. CropBox 원점은 0이 아니어도 지원한다.

PDFKit은 90°/270° 대상 페이지에 FreeText를 바로 추가하면 회전된 display rectangle 폭으로 줄바꿈한다. 이를 피하기 위해 원본 페이지 뒤에 같은 media/crop/bleed/trim/art box를 가진 임시 0° carrier page를 target별로 하나씩 추가하고, 모든 글꼴·색·정렬·표시/인쇄·URL action을 확정한 FreeText를 carrier에 배치한다. 문서 전체를 메모리에서 한 번 직렬화하고 다시 연 뒤 `hasAppearanceStream`, bounds, 내용과 속성을 확인한다. 그 reopened 문서 안에서 carrier의 동일 annotation 객체를 remove하고 원래 target page에 add한 다음 carrier를 역순으로 제거한다. 이 이동 뒤에는 appearance를 무효화할 수 있는 속성 변경을 하지 않는다. 다른 문서로 detach/copy하면 appearance resource 참조가 끊길 수 있으므로 금지한다. 최종 직렬화·재개방에서도 원래 page count/box/회전과 moved appearance를 다시 검사한다.

### 5.2 페이지 단위 번역 계약

`DocumentPageTranslationRequest`는 한 페이지의 모든 문단 블록과 안정적인 ID를 담는다. Gemini/Codex 경로는 이 블록들을 하나의 XML envelope로 직렬화해 한 번 호출하므로 모델이 페이지 전체 문맥과 블록 경계를 함께 본다. XML parser는 외부 entity를 사용하지 않으며 응답의 페이지, ID 집합, 중복, 누락, 알 수 없는 ID, 빈 번역을 엄격히 검사한다.

Apple 경로도 같은 XML envelope 전체를 하나의 `TranslationSession.Request`로 전달해 블록 간 페이지 문맥을 한 번에 번역한다. 응답의 page `clientIdentifier`와 envelope 내부 블록 ID를 모두 검사하며 Apple 엔진이 마커를 변경하면 위치를 추측하지 않고 실패한다. `LanguageAvailability`와 `prepareTranslation()`으로 언어 지원/다운로드 상태를 확인하고 macOS 14에서는 해당 선택을 비활성화한다. 세 엔진 모두 페이지를 순차 처리하고 페이지별 결과를 전부 검증한 뒤에만 합성을 시작한다.

### 5.3 비파괴 합성

`PDFDocumentCompositionService`는 원본 `sourceData`에서 새 `PDFDocument`를 열어 원본 content stream을 변경하지 않는다. 각 원문 줄 위에 다음 printable annotation을 추가한다.

1. 주변에서 추정한 배경색의 사각형 마스크
2. 원래 정렬과 전경색을 따르는 free-text 번역 주석

CoreText로 원래 크기부터 최소 5pt까지 맞추고 대상 문자의 glyph를 모두 지원하는 serialization-stable 공개 글꼴만 선택한다. 전체 번역 glyph를 지원하는 신뢰 가능한 공개 원본 글꼴은 원래 line metrics 보존을 위해 우선하고, private dot-prefixed 시스템 이름과 PDFKit이 Times로 대체한 private SF 리소스는 제외한다. 원본 글꼴을 쓸 수 없으면 라틴은 Barlow, 한글은 Noto Sans KR, 고정폭은 D2Coding을 선택하며 일본어 가나는 Hiragino, 한자 중심 중국어는 PingFang SC/TC 공개 이름으로 분기한다. 동적 private fallback은 재개방 시 Times로 대체될 수 있어 PDF 직렬화 후보로 쓰지 않는다.

레이아웃 피팅은 글자를 가로로 비율 변환하지 않는다. 원문 glyph를 지우는 마스크는 `sourceMaskBounds`에만 남기고, 번역문 컨테이너는 같은 감지 열(column)의 안전한 오른쪽 경계까지 확장한다. 따라서 짧은 영문 glyph 박스에 긴 한글을 억지로 넣어 5pt로 축소하지 않고, 원래 시작점·정렬·줄 높이를 유지한 채 사용 가능한 여백을 먼저 사용한다. 가운데 정렬 제목은 페이지/열 중심을 고정하고, 90°/270° 페이지는 기존 carrier appearance 경로를 위해 원래 bounds를 유지한다. 최소 크기에서도 들어가지 않거나 표시할 수 없는 문자가 있으면 조용히 잘라내지 않고 출력 전체를 실패시킨다.

PDFKit이 줄바꿈 continuation을 서로 다른 font resource로 내보내는 경우에도 같은 크기·색·열·수직 간격이면 하나의 문단 블록으로 묶는다. 폭이 넓어 페이지 전체 후보로 분류된 목록 줄과 들여쓴 continuation 줄도 목록 기호·수직 간격·좌측 시작점이 이어지면 하나의 블록으로 다시 연결한다. 따라서 FAQ의 `... Public`/`Cloud?` 또는 `... customer data`/`across borders ...`가 서로 다른 번역 단위로 분리되지 않는다. 새 목록 기호로 시작하는 줄은 별도 블록으로 남겨 bullet/번호 위치를 보존한다. PDFKit이 Word 문단 스타일을 모든 glyph run에 잘못 복사해 `right`를 보고하더라도 실제 glyph 좌표와 열 경계가 정렬의 기준이다. 목록 기호로 시작하는 블록과 그 continuation은 항상 같은 왼쪽 기준을 사용하므로 긴 문장이 우연히 페이지 중앙에 걸쳐 보여도 가운데 정렬로 이동하지 않는다. 번역기가 구버전 방식으로 줄별 결과를 반환해도 모든 블록 줄의 결과를 합쳐 같은 reflow 경로로 보정한다. 블록 번역 결과는 원문 glyph 폭의 문자 수 비례가 아니라 실제 Barlow/Noto Sans KR/D2Coding glyph advance를 측정해 각 줄의 확장된 컨테이너에 greedy reflow하며, 공백 경계가 있으면 단어 단위로 끊고 한국어·URL처럼 공백이 없는 문자열은 glyph 단위로 안전하게 끊는다. 모델이 삽입한 줄바꿈은 원문 glyph-wrap을 의미하지 않으므로 평탄화하고, 끝의 물음표·마침표 같은 1–2자 구두점만 단독 continuation 줄에 남지 않도록 앞 chunk에 붙인다. 최소 크기에서도 들어가지 않거나 표시할 수 없는 문자가 있으면 조용히 잘라내지 않고 출력 전체를 실패시킨다.

출력은 원본과 다른 임시 URL에서 직렬화하고 다시 열어 다음을 검증한 뒤 최종 URL로 move한다.

- 페이지 수, media/crop/bleed/trim/art box의 effective bounds, 회전
- 원래 있던 일반 주석과 링크의 URL/action identity, appearance stream 존재 여부, 색·내부색·border·표시/인쇄와 적용 가능한 FreeText 글꼴/색/정렬
- 예상한 마스크/번역 주석의 subtype, bounds, 내용, 마스크/글자 색, 정렬, 글꼴 크기와 대상 glyph, 표시/인쇄 속성, URL action

원문 링크와 줄 영역이 유의미하게 겹치면 분석 경고로 사용자 확인을 요청한다. 합성 preflight는 실제 expanded overlay와 모든 기존 주석이 양의 면적으로 조금이라도 겹치는지 더 엄격하게 검사한다. 정확히 하나의 URL Link이면 action을 마스크와 free-text 주석에도 복제해 위쪽 overlay에서도 클릭할 수 있게 하고, 저장 후 원본 링크 fingerprint와 overlay URL action을 모두 재검증한다. 복수 URL 또는 GoTo/Named/Remote action이거나 Link가 아닌 highlight/underline/strikeout/ink/stamp/text/freeText 등의 기존 주석이면 표시와 상호작용 보존을 보장할 수 없어 번역 엔진 호출 전에 전체 작업을 실패시킨다. 복잡하거나 추정 불가능한 배경도 같은 preflight에서 실패시켜 대표색/흰색 마스크로 문서를 훼손하지 않는다.

최종 파일 이름은 `<원본>.<대상언어>.translated.pdf`이며 기존 파일과 충돌하면 번호를 붙인다. 원본 경로와 같은 출력, 기존 목적지 덮어쓰기, 부분 출력은 허용하지 않는다. URL 결정 직후 목적지 부모에 UUID 이름의 0바이트 probe 파일을 `.withoutOverwriting`으로 만들고 즉시 삭제해 현재 쓰기 권한을 번역 엔진 호출 전에 확인한다. 이 검사는 이후 권한 변경에 대한 보장이 아니므로 최종 합성도 소유권이 명확한 UUID 임시 파일을 검증한 뒤 atomic move하며 TOCTOU 실패를 안전하게 처리한다. 분석/번역/합성 작업은 generation과 Swift cancellation을 확인해 취소되거나 교체된 작업이 UI나 파일에 남지 않도록 한다. 파일 번역 화면에서 입력한 Gemini API 키는 SwiftUI 상태 메모리에만 두고 `UserDefaults`에 쓰지 않는다.

원본 객체를 보존하는 이 방식은 지원 PDF에서 가장 안전한 레이아웃 보존 전략이지만 번역문 길이 변화, 원본 subset 글꼴, 복잡한 배경, OCR 오인식 때문에 픽셀 단위 100% 동일한 결과를 일반적으로 보장할 수 없다. 재개방 검사는 `출력 PDF 구조 재검증 완료`를 뜻하며 임의 이미지·표·벡터가 픽셀 단위로 같다는 검증은 아니다. 원문 content stream을 삭제하지 않으므로 검색·복사·VoiceOver·tagged PDF 구조에 원문이 남고, 주석을 숨기는 뷰어나 인쇄 설정에서는 원문이 보일 수 있다. UI는 이 접근성·상호운용 제약을 명시한다.

## 6. 실시간 오디오 안정성

이 절의 Gemini Live 동작은 텍스트 번역 백엔드 선택의 영향을 받지 않는다.

- 입력 PCM: 16kHz mono, 100ms 청크
- 출력 PCM: 24kHz mono
- 네트워크 송신: 최대 약 1초의 bounded queue, 지연 시 가장 오래된 미전송 음성 폐기
- 출력 재생: 최대 2초 버퍼, 초과 시 새 청크 거부
- By Pass: 20ms 청크, 최대 0.5초 버퍼
- 연결은 방향별 generation으로 식별하여 OFF/재시작 뒤 늦게 끝난 연결을 폐기한다.
- setup timeout, receive 종료, 송신 실패, event overflow는 terminal 오류로 처리하고 오디오/UI를 함께 정리한다.
- Live 화면을 벗어나거나 앱이 종료되면 캡처, By Pass, WebSocket을 먼저 정지해 백그라운드 마이크 사용과 API 소비를 막는다.

## 7. UI 구성

메인 창:

- 상단 모드 바: 텍스트 번역, 번역비교, Live 번역, 파일 번역, 기록
- 언어 바: 원문 언어, 전환 버튼, 대상 언어
- 작업 영역: 왼쪽 입력, 오른쪽 결과
- 하단 상태 바: 보안/상태/보조 아이콘
- 오른쪽 패널: 최근 기록
- 파일 번역: PDF 선택/드롭, 원본·번역본 PDFKit 미리보기, 언어·엔진·모델, 출력 위치, 분석/OCR 경고, 진행률/취소, 결과 열기

설정 창:

- `Settings` 씬으로 분리
- 왼쪽 카테고리 사이드바
- 카테고리별 상세 설정
- **LLM 번역**에 `LLM API 사용` / `Codex App Server 사용` 번역 방식 picker 제공
- LLM API 선택 시 기존 공급자/API 키/세부 모델/temperature 설정 제공
- Codex App Server 선택 시 `model/list`에서 동적으로 받은 모델 picker 제공
- **LLM Live** 설정과 동작은 텍스트 백엔드 선택과 분리

## 8. 화면 캡처 설계

화면 캡처는 아직 지원하지 않는다. 캡처 버튼, 목업 시트, 메뉴와 전역 단축키를 노출하지 않으며, 안내 문구를 원문에 삽입하지 않는다.

다음 구현:

- `ScreenCaptureKit` 또는 `CGWindowListCreateImage` 기반 캡처
- macOS Screen Recording 권한 체크
- Vision `VNRecognizeTextRequest` OCR
- OCR 결과를 원문 필드에 삽입 후 자동 번역

## 9. 테스트 전략

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
- 번역비교 모델 순서, 순차 실행, 부분 실패 지속 검증
- 번역 기록의 엔진/공급자/모델 직렬화와 구버전 기록 호환 검증
- Live transcript 언어 라우팅, 증분 조립, 문장 분할 회귀 검증
- 파일 기반 번역 기록 저장/로드 검증
- 초기 비동기 load와 종료 flush의 merge 검증
- 페이지 XML envelope escape/parse와 정확한 ID 집합/순서 검증
- Apple batch clientIdentifier 매핑, 언어 코드/중국어 script 매핑 검증
- PDF 디지털 텍스트 열 순서/안정 ID와 Vision OCR fallback 검증
- PDF 페이지 media/crop/bleed/trim/art box·회전·기존 일반 주석 appearance stream과 overlay bounds/색/정렬/표시·인쇄/대상 glyph 보존, 입력형 양식 및 non-Link 주석 중첩 거부, 90°/270° carrier appearance와 비지원 MediaBox/회전 preflight 실패 검증
- PDF 원본·기존 목적지 보호, 번역 누락/overflow/서명/잠금 실패 검증
- 파일 ViewModel의 엔진 라우팅, 페이지 순차 처리, 취소/늦은 응답 배제 검증

추가 권장:

- 실제 설치된 Codex 로그인으로 opt-in App Server smoke test
- 번역 기록 저장/삭제 검증
- OCR 권한 상태별 UI 검증

번역 기록과 Live 대화 기록은 Application Support에 atomic JSON으로 저장하며 현재 암호화하지 않는다. 앱 수명의 단일 ViewModel이 actor 저장소를 소유하고 빠른 연속 변경을 합쳐 MainActor의 파일 I/O를 피한다. 종료 시 신규 번역·Live 이벤트를 먼저 중단하고 초기 load를 기다린 뒤, generation이 안정될 때까지 최신 snapshot을 직렬 저장한다.

번역 기록은 원문과 결과를 생략하지 않고 스크롤 가능한 기록 화면에 모두 표시한다. 신규 기록은 `backend`, API 경로의 `provider`, `modelID`를 저장하며, 기존 JSON과 호환되도록 새 엔진 필드는 optional로 decode한다.

## 10. macOS 서명

`script/build_and_run.sh`의 기본 실행과 `--verify`는 디버깅 가능한 `Apple Development` 서명을 유지한다. `--release`는 Release 바이너리를 빌드하고 `Developer ID Application` 인증서로 서명하며 다음 배포 보호를 적용한다.

- Hardened Runtime
- Apple 보안 timestamp
- `com.apple.security.device.audio-input` entitlement
- Team ID와 서명 Authority 명시적 검증

일반 Developer ID 직접 배포에는 고급 capability를 사용하지 않는 한 별도 프로비저닝 프로파일을 embed하지 않는다. 외부 배포 파일은 Apple notarization 제출과 stapling을 추가로 완료해야 Gatekeeper 검증이 완성된다.
