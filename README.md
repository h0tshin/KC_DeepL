# KC DeepL

KC DeepL은 DeepL 스타일의 macOS 즉석 번역 앱입니다. 텍스트 번역은 설치된 OpenAI Codex의 로컬 App Server 또는 기존 LLM API를 선택해서 사용할 수 있고, 양방향 음성 번역은 기존과 동일하게 Gemini Live를 사용합니다.

## 글꼴

영문 UI와 일반 라틴 텍스트는 **Barlow**, 한글은 **Noto Sans KR**을 주력으로 사용하고 코드·고정폭 텍스트는 **D2Coding**을 사용합니다. 정적 Regular/Semibold 또는 Bold 파일을 앱 리소스에 포함해 실행 프로세스에만 한 번 등록하므로 사용자 Font Book에는 설치하지 않습니다. 등록에 실패한 환경에서는 시스템 글꼴로 안전하게 대체합니다. PDF는 레이아웃을 우선해 번역문 전체 glyph를 지원하는 공개 원본 글꼴을 먼저 유지하고, 그렇지 않으면 위 글꼴과 공개 시스템 CJK fallback을 사용합니다. 원본·라이선스·고정 커밋·SHA-256은 [폰트 고지](Sources/App/Resources/Fonts/NOTICE.md)에 기록되어 있습니다.

## PDF 파일 번역

상단의 **파일 번역**에서 PDF를 선택하거나 끌어다 놓으면 페이지별 텍스트와 좌표를 분석한 뒤 원래 위치에 번역 레이어를 배치한 새 PDF를 만듭니다. 번역 엔진은 다음 세 경로에서 고를 수 있습니다.

- **Apple 내장 번역**: macOS 15 이상에서 기기 내 Translation 프레임워크를 사용합니다. 필요한 언어 팩은 시스템 승인을 거쳐 내려받습니다.
- **Codex App Server**: 이 Mac의 Codex 로그인과 동적으로 조회한 모델을 사용합니다. 페이지 내용과 결과가 전용 Codex 작업 기록에 남을 수 있습니다.
- **Gemini API**: 사용자가 입력한 API 키와 선택한 Gemini 모델을 사용합니다. 파일 번역 화면의 키는 메모리에만 두고 앱 설정에 저장하지 않습니다.

한 페이지의 텍스트 블록 전체를 안정적인 ID와 함께 한 요청으로 보내므로 문장이 여러 영역으로 나뉘거나 읽기 순서가 섞여도 페이지 문맥과 원래 배치 위치를 함께 유지합니다. 응답의 ID가 누락·중복·변조되면 PDF를 만들지 않습니다. 텍스트 레이어가 없는 스캔 페이지뿐 아니라 일반 텍스트와 이미지가 섞인 페이지도 Vision OCR 결과를 좌표 중복 제거 후 보충합니다. 0/90/180/270도 페이지는 PDFKit 표시 변환의 역행렬로 OCR 위치를 원래 PDF 좌표에 복원하며, 변환·비율·교차 검증에 실패한 페이지는 추측 배치하지 않고 UI에서 경고합니다. OCR 실패·낮은 신뢰도·텍스트 미검출이 있으면 기본적으로 시작을 막고, 사용자가 누락 가능성을 명시적으로 확인한 경우에만 계속합니다.

| 페이지 회전 | 텍스트/OCR 분석 | 번역 PDF 합성 |
| --- | --- | --- |
| 0°, 180° | 지원 | MediaBox 원점이 (0, 0)이면 지원 |
| 90°, 270° | page-space 좌표 복원 지원 | MediaBox 원점이 (0, 0)이면 동일 문서의 임시 0° 페이지에서 FreeText appearance를 만든 뒤 원래 페이지로 이동하여 지원. 비영점 CropBox는 허용 |
| 그 외 각도/불안정 변환 | 안전 guard를 통과한 native text만 사용 | 엔진 호출 전 안전 중단 |

출력은 원본 파일을 절대 덮어쓰지 않습니다. 원본 content stream을 바꾸지 않고 그 위에 배경색 마스크와 크기를 맞춘 번역 주석을 추가합니다. 저장 직후 출력 PDF를 다시 열어 페이지 수, media/crop/bleed/trim/art box, 회전, 기존 일반 주석·링크 URL/action과 appearance stream 존재 여부, 번역 overlay의 bounds·색·정렬·글꼴/glyph·표시/인쇄 속성을 구조적으로 재검증합니다. 이는 임의 이미지·표·벡터를 픽셀 단위로 동일하다고 검증한다는 뜻은 아닙니다. 원문 링크와 번역 영역이 겹치면 단일 URL action을 마스크와 번역 주석에도 복제하고 확인 경고를 표시합니다. MediaBox 원점이 (0, 0)이 아닌 페이지, 0/90/180/270 이외 회전, 복수 URL이나 GoTo/Named/Remote action, Link가 아닌 기존 주석이 번역 영역과 겹치거나 배경이 복잡·추정 불가한 경우에는 번역 엔진 호출 전 preflight에서 안전 실패합니다. 선택한 저장 폴더도 UUID 기반 빈 probe 파일을 즉시 생성·삭제해 현재 쓰기 권한을 엔진 호출 전에 확인합니다. 번역문이 원문보다 길거나 대상 글꼴을 사용할 수 없는 경우에도 잘라내지 않고 출력을 만들지 않습니다. 전자 서명·잠금·변경 금지 PDF와 appearance를 안전하게 재직렬화할 수 없는 입력형 PDF 양식은 원본 무결성을 위해 거부합니다.

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

Developer ID Release 번들:

```bash
./script/build_and_run.sh --release
```

Release 모드는 `Developer ID Application` 인증서, Hardened Runtime, 보안 타임스탬프와 마이크 입력 entitlement를 적용해 `dist/KCDeepL.app`을 생성합니다. App Store 밖에서 다른 Mac에 배포하려면 이 번들을 Apple 공증한 뒤 공증 티켓을 stapling해야 합니다.

Finder에서 직접 실행할 사용자 전달용 번들을 최신 빌드로 교체하려면, 명시적으로 다음 명령을 실행합니다. 기본 실행 경로는 의도적으로 `dist/KCDeepL.app`만 갱신하며, 이 명령만 `/Applications/KCDeepL.app`을 안전하게 교체합니다.

```bash
./script/build_and_run.sh --install-application
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
- 페이지 단위 문맥·안정적 위치 ID를 사용하는 PDF 파일 번역
- PDFKit 텍스트/좌표 추출, Vision OCR, 비파괴 번역 레이어 합성
- 원문 마스크와 번역 컨테이너를 분리하고, 목록의 줄바꿈 continuation을 하나의 문단으로 묶어 페이지 단위 번역
- 열 경계·glyph 폭 측정 기반으로 문단 전체를 자연스럽게 reflow하여 `Plex는퍼블릭`처럼 좁은 줄에 갇히는 현상, 문장 끝 기호만 남는 고아 줄, 짧은 continuation 조각의 초소형 글꼴을 방지
- PDFKit의 stale paragraph alignment를 glyph geometry와 목록 블록 문맥으로 교정하여 bullet/답변의 왼쪽 시작점과 가운데·오른쪽 정렬을 보존
- Apple 내장 / Codex App Server / Gemini API 파일 번역 엔진 선택
- 원본 덮어쓰기 방지, 진행률·취소·경고·원본/결과 PDF 미리보기
- Barlow/Noto Sans KR/D2Coding 정적 폰트 번들, 프로세스 등록과 PDF 저장 후 glyph 검증
- 기존 Gemini API 번역 클라이언트
- Gemini Live 실시간 음성 번역과 오디오 By Pass
- `UserDefaults` 기반 API 설정 저장
- 엔진·모델 정보와 원문/결과 전체를 표시하는 로컬 번역 기록
- 화면 캡처 진입 목업
- 번역 프롬프트/응답 파서 단위 테스트

## 보안 주의

이 저장소의 과거 Git 이력에 개발용 인증정보가 포함된 적이 있습니다. 해당 인증정보는 폐기·재발급해야 하며, 현재 소스와 새 앱 바이너리에는 기본 API 키가 포함되지 않습니다. 설정 화면의 기존 텍스트/Live 키는 `UserDefaults`에 평문으로 저장되고, 파일 번역 화면의 키는 영구 저장하지 않습니다. Git 이력 정리가 필요하다면 모든 협업자와 배포 지점을 확인한 뒤 별도 이력 재작성 절차로 진행하세요.

Codex App Server 번역은 저장소나 사용자 작업 폴더가 아닌 `Application Support/KCDeepL/CodexTranslation`을 전용 현재 작업 폴더로 사용합니다. 번역 turn은 승인 요청을 허용하지 않는 `never` 정책과 `read-only` 샌드박스로 실행하며, shell/exec·브라우저·앱/플러그인·MCP·웹 검색 도구를 비활성화합니다. 다만 원문과 번역 결과는 재사용하는 Codex 작업의 대화 내역에 남을 수 있으므로 민감한 원문을 번역할 때는 이 점을 고려해야 합니다.

## 문서

- [제품 요구서](docs/product_requirements.md)
- [기술 정의서](docs/technical_spec.md)
- [실행 계획](docs/execution_plan.md)
- [검증 계획](docs/validation_plan.md)
- [UX/UI 설계](docs/ux_ui_design.md)
- [레퍼런스](references/README.md)
