# KC DeepL Validation Plan

## 1. 정적 검증

- `swift test`
- `swift build`
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency`
- `swift build -Xswiftc -swift-version -Xswiftc 6`
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
- 언어 선택 picker가 동작한다.
- 입력/결과 2패널이 동일한 높이로 표시된다.
- 빈 입력 상태에서 입력 힌트가 보인다.
- 입력 중에는 API 호출이 보류되고 1초 이상 휴지기가 생기면 자동 번역이 시작된다.
- 오른쪽 도구 패널을 열고 닫을 수 있다.
- 캡처 버튼을 누르면 캡처 목업 시트가 열린다.
- 캡처 완료 시 원문 필드에 캡처 안내 문구가 들어간다.
- 선택한 텍스트 번역 백엔드의 성공 결과가 동일한 오른쪽 결과 패널에 표시된다.

## 4. 설정 UI 체크리스트

- 햄버거 메뉴에서 설정을 열 수 있다.
- 일반 탭: 자동 실행, 빠른 액세스, 닫기 동작 설정
- 키보드 단축키 탭: 세 가지 단축키 표시와 초기화
- 손쉬운 사용 탭: 글꼴 크기와 음성 속도 설정
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
- 로컬 기록 토글 또는 로컬 기록 삭제는 고정 Codex 작업의 대화 내역을 삭제하지 않는다.
- 마크다운 문법이 포함된 입력과 번역 결과는 가능한 범위에서 서식 있게 표시된다.

## 6. Codex App Server 검증

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

## 7. 회귀 테스트

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
- `LiveTranslationViewModelPersistenceTests`

추가 권장 테스트:

- JSONL transport와 App Server RPC lifecycle 테스트
- 동적 모델 목록 페이지네이션과 선택 복원 테스트
- 고정 Codex 작업 resume/start 및 이름 지정 테스트
- turn interrupt/terminal/final output 테스트
- 텍스트 백엔드 라우팅 및 설정 migration 테스트
- 캡처 상태 전이 테스트
- 기록 저장 정책 테스트

## 8. 수동 QA 시나리오

1. 앱 실행 후 한국어 대상 언어 유지 확인
2. 기본 `LLM API 사용`에서 영어 문장 입력 후 번역 실행
3. 설정 > LLM 번역에서 API 모델을 `gemini-2.5-flash`로 변경 후 다시 `gemini-2.5-flash-lite`로 복원
4. 번역 방식을 `Codex App Server 사용`으로 변경하고 동적으로 불러온 모델 하나를 선택
5. 같은 영어 문장을 번역해 오른쪽 결과 패널과 최근 기록에 표시되는지 확인
6. Codex에서 이름이 `KC DeepL 번역`인 작업이 생성 또는 재사용되었는지 확인
7. 빠르게 서로 다른 두 원문을 입력해 마지막 번역만 결과와 기록에 남는지 확인
8. 로컬 기록 저장을 끄고 다시 번역한 뒤 Codex 작업 내역과 로컬 기록이 독립적인지 확인
9. 앱을 재실행해 Codex 모델/작업이 복원되고 새 중복 작업이 생기지 않는지 확인
10. `LLM API 사용`으로 돌아가 기존 API 모델/키가 유지되는지 확인
11. LLM Live 화면에서 기존 양방향 음성 번역이 그대로 동작하는지 확인
12. 설정 > 키보드 단축키에서 기본값 초기화
13. 캡처 버튼으로 목업 시트 열고 캡처 완료
