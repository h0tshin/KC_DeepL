# KC DeepL

KC DeepL은 DeepL 스타일의 macOS 즉석 번역 앱입니다. 텍스트 번역은 설치된 OpenAI Codex의 로컬 App Server 또는 기존 LLM API를 선택해서 사용할 수 있고, 양방향 음성 번역은 기존과 동일하게 Gemini Live를 사용합니다.

## 텍스트 번역 백엔드

**설정 > LLM 번역**의 번역 방식에서 다음 두 경로를 선택할 수 있습니다.

- **LLM API 사용**: 기존 Gemini API 경로입니다. 신규 설치와 기존 설치 모두 이 경로가 기본이며, 기본 텍스트 모델 `gemini-2.5-flash-lite`, 공급자, 모델, API 키 설정은 그대로 유지됩니다.
- **Codex App Server 사용**: 이 Mac에 설치된 `codex` 실행 파일로 `codex app-server --listen stdio://`를 시작합니다. 별도 API 키 대신 기존 Codex 로그인을 사용하며, 실행 중인 App Server의 모델 목록을 동적으로 불러와 선택할 수 있습니다.

Codex 번역은 이름이 **`KC DeepL 번역`**인 전용 Codex 작업을 계속 재사용합니다. 작업 ID와 선택 모델은 앱 설정에 저장되며, Codex 작업의 대화 내역은 KC DeepL의 로컬 번역 기록과 별개로 유지됩니다. 따라서 KC DeepL에서 로컬 기록 저장을 꺼도 Codex 작업 내역이 자동으로 삭제되지는 않습니다.

상단의 **번역비교**에서는 같은 원문을 SOL, Terra, Luna, 5.5, 5.4, 5.4 mini, 5.3의 7개 Codex 모델로 번역하고 탭별 결과를 비교할 수 있습니다. 고정 Codex 작업을 안전하게 공유하도록 모델 요청은 순서대로 실행되며, 한 모델이 실패해도 나머지 비교는 계속됩니다.

LLM API 키는 앱에 포함되지 않습니다. 첫 실행 후 **설정 > LLM 번역 / LLM Live**에서 필요한 키를 직접 입력하면 이 Mac의 앱 설정(`UserDefaults`)에 저장됩니다. Codex App Server 경로에는 API 키가 필요하지 않습니다.

## 실행

```bash
./script/build_and_run.sh
```

검증 실행:

```bash
./script/build_and_run.sh --verify
```

테스트:

```bash
swift test
```

## 현재 구현

- macOS SwiftUI 2패널 번역 UI
- 오른쪽 도구 패널
- 별도 설정 창
- 텍스트 번역용 Codex App Server / LLM API 백엔드 선택
- 설치된 Codex 실행 파일 탐색, 로컬 stdio App Server 연결, 동적 모델 선택
- 고정된 `KC DeepL 번역` Codex 작업 재사용
- 7개 Codex 모델의 탭 기반 번역 품질 비교
- 기존 Gemini API 번역 클라이언트
- Gemini Live 실시간 음성 번역과 오디오 By Pass
- `UserDefaults` 기반 API 설정 저장
- 엔진·모델 정보와 원문/결과 전체를 표시하는 로컬 번역 기록
- 화면 캡처 진입 목업
- 번역 프롬프트/응답 파서 단위 테스트

## 보안 주의

이 저장소의 과거 Git 이력에 개발용 인증정보가 포함된 적이 있습니다. 해당 인증정보는 폐기·재발급해야 하며, 현재 소스와 새 앱 바이너리에는 기본 API 키가 포함되지 않습니다. 사용자가 입력한 키는 `UserDefaults`에 평문으로 저장됩니다. Git 이력 정리가 필요하다면 모든 협업자와 배포 지점을 확인한 뒤 별도 이력 재작성 절차로 진행하세요.

Codex App Server 번역은 저장소나 사용자 작업 폴더가 아닌 `Application Support/KCDeepL/CodexTranslation`을 전용 현재 작업 폴더로 사용합니다. 번역 turn은 승인 요청을 허용하지 않는 `never` 정책과 `read-only` 샌드박스로 실행하며, shell/exec·브라우저·앱/플러그인·MCP·웹 검색 도구를 비활성화합니다. 다만 원문과 번역 결과는 재사용하는 Codex 작업의 대화 내역에 남을 수 있으므로 민감한 원문을 번역할 때는 이 점을 고려해야 합니다.

## 문서

- [제품 요구서](docs/product_requirements.md)
- [기술 정의서](docs/technical_spec.md)
- [실행 계획](docs/execution_plan.md)
- [검증 계획](docs/validation_plan.md)
- [UX/UI 설계](docs/ux_ui_design.md)
- [레퍼런스](references/README.md)
