# KC DeepL Validation Plan

## 1. 정적 검증

- `swift test`
- `swift build`
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency`
- `swift build -Xswiftc -swift-version -Xswiftc 6`
- `./script/build_and_run.sh --release`
- `codesign --verify --deep --strict dist/KCDeepL.app`
- `codesign -dv --verbose=4 dist/KCDeepL.app`에서 Developer ID Authority, Team ID, runtime flag, timestamp 확인
- `codesign -d --entitlements - --xml dist/KCDeepL.app`에서 audio-input entitlement 확인
- 공증·stapling 후 `spctl -a -vv dist/KCDeepL.app`
- `git status --short`로 의도한 파일만 변경되었는지 확인

## 2. 앱 실행 검증

명령:

```bash
./script/build_and_run.sh --verify
```

확인 항목:

- 기존 `KCDeepL` 프로세스를 종료한 뒤 새 앱 번들을 실행한다.
- `pgrep -x KCDeepL`이 성공한다.
- `dist/KCDeepL.app`이 생성된다.

## 3. 메인 UI 체크리스트

- 상단 모드 바가 표시된다.
- `텍스트 번역` 바로 옆에 `번역비교`가 표시된다.
- 언어 선택 picker가 동작한다.
- 입력/결과 2패널이 동일한 높이로 표시된다.
- 빈 입력 상태에서 입력 힌트가 보인다.
- 입력 중에는 API 호출이 보류되고 1초 이상 휴지기가 생기면 자동 번역이 시작된다.
- 오른쪽 도구 패널을 열고 닫을 수 있다.
- 미구현 화면 캡처 버튼·메뉴·단축키가 노출되지 않고 원문에 목업 안내 문구가 삽입되지 않는다.
- 과거 설정의 미지원 API 공급자는 번역 결과 대신 오류를 표시하며, Apple 번역 결과는 정상적으로 사용할 수 있다.
- 선택한 텍스트 번역 백엔드의 성공 결과가 동일한 오른쪽 결과 패널에 표시된다.
- 번역비교 실행 시 SOL, Terra, Luna, 5.5, 5.4, 5.4 mini, 5.3 탭에 각 상태와 결과가 표시된다.

## 4. 설정 UI 체크리스트

- 톱니바퀴 버튼에서 설정을 바로 열 수 있다.
- 일반 탭: 자동 실행 설정과 로그인 항목 등록 상태 확인
- 키보드 단축키 탭: 텍스트·Live 번역 두 가지 단축키 표시와 초기화
- 손쉬운 사용 탭: 글꼴 크기 설정과 미리보기
- 파일 및 번역 탭: 다운로드 위치와 기록 토글
- LLM 번역: 번역 방식에 정확히 `LLM API 사용`, `Codex App Server 사용`이 표시된다.
- LLM 번역 > LLM API 사용: 기존 공급자, 세부 모델, API 키, 자동 번역, temperature가 표시된다.
- LLM 번역 > Codex App Server 사용: 실행 중인 App Server의 `model/list` 결과가 모델 picker에 표시된다.
- Codex 모델 목록이 여러 페이지일 때 `nextCursor`가 끝날 때까지 모든 페이지를 반영한다.
- API 모델과 Codex 모델 선택은 별도로 유지되며 백엔드를 왕복해도 복원된다.
- 신규/기존 설치의 기본 번역 방식은 `LLM API 사용`이고 기존 Gemini 기본값과 저장값이 바뀌지 않는다.
- Codex 로그인이 없는 경우 API 키 오류로 오인하지 않는 명확한 안내가 표시된다.
- LLM Live: 기존 Gemini Live 모델/API 키/오디오 설정이 그대로 표시되고 텍스트 번역 방식 변경의 영향을 받지 않는다.

## 5. 번역 기능 체크리스트

- 빈 입력은 네트워크 요청 없이 안내 메시지를 표시한다.
- `LLM API 사용`에서는 Gemini API 키가 비어 있으면 오류 메시지를 표시한다.
- `LLM API 사용`의 HTTP 실패는 status code와 메시지를 표시한다.
- `Codex App Server 사용`에서는 Gemini API 키가 비어 있어도 Codex 로그인으로 번역할 수 있다.
- 선택한 백엔드에만 요청하며 성공 응답은 동일한 오른쪽 결과 패널에 표시한다.
- 기록 토글이 켜져 있으면 최근 기록에 저장한다.
- 앱을 재실행해도 번역 기록이 유지되고 기록 모드에서 조회/삭제할 수 있다.
- 신규 기록에는 사용한 엔진과 모델이 표시되고 원문·결과 텍스트가 줄임 없이 모두 표시된다.
- 로컬 기록 토글 또는 로컬 기록 삭제는 고정 Codex 작업의 대화 내역을 삭제하지 않는다.
- 마크다운 문법이 포함된 입력과 번역 결과는 가능한 범위에서 서식 있게 표시된다.

## 6. 번역비교 검증

- 모델 ID는 SOL, Terra, Luna, 5.5, 5.4, 5.4 mini, 5.3 순서로 정확히 매핑된다.
- App Server 모델 목록에 없는 모델은 요청하지 않고 해당 탭에 사용 불가로 표시한다.
- 사용 가능한 모델은 동시에 실행하지 않고 순차 요청한다.
- 한 모델의 실패는 해당 탭에만 표시되며 나머지 모델은 계속 번역한다.
- 원문·언어 변경, 모드 이탈, 중지 버튼은 진행 중 비교를 취소하고 늦은 결과를 반영하지 않는다.
- 성공한 각 결과는 기록 설정에 따라 Codex App Server 엔진과 실제 모델 ID로 저장된다.

## 7. PDF 파일 번역 검증

### 자동 검증

- 같은 디지털 PDF를 두 번 분석하면 페이지·블록·줄 ID와 2단 열 읽기 순서가 동일하다.
- 텍스트 레이어가 없는 깨끗한 스캔 페이지는 Vision OCR 줄과 경고를 만든다.
- MediaBox 원점이 (0, 0)인 0/90/180/270도 스캔은 비영점 CropBox에서도 같은 page-space OCR 좌표를 복원하고 같은 bounds에 overlay를 저장한다. 90°/270°는 동일 문서의 임시 0° carrier에서 CJK FreeText appearance를 만든 뒤 같은 annotation 객체를 대상 페이지로 이동하며 `hasAppearanceStream`, URL action, 원 page count/box/회전을 최종 재개방에서 검사한다. MediaBox 원점이 0이 아니거나 회전이 네 허용값 밖이면 엔진 호출 전 실패하고 출력 파일을 만들지 않는다.
- 페이지 XML 요청은 특수 문자를 escape하며 응답의 ID 순서를 원본대로 복원한다.
- 누락·중복·알 수 없는 ID, 빈 번역, 손상된 XML은 합성 전에 실패한다.
- Apple 응답의 `clientIdentifier` 순서가 바뀌어도 원본 블록 순서를 복원하고 언어 코드/중국어 script를 보존한다.
- 출력의 페이지 수, media/crop/bleed/trim/art box, 회전, 기존 일반 주석과 링크 URL/action 및 appearance stream 존재 여부를 포함한 안정적인 fingerprint가 원본과 같다. overlay의 subtype, bounds, 마스크/글자 색, 정렬, 글꼴/glyph, 표시/인쇄 속성을 재개방 후 검사하며 링크와 겹친 overlay에도 같은 URL action이 남는다.
- 색상 배경에는 샘플한 마스크 색을 적용하고 대상 문자의 glyph를 지원하는 글꼴을 사용한다.
- 번들 Barlow/Noto Sans KR/D2Coding을 실제 공개 PostScript 이름으로 등록하고 반복 등록 요청이 캐시된 같은 결과를 반환하는지 검증한다.
- 라틴/한글/고정폭 PDF를 저장·재개방·재저장한 뒤 각각 신뢰 가능한 공개 원본 또는 Barlow/Noto Sans KR/D2Coding font identity와 전체 glyph가 유지되는지 검증한다. private SF 리소스가 PDFKit에서 Times로 대체된 경우도 원래 bold/monospaced 의도를 복원해 Times 출력 회귀가 없는지 확인한다.
- 번역 누락, 최소 5pt에서도 overflow, 지원할 글꼴 없음, 복잡·추정 불가 배경, 단일 URL로 복제할 수 없는 중첩 링크, Link가 아닌 기존 주석 중첩, 잠금/서명/변경 금지/입력형 양식은 최종 파일을 남기지 않는다. 번역 전에 알 수 있는 조건은 엔진 호출 전 preflight에서 실패한다.
- OCR 실패·낮은 신뢰도·텍스트 미검출 경고가 있으면 확인 전에는 엔진을 호출하지 않고, 명시적 확인 후에만 나머지 페이지 번역을 허용한다.
- 원본 경로와 같은 출력 및 기존 목적지 덮어쓰기를 거부한다.
- 존재하지 않거나 쓸 수 없는 저장 폴더는 UUID 0바이트 probe 단계에서 엔진 호출 전에 거부하고 probe 파일을 남기지 않는다.
- 취소 또는 새 import 뒤 늦게 도착한 번역 결과가 UI나 목적지 파일에 반영되지 않는다.

### 시각 검증

1. 표, 컬러 배경, 2단 본문과 기존 일반 주석이 있는 fixture를 분석/합성한다.
2. Poppler `pdftoppm -png -r 150`으로 원본과 번역본의 모든 페이지를 이미지로 렌더링한다.
3. 0°/90°/180°/270°에서 페이지 크기·회전·표·이미지·벡터·일반 주석 위치가 같은지, 원문 영역만 배경과 번역문으로 바뀌었는지 눈으로 확인한다. 이 수동 렌더 비교는 자동 구조 재검증과 구분해 기록한다.
4. 긴 번역, CJK/라틴 혼합, 흰 글자/어두운 배경, OCR 결과를 별도로 확인한다. 비영점 CropBox의 90°/270° CJK 출력은 Poppler 144dpi에서 한 줄 방향·정렬 기준점과 PDFKit 재저장 전후 렌더 hash를 비교한다.
5. 생성된 QA 중간 파일은 검증 후 삭제하고 제품 출력만 전달한다.

### 수동 UI 검증

- PDF 선택 버튼과 드래그앤드롭 모두 동작하며 PDF 외 파일은 거부한다.
- 원본/번역본 미리보기 전환, 분석/OCR 경고, 페이지 진행률, 취소가 보인다.
- macOS 15 이상에서는 Apple 내장 번역과 언어 팩 안내가 동작하고 macOS 14에서는 명확히 비활성화된다.
- Codex는 동적 모델 목록을, Gemini API는 모델 picker와 보안 입력 API 키를 사용한다.
- 파일 번역용 Gemini API 키는 화면을 닫거나 앱을 종료한 뒤 `UserDefaults`에 남지 않는다.
- `매번 묻기`는 save panel을 열고 Desktop/Downloads는 충돌 없는 이름으로 저장한다.
- 완료 후 번역본 열기와 Finder에서 보기가 정확한 결과 파일을 가리킨다.

## 8. Codex App Server 검증

| 영역 | 검증 방법 | 기대 결과 |
| --- | --- | --- |
| 실행/인증 | 설치된 Codex 실행 파일로 `app-server --listen stdio://` 실행 후 initialize | 기존 Codex 로그인을 사용하고 별도 API 키를 요구하지 않는다. 실행 파일/로그인 문제는 구분된 오류로 끝난다. |
| 라우팅 | 같은 원문을 두 백엔드에서 각각 실행하고 호출 spy 확인 | 선택한 client만 한 번 호출되고 결과는 같은 결과 패널/기록 흐름으로 전달된다. |
| 모델 | cursor가 있는 `model/list` 응답과 모델 선택/재실행 검증 | 전체 페이지를 합치며 선택 ID를 `kc.advanced.codexModelID`에 저장한다. API 모델 설정은 변경하지 않는다. |
| 작업 | 저장 ID resume, stale ID, 고정 이름 검색, 신규 생성/이름 지정 검증 | `KC DeepL 번역` 작업을 재사용하고 `kc.advanced.codexThreadID`를 갱신하며 불필요한 중복 작업을 만들지 않는다. |
| 작업 기록 | 로컬 기록 OFF/삭제 후 같은 Codex 작업 resume | Codex 작업 대화 내역은 로컬 `translation-history.json`과 독립적으로 유지된다. |
| 격리 | start/resume/turn RPC 파라미터와 자식 프로세스 인자/cwd 검사 | cwd는 `Application Support/KCDeepL/CodexTranslation`, approval은 `never`, sandbox는 `read-only`이며 shell/exec·브라우저·앱/플러그인·MCP·웹 검색이 비활성화된다. |
| 취소 | 느린 turn 중 새 원문 입력, 백엔드 변경, 수동 취소, 앱 종료 | `turn/interrupt` 후 terminal 이벤트를 확인하고 이전 결과/기록을 반영하지 않으며 다음 turn과 섞이지 않는다. |
| 최종 출력 | commentary, delta, `final_answer`, phase 미지정 메시지를 섞어 전달 | 완료 뒤 `final_answer`를 우선하고 delta를 중복 결합하지 않으며 최종 번역만 표시한다. |
| schema | 정상/누락/추가 필드/잘못된 JSON 응답 전달 | 엄격한 `{translation:string}`만 수락하고 손상된 결과를 성공으로 저장하지 않는다. |
| 프로세스 | stdout 부분 줄/복수 줄/CRLF, stderr flood, 중간 종료 검증 | JSONL을 정확히 분리하고 오류 시 모든 waiter가 종료되며 app-server 자식 프로세스가 남지 않는다. |

실제 Codex 로그인과 사용량을 소비하는 통합 smoke test는 기본 `swift test`와 분리해 opt-in으로 실행한다. 일반 테스트에서는 scripted transport/process launcher로 모델, 작업, turn 이벤트 순서를 결정적으로 재현한다.

## 9. 회귀 테스트

기본 단위 테스트:

- `TranslationPromptBuilderTests`
- `GeminiTranslationClientTests`
- `GeminiLiveTranslationClientTests`
- `GeminiResponseParserTests`
- `TranslationHistoryStoreTests`
- `LiveTranscriptLanguageFilterTests`
- `LiveTranscriptTurnAssemblerTests`
- `LiveConversationSegmenterTests`
- `TranslationViewModelTests`
- `TranslationComparisonViewModelTests`
- `LiveTranslationViewModelPersistenceTests`
- `DocumentPageTranslationTests`
- `AppleDocumentTranslationClientTests`
- `PDFDocumentServicesTests`
- `FileTranslationOutputURLResolverTests`
- `FileTranslationViewModelTests`

추가 권장 테스트:

- JSONL transport와 App Server RPC lifecycle 테스트
- 동적 모델 목록 페이지네이션과 선택 복원 테스트
- 고정 Codex 작업 resume/start 및 이름 지정 테스트
- turn interrupt/terminal/final output 테스트
- 텍스트 백엔드 라우팅 및 설정 migration 테스트
- 번역비교 모델 순서, 순차 실행, 부분 실패 테스트
- 이력 엔진 메타데이터와 구버전 JSON 호환 테스트
- 기록 저장 정책 테스트

## 10. 수동 QA 시나리오

1. 앱 실행 후 한국어 대상 언어 유지 확인
2. 기본 `LLM API 사용`에서 영어 문장 입력 후 번역 실행
3. 설정 > LLM 번역에서 API 모델을 `gemini-2.5-flash`로 변경 후 다시 `gemini-2.5-flash-lite`로 복원
4. 번역 방식을 `Codex App Server 사용`으로 변경하고 동적으로 불러온 모델 하나를 선택
5. 같은 영어 문장을 번역해 오른쪽 결과 패널과 최근 기록에 표시되는지 확인
6. 번역비교로 전환해 7개 탭과 각 모델 결과/오류 상태를 확인
7. 번역 기록에서 엔진·모델과 긴 원문·결과 전체가 표시되는지 확인
8. Codex에서 이름이 `KC DeepL 번역`인 작업이 생성 또는 재사용되었는지 확인
9. 빠르게 서로 다른 두 원문을 입력해 마지막 번역만 결과와 기록에 남는지 확인
10. 로컬 기록 저장을 끄고 다시 번역한 뒤 Codex 작업 내역과 로컬 기록이 독립적인지 확인
11. 앱을 재실행해 Codex 모델/작업이 복원되고 새 중복 작업이 생기지 않는지 확인
12. `LLM API 사용`으로 돌아가 기존 API 모델/키가 유지되는지 확인
13. LLM Live 화면에서 기존 양방향 음성 번역이 그대로 동작하는지 확인
14. 설정 > 키보드 단축키에서 기본값 초기화
15. 원문 패널, 앱 메뉴, 메뉴 막대, 단축키 설정에서 화면 캡처 목업이 제거되었는지 확인
16. 파일 번역에서 디지털 PDF를 선택하고 페이지/텍스트 영역 수와 원본 미리보기 확인
17. Apple, Codex, Gemini API 세 엔진에서 각각 모델/키 요구사항과 페이지 진행률 확인
18. 번역본 미리보기와 렌더링을 원본과 비교하고 표·이미지·일반 주석 보존 확인
19. 입력형 PDF 양식은 출력 없이 평면화 안내 오류로 끝나는지 확인
20. 스캔 PDF의 OCR 경고와 번역 배치 확인
21. 번역 중 취소하고 목적지에 부분 PDF가 남지 않는지 확인
