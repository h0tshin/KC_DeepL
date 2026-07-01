# KC DeepL

KC DeepL은 DeepL 스타일의 macOS 즉석 번역 앱 목업입니다. 기본 번역 공급자는 Gemini이며 초기 기본 모델은 `gemini-2.5-flash-lite`입니다.

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
- 화면 캡처 진입 목업
- 번역 프롬프트/응답 파서 단위 테스트

## 문서

- [제품 요구서](/Users/h0tshin/Documents/KC_DeepL/docs/product_requirements.md)
- [기술 정의서](/Users/h0tshin/Documents/KC_DeepL/docs/technical_spec.md)
- [실행 계획](/Users/h0tshin/Documents/KC_DeepL/docs/execution_plan.md)
- [검증 계획](/Users/h0tshin/Documents/KC_DeepL/docs/validation_plan.md)
- [UX/UI 설계](/Users/h0tshin/Documents/KC_DeepL/docs/ux_ui_design.md)
- [레퍼런스](/Users/h0tshin/Documents/KC_DeepL/references/README.md)
