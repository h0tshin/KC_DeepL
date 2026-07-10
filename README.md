# KC DeepL

KC DeepL은 DeepL 스타일의 macOS 즉석 번역 앱입니다. 텍스트 번역과 Gemini Live 기반 양방향 음성 번역을 지원하며, 기본 텍스트 모델은 `gemini-2.5-flash-lite`입니다.

API 키는 앱에 포함되지 않습니다. 첫 실행 후 **설정 > LLM 번역 / LLM Live**에서 직접 입력하면 이 Mac의 앱 설정(`UserDefaults`)에 저장됩니다.

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
- Gemini 번역 클라이언트
- Gemini Live 실시간 음성 번역과 오디오 By Pass
- `UserDefaults` 기반 API 설정 저장
- 로컬 번역 기록과 Live 대화 기록
- 화면 캡처 진입 목업
- 번역 프롬프트/응답 파서 단위 테스트

## 보안 주의

이 저장소의 과거 Git 이력에 개발용 인증정보가 포함된 적이 있습니다. 해당 인증정보는 폐기·재발급해야 하며, 현재 소스와 새 앱 바이너리에는 기본 API 키가 포함되지 않습니다. 사용자가 입력한 키는 `UserDefaults`에 평문으로 저장됩니다. Git 이력 정리가 필요하다면 모든 협업자와 배포 지점을 확인한 뒤 별도 이력 재작성 절차로 진행하세요.

## 문서

- [제품 요구서](docs/product_requirements.md)
- [기술 정의서](docs/technical_spec.md)
- [실행 계획](docs/execution_plan.md)
- [검증 계획](docs/validation_plan.md)
- [UX/UI 설계](docs/ux_ui_design.md)
- [레퍼런스](references/README.md)
