# GPT Luna 전달용 — PDF → PPTX/DOCX 구현 프롬프트

- 용도: KC DeepL 저장소에서 PDF 문서 변환 기능을 실제로 완성하도록 GPT Luna에게 그대로 전달
- 대상 환경: macOS 14+, Swift 5.9+, SwiftPM 기반 native macOS 앱
- 기준일: 2026-08-03

## Luna가 반드시 읽을 문서 순서

1. Luna 작업 컨텍스트에 제공되는 `AGENTS.md instructions` — 저장소 작업·검증·Git 규칙. 실제 root `AGENTS.md`가 생긴 경우에도 읽는다.
2. `docs/pdf_office_conversion_implementation_guide.md` — 이 기능의 최우선 설계·요구사항·완료 기준
3. `docs/technical_spec.md` — 기존 앱 구조와 제품 규칙
4. `docs/validation_plan.md` — 기존 전체 검증 명령
5. `docs/execution_plan.md` — 기존 구현·패키징 흐름
6. 실제 코드와 테스트:
   - `Package.swift`
   - `Sources/App/App/KCDeepLApp.swift`
   - `Sources/App/App/AppDelegate.swift`
   - `Sources/App/Views/ContentView.swift`
   - `Sources/App/Views/FileTranslationWorkspace.swift`
   - `Sources/App/Support/FileTranslationViewModel.swift`
   - `Sources/App/Support/PendingPersistenceRegistry.swift`
   - `Sources/App/Services/PDFDocumentAnalysisService.swift`
   - `Sources/App/Support/FileTranslationOutputURLResolver.swift`
   - `Sources/App/KCDeepL.entitlements`
   - `script/build_and_run.sh`
   - `Tests/KCDeepLAppTests/`
   - `Tests/KCDeepLCoreTests/`

### 현재 저장소 구현 프로파일

현재 브랜치에는 이미 macOS native baseline이 구현되어 있다. `PDFKit`·`CoreGraphics`·`ImageIO`·`Vision`과 순수 Swift ZIP/OOXML writer를 사용하며, PDFium/XCFramework/helper, ZIPFoundation, .NET/DLL, LibreOffice를 실행 의존성으로 추가하지 않는다. 기존 baseline의 page-RGBA safety net, editable text boxes, decoded image assets/masks, conservative native rectangles, operation gate와 lifecycle을 먼저 유지하고 확장한다. PDFium worker는 실제 pinned artifact·license·universal build·signed sandbox helper를 함께 추가할 때만 별도 고충실도 프로파일로 도입하며, 존재하지 않는 artifact를 구현 완료로 보고하지 않는다.

현재 저장소 root에는 tracked `AGENTS.md`가 없고, `AGENTS 2.md`는 기존 사용자 소유 untracked 파일이다. Luna는 `AGENTS 2.md`를 canonical instruction으로 추측하거나 변경·stage하지 않는다. 문서가 충돌하면 PDF 변환 기능에는 `docs/pdf_office_conversion_implementation_guide.md`가 우선하고, 보안·파괴적 작업·Git 범위에는 Luna task에 주입된 `AGENTS.md instructions`가 우선한다.

과거 worktree snapshot을 현재 상태로 가정하지 않는다. 구현 시작 직전에 `git status --short`, `git diff`, 현재 HEAD/remote를 직접 확인하고, 그 시점의 tracked/untracked 변경을 사용자 또는 병렬 작업으로 보존한다. 변환 ViewModel 주입 때문에 `ContentView.swift`를 수정할 때도 현재 파일을 통째로 교체하지 말고 최소 병합한다. 현재 확인되는 `application/`, `image/`, `output/`, `tmp/`와 기타 untracked 파일은 build input/release golden으로 추측하거나 삭제·덮어쓰기·stage하지 않는다.

## 그대로 전달할 프롬프트

```text
너는 KC DeepL macOS 앱의 PDF → PowerPoint/Word 변환 기능을 끝까지 구현하는 담당자 GPT Luna다.

현재 저장소에는 PDFKit/CoreGraphics/ImageIO/Vision 기반 native baseline과 순수 Swift OOXML/ZIP writer가 이미 들어 있을 수 있다. 먼저 이를 재사용·검증하라. PDFium/XCFramework/helper가 실제로 존재하지 않는다면 PDFium이 포함된 것처럼 보고하거나 .NET/DLL/LibreOffice를 shipping runtime으로 추가하지 말고, page-RGBA fallback과 품질 보고서를 유지한 채 native baseline을 완성하라.

작업 저장소:
/Users/h0tshin/Documents/KC_DeepL

먼저 다음 파일을 순서대로 끝까지 읽고, 실제 저장소 상태와 일치하는지 확인하라.

1. 현재 task에 주입된 AGENTS.md instructions. root에 실제 tracked AGENTS.md가 있으면 그것도 읽는다. 현재 untracked인 ‘AGENTS 2.md’는 사용자 파일이므로 지침으로 추측하거나 수정하지 않는다.
2. docs/pdf_office_conversion_implementation_guide.md
3. docs/technical_spec.md
4. docs/validation_plan.md
5. docs/execution_plan.md
6. Package.swift와 지침서가 지정한 기존 Swift source/test 파일

이 기능의 source of truth는 docs/pdf_office_conversion_implementation_guide.md다. 임의로 단순화하거나 다른 변환 제품을 호출하는 방식으로 대체하지 마라. 구현 전에 git status/diff/HEAD를 직접 확인하고 사용자·병렬 작업을 보존하라. 문서의 과거 worktree snapshot을 현재 상태로 가정하지 말며 현재 파일을 최소 병합하고 unrelated hunk를 stage하지 마라. 특히 이미 존재하던 untracked 파일·application/·image/·output/·tmp/를 삭제, 이동, 덮어쓰기, release golden으로 사용 또는 stage하지 마라.

필수 제품 동작:

- 파일번역 오른쪽 inspector의 ‘번역 엔진’ 선택 영역 바로 위에 ‘문서 변환’을 추가한다.
- 형식은 ‘파워포인트 (.pptx)’와 ‘워드 (.docx)’ 중 선택하고 ‘변환 시작’으로 저장한다.
- PDF page 하나를 PPT slide 하나 또는 fixed-layout DOCX page/section 하나로 변환한다.
- 이미지-only PDF도 변환한다. 번역 가능한 텍스트가 없다는 이유로 버튼을 막지 마라.
- 원본과 기존 출력 파일을 덮어쓰지 않고, 취소·실패 때 부분 파일을 남기지 마라.
- Same-volume temp output을 검증한 뒤 Darwin renamex_np(..., RENAME_EXCL) 또는 동등한 exclusive atomic primitive로 commit하라. fileExists+moveItem TOCTOU를 no-overwrite 보장으로 쓰지 말고 EEXIST이면 새 suffix를 resolve해 재시도하라.
- 별도 저장 위치 UI를 중복 만들지 말고 현재 file workspace의 `downloadLocation`(데스크탑/다운로드/매번 묻기)을 공유하라. `NSSavePanel`은 `@MainActor`의 작은 panel service에만 두고 형식별 UTI/확장자/기본 이름을 강제하라. Source descriptor와 destination commit의 security-scoped access는 모든 terminal path에서 균형 있게 닫아라.
- 번역과 변환의 state/lifecycle은 별도 ViewModel로 분리하되, UI `.disabled`만 믿지 말고 `KCDeepLApp`에서 하나의 `@MainActor FileWorkspaceOperationGate` lease를 두 ViewModel에 주입해 public start/import API 수준에서 동시에 실행되지 않게 하라.
- 변환 중에는 format/start와 번역 시작을 막되 `변환 취소`는 활성으로 유지하고, 번역 중에는 변환 시작을 막되 기존 `번역 취소`는 활성으로 유지하라. Busy container 전체를 disable해 자기 취소 버튼까지 막지 마라.
- `DocumentConversionViewModel`은 `KCDeepLApp`의 `@StateObject`로 소유하고 `ContentView`를 통해 `FileTranslationWorkspace`에 주입하라. Mode 전환이나 workspace view 재생성으로 진행 상태와 task가 사라져서는 안 된다. UI는 별도 `DocumentConversionSection` SwiftUI 파일로 분리하고 binding/value/callback만 받아 task나 장기 AppKit 객체를 소유하지 않게 하라.
- 번역 분석과 독립된 `SelectedFileSnapshot(url, kind, selectionGeneration, size, file identity, filename)`을 만든다. Generation은 실제 새 선택/clear에서만 바꾸고 OCR 재분석에는 유지하라. 번역 분석 실패·이미지-only PDF도 snapshot을 유지해 conversion preflight가 독립 판단하게 하라.
- `KCDeepLApp.init`에서 conversion VM의 termination preparation과 async shutdown을 `PendingPersistenceRegistry`에 정확히 한 번 등록하라. 종료 시 새 lease/generation을 막고 task/pipe를 취소한 뒤 bounded exact-child SIGTERM/SIGKILL/waitpid로 worker를 회수하고 소유 UUID temp만 정리하라. `deinit`만 믿지 마라.
- Format picker/진행률/시작·취소·결과·오류에 VoiceOver label/value/help와 keyboard focus를 제공하고 기존 `⌘O`/command와 충돌하는 새 shortcut을 만들지 마라.

절대적인 기술 경계:

- 대상은 macOS native Swift/SwiftPM이다.
- 출시 앱의 필수 변환 경로에는 .NET runtime, DocumentFormat.OpenXml DLL, Windows COM, Python, Java, LibreOffice, 외부 shell converter, PowerPoint/Word automation을 사용하지 마라.
- PDF 추출/렌더링은 exact commit으로 고정한 macOS arm64+x86_64 universal complete-static PDFium.xcframework와 public C API를 사용하라.
- PDFium은 SwiftPM local binaryTarget/CPDFiumBridge를 통해 `KCDeepLPDFWorkerCore`와 bundle의 signed universal `Contents/Helpers/KCDeepLPDFWorker.app/Contents/MacOS/KCDeepLPDFWorker`에만 정적으로 링크하라. 메인 `KCDeepL` target은 PDFium/bridge/worker core를 의존하거나 링크하면 안 된다. 사용자가 PDFium dylib, DLL, helper runtime을 별도 설치하게 하지 마라.
- `KCDeepLPDFWorker`는 외부 converter가 아니라 이 앱이 빌드·nested-signing하여 포함하는 first-party native Swift helper app이다. 매 PDF job마다 새 worker를 고정 executable URL을 직접 받는 전용 `NativeChildProcess`/`posix_spawn`으로 실행하고 pipe file-actions/close-on-exec를 설정하라. Environment는 필요한 locale만 allowlist하고 `DYLD_*`, `LD_*`, PATH, token/credential을 상속하지 마라. Shell/실행 파일 검색/사용자 제공 실행 경로를 사용하지 마라. Helper bundle/executable이 symlink가 아닌 bundle 내부 regular file이며 outer app과 같은 Team ID, expected worker identifier의 별도 designated requirement를 가진 sealed code인지 실행 전에 검증하라. Worker `SecStaticCodeCheckValidity`에는 all-architectures/strict/restrict-symlinks flags를, outer release bundle에는 nested-code check도 적용하고 signed identifier/Team/entitlement exact allowlist를 확인하라. App과 helper의 identifier가 다르므로 두 designated requirement 문자열이 같다고 요구하지 마라. 이 runtime check를 OS signing/notarization이나 완전한 TOCTOU 경계의 대체물로 주장하지 마라.
- worker 통신은 지침서 4.4의 versioned length-framed stdin/stdout protocol로 구현하라. Hello nonce/version/build hash, frame/payload SHA-256, request ID/order, 엄격한 크기·총량·NaN/overflow·asset offset 검증을 하고 PDF bytes/assets를 bounded chunk로 streaming하라. Newline JSON, 임의 file path 전달, unbounded stderr/whole-scene buffering을 쓰지 마라.
- 현재 main app은 App Sandbox를 켜지 않았으므로 상속을 보안 경계로 주장하지 마라. Worker를 `CFBundleIdentifier=com.h0tshin.KCDeepL.PDFWorker`, `CFBundleExecutable=KCDeepLPDFWorker`, `LSBackgroundOnly=true`인 helper app으로 감싸고 `com.apple.security.app-sandbox=true`만 부여하라. `com.apple.security.inherit`, network/file/Apple Events entitlement 없이 stdin/stdout과 worker container의 UUID temp만 사용하라. Signed exported worker의 runtime sandbox 상태, PDF fixture 성공, outbound socket과 미승인 사용자 문서 sentinel read/write 거부를 integration test로 증명하라. 광범위 entitlement를 추가해서 통과시키지 마라.
- lifecycle actor 하나가 `posix_spawn`, pipe, signal과 `waitpid`를 단독 소유하게 하고 Foundation `Process` reaper와 섞지 마라. Host watchdog은 wall time, 무진행, output budget, child footprint를 감시한다. 취소/timeout이면 cancel frame/stdin close 뒤 매 SIGTERM/SIGKILL 직전에 `waitpid(WNOHANG)`과 spawn 시 기록한 PID/`proc_pidinfo` start identity를 확인하라. 이미 종료됐거나 identity 확인에 실패하면 signal하지 말고, manual reaper가 status를 회수하기 전 zombie 상태로 PID 재사용을 막아 무관한 process를 죽이지 마라. `pkill`/이름 검색/process-group kill은 금지한다. Worker crash/hang/protocol corruption 뒤에도 메인 앱이 살아서 다음 job을 처리하는지 검증하라.
- PDFium API는 thread-safe가 아니므로 worker process 안의 process-wide PDFiumRuntimeActor 하나에서 모든 FPDF_* 호출을 concurrency 1로 직렬화하라. Document별 actor나 parallel page render를 만들지 마라. FPDF handle/raw pointer는 actor/worker 밖으로 보내지 말고 plain Swift value/copied bytes만 반환하라.
- Host는 열린 read-only descriptor에서 PDF를 hash하며 chunk streaming하고 UI ViewModel에 large PDF 전체를 중복 Data로 복사하지 마라. Worker는 자기 container의 mode 0600 exclusive/no-follow temp에 spool하고 declared size/hash를 검증하라. 작은 input만 bounded malloc copy + FPDF_LoadMemDocument64를 허용하고 기본 large-file 경로는 retained descriptor와 bounds-checked pread callback의 FPDF_FILEACCESS/FPDF_LoadCustomDocument를 사용하라.
- PDF input backing storage는 document close까지 살아 있어야 한다. Data.withUnsafeBytes 포인터를 보관하지 말고 document scope가 malloc-backed copy 또는 retained FPDF_FILEACCESS context/descriptor를 소유하게 하라. Page/text/structure/bitmap/document/input close order와 bitmap copy-before-destroy를 error/cancel test로 검증하라.
- in-flight FPDF_* C 호출은 Task cancellation로 중단된다고 가정하지 마라. 이 경우 host watchdog이 worker를 종료하는 test를 반드시 두어라. `pdf_use_partition_alloc=false`는 초기 static-link 호환성 trade-off일 뿐 보안 기능이 아니므로 threat model에 기록하고, 가능하면 같은 target에서 PartitionAlloc-enabled build를 Phase 0에서 재검토하라.
- PDFium page-object API만으로 ExtGState/SMask/clip/paint order가 완전하다고 가정하지 마라. Worker의 재귀 content-stream resolver가 resource scope별 `/ExtGState`, `/XObject`, `/Properties`, Form `/Matrix`/`/BBox`/`/Group`/`/Resources`를 resolve하고 `q/Q`, `cm`, `gs`, pending clip, `Do`, `sh`, `BT/ET`, BDC/EMC state를 occurrence별로 누적하게 하라. Unknown operator, resource/state stack 오류 또는 PDFium event 매칭 불일치가 compositing에 영향을 줄 수 있으면 native 변환을 금지하고 Form/dependency/page island로 보수적으로 fallback하라.
- OPC ZIP은 exact version으로 고정한 ZIPFoundation을 사용하고, PPTX/DOCX XML/relationships/content types는 순수 Swift typed writer로 생성하라.
- Open XML SDK는 표준 동작 참고 또는 shipping app과 분리된 선택적 개발 CI 교차검사에만 허용된다.
- macOS PowerPoint/Word는 설치된 QA 장비의 opt-in round-trip 검증에만 사용할 수 있다. 앱의 변환 동작은 Office가 없어도 완전해야 한다.
- MuPDF/PyMuPDF는 상용 라이선스 계약이 저장소에서 확인되지 않는 한 포함하지 마라. AGPL을 process 분리로 우회하지 마라.

핵심 품질 계약:

- PDF renderer 결과가 visual truth다.
- PDF가 Office 작성 의미를 잃은 경우까지 ‘모든 객체를 완전히 editable하며 pixel-identical’하다고 거짓 보장하지 마라.
- Office가 시각적으로 동등하게 표현할 수 있는 text/image/line/shape/table/connector만 native 객체로 만든다.
- Office가 동등하게 표현하지 못하는 SMask, clipping, transparency group, blend, pattern 등은 dependency closure를 구해 전체 페이지가 아닌 최소 RGBA render island로 보존한다. Backdrop-independent이면 transparent island, backdrop-dependent이면 안전성이 증명된 opaque baked island 또는 page fallback을 사용한다.
- 모든 source paint occurrence를 native object, template object 또는 render island 중 정확히 하나가 소유하게 하라. 조용한 누락과 중복은 0이어야 한다.
- object paint order를 하나의 전역 단조 증가 값으로 유지하고 PPTX shape-tree XML 순서와 DOCX anchor relativeHeight/behindDoc에 결정적으로 매핑하라.
- 암묵적 paper를 숨기지 말고 `pageBackdropPolicy`를 scene에 넣어라. 기본 runtime reference와 PPTX explicit background는 opaque sRGB white로 맞추고, DOCX는 목표 Word의 opaque white page canvas를 QA 계약으로 고정하되 `w:background`에 의존하지 마라. Alpha 독립성은 transparent/black/white/color probe로 별도 검증하고 backdrop-dependent island의 의존성과 배경 변경 제약을 보고하라.
- `backdropIndependent` island만 transparent surface에 렌더하라. `requiresPageBackdrop`는 backdrop을 포함한 opaque surface로 렌더하되 그 rectangle/z-span이 제외 node를 가리지 않는 안전한 replacement임을 증명하고, 증명할 수 없으면 `pageRasterFallback`으로 승격하라. Mode, baked backdrop, replacement proof와 편집 제약을 scene/report/test에 남겨라.

이미지·투명도:

- xref asset 단위가 아니라 실제 image paint occurrence마다 수집하라. 같은 asset의 여러 배치는 각각 위치·transform·clip·z-order를 보존하라.
- /SMask, /Matte, color-key /Mask, /ImageMask, 비직사각 clip, shear, alpha, ICC/CMYK를 지침서 결정표대로 처리하라.
- Direct SMask pixel combine은 `/S /Alpha`, identity transfer, aligned standalone mask, Normal blend, 지원 clip, group/backdrop dependency 없음이 모두 증명된 경우만 허용하라. `/Luminosity`, `/BC`, `/TR`, group color space/isolation/knockout은 완전 구현 증명이 없으면 dependency island로 보내라. Matte는 동일 색공간에서 alpha=0 guard/clamp를 포함한 지침서 식으로 역산하고 color-key sample stage와 ImageMask Decode 반전을 known-vector로 검증하라.
- `FPDFImageObj_GetImageDataDecoded` 결과를 RGBA로 착각하지 마라. 이는 filter-decoded raw sample이므로 `/Decode`, Indexed/bit depth, ICC/Lab/CMYK/Separation, mask를 완전 해석한 ColorSync sRGB RGBA 또는 PDFium reference render만 PNG 입력으로 허용하라.
- `FPDFImageObj_GetRenderedBitmap`이 surrounding page/Form clip, graphics-state SMask, group, blend backdrop을 보존한다고 가정하지 마라. 그런 state가 있으면 원래 graphics-state의 subset page/Form render만 사용하고 불가능하면 dependency island로 승격하라.
- alpha가 있으면 lossless PNG를 사용하고 JPEG로 평면화하지 마라.
- premultiplied alpha와 Matte 역산을 검증하고 black/white/color 배경 합성 golden test를 작성하라.
- non-Normal blend나 soft-mask group은 아래 backdrop까지 포함하는 최소 render-island dependency closure를 사용하라.

텍스트:

- Tagged PDF structure, ActualText, MCID를 우선하고 없으면 glyph → word → line → paragraph → text box 계층을 복원하라.
- PDF의 시각적 줄마다 textbox 하나를 만들지 마라. 같은 문단의 여러 줄과 style run을 하나의 text box에 넣어라.
- 한 문단 line들의 source paint span 사이에 겹치는 image/shape가 끼거나 line별 clip/mask/blend가 달라 하나의 z-slot으로 옮길 수 없으면 순서를 깨고 합치거나 line별 box로 위장하지 마라. Logical paragraph는 유지하되 intervening dependency와 최소 island/outline으로 보존하고 편집성 저하를 보고하라. 비겹침 interleave만 한 box 병합을 허용하라.
- 자연 wrap/metric 보정으로 원본 line baseline을 맞추지 못하면 box를 늘리지 말고 같은 textbox 안 원본 visual-line 경계에 a:br/w:br를 넣는 deterministic fallback을 사용하고 보고하라.
- column, table cell, caption, list, 큰 vertical gap, rotation/reading direction 변화만 box 분리 근거로 사용하라.
- 디지털 text를 OCR로 덮어쓰지 말고 필요한 영역에만 Vision OCR을 사용한 뒤 invisible OCR layer와 중복 제거하라.
- CoreText로 font mapping과 fit을 검증하고 OpenType OS/2.fsType embedding 권한을 준수하라. 허용되지 않으면 substitute/outline/raster 정책과 경고를 보고서에 기록하라.
- Logical Unicode order와 visual glyph/paint order를 분리하고 PDF text rendering mode 4–7의 clipping dependency를 보존하라. Type3/color glyph/invalid ToUnicode는 native editable text로 허위 복원하지 말고 ActualText/OCR은 의미 계층에, appearance는 outline/island에 둬라.
- PPTX `p:cNvSpPr@txBox`, xfrm, `a:bodyPr` inset/wrap/anchor/vert/noAutofit, paragraph/run/break/bidi/font/alpha와 DOCX WPS `wps:cNvSpPr`, `wps:spPr`, `wps:txbx/w:txbxContent`, `wps:bodyPr`, `w:pPr/w:rPr`의 bidi/EA/CS font/spacing을 typed builder로 완전 직렬화하라. RTL/vertical shaping이 threshold를 못 맞추면 해당 run/line만 fallback하라.
- DOCX embedded font는 ECMA-376 GUID/XOR `.odttf` 규칙과 `fontTable.xml` relationship을 구현하고 known-vector round-trip으로 검증하라. PPTX `application/x-fontdata`를 raw TTF rename이나 DOCX 방식으로 위조하지 마라. macOS PowerPoint에서 검증된 font-data encoder가 없으면 설치 font + 경고 또는 최소 text-run outline/island fallback으로 정직하게 처리하라.

벡터와 템플릿:

- line, rectangle, rounded rectangle, ellipse, polygon, arrow, connector, table을 먼저 인식해 native DrawingML/WPS object로 만들어라.
- Effective CTM 적용→path canonicalization→primitive residual/Hausdorff/angle fit→style/compositing eligibility의 결정적 순서를 쓰고, recognizer 성공 결과가 아닌 독립 labeled `NativePrimitiveEligibility` manifest를 100% 분모로 사용하라. Hole/even-odd, group transform, arrow/table topology, gradient가 target과 동등하지 않으면 SVG+PNG/island로 보내라.
- equivalent geometry/style/compositing가 검증되지 않으면 custom geometry 또는 최소 SVG/PNG fallback을 사용하라.
- 페이지 간 반복 fingerprint로 background, header, footer, page number, watermark/common mask 후보를 찾되 confidence와 z-order safety gate를 모두 통과한 것만 template로 승격하라.
- 반복성 없는 page role을 먼저 분류하라. 단일 페이지라도 self-contained lowest-z full-page underlay이면 `pageLocalBackground`로 PPTX `p:bg` 또는 검증된 Word section-local header underlay에 두고, 이것을 반복 `sharedTemplate`과 구분하라. `/Artifact` 역할도 geometry/z-safety를 통과해야 한다. Page number field는 실제 numbering 문자열이 동일할 때만 사용하라.
- 반복 mask가 page-local content를 SMask/clip/blend input으로 소비하면 template로 떼지 말고 local render-island dependency closure 안에 유지하라.
- PPTX master는 local foreground와 임의 interleave할 수 없으므로 foreground watermark를 무조건 master로 옮기지 마라. Page-local template 객체도 하나의 ‘KC Template Overlay’에 몰아넣지 말고 local 객체가 끼지 않는 maximal contiguous z-band별 group으로 나누며, 안전하지 않으면 개별 객체로 유지하라.
- DOCX header/footer story도 body foreground와 z-order가 검증되지 않으면 page-local drawing으로 되돌려라.

순수 Swift OOXML writer:

- OPCPackageWriter, OOXMLPartStore, ContentTypeRegistry, RelationshipGraph, MediaStore, XMLStreamWriter, PresentationMLWriter, WordprocessingMLWriter, OOXMLPackageValidator를 지침서 경계대로 구현하라.
- XML은 raw string interpolation으로 조립하지 말고 namespace와 escaping을 강제하는 typed builder/stream writer만 사용하라.
- relationship target, content type, part path, unique IDs, media hash, positive EMU extent를 작성 시점과 reopen 검증 시점에 모두 검사하라.
- External hyperlink는 정규화·길이/control/percent-encoding 검사를 통과한 `https`, `http`, `mailto`만 `TargetMode="External"`로 허용하라. `file`, `javascript`, `data`, `smb`, custom scheme와 위장 URL은 relationship/action을 만들지 말고 경고하라. Internal link는 실제 생성한 slide/bookmark ID만 허용하라.
- ZIP entry는 deterministic order로 streaming 작성하고 large media 전체를 메모리에 올리지 마라.
- 최소 PPTX는 theme, `presProps.xml`, `viewProps.xml`, `tableStyles.xml`, presentation→master/slide/properties, master→layout/theme, layout→master 관계와 `sldMasterIdLst`/`sldIdLst` numeric ID까지 지침서 14.2 inventory대로 생성·검증하라. 최소 DOCX와 함께 PowerPoint/Word repair dialog 없이 열리는 golden fixture로 고정하라.
- DOCX root `_rels/.rels`는 officeDocument뿐 아니라 포함한 `docProps/core.xml`과 `docProps/app.xml`의 core/extended property relationship을 정확히 연결하라. 각 section header/footer reference→document rels→part→part rels chain과 content type을 검증하고 orphan part를 허용하지 마라.
- PPTX는 한 file 내 slide size가 하나뿐인 제약을 지침서의 common canvas 정책으로 처리하고 왜곡하지 마라.
- DOCX는 reflow가 아닌 page-relative wp:anchor 기반 fixed-layout editable canvas로 구현하라. Section-local anchor host, drawing-only run, required anchor attributes와 `simplePos→positionH→positionV→extent→effectExtent→wrapNone→docPr→cNvGraphicFramePr→graphic` child order, global unique `docPr`를 typed builder와 reopen validator에서 강제하라.

구현 순서:

1. 네가 바꿀 파일, 새 module, dependency, test, 위험 요소를 포함한 짧은 계획을 먼저 제시하라.
2. Phase 0부터 Phase 7까지 docs/pdf_office_conversion_implementation_guide.md의 순서와 gate를 지켜라.
3. 각 Phase에서 production code와 해당 unit/contract/golden test를 함께 구현하라.
4. 각 Phase gate를 실행해 실패 원인을 고치고, 통과 증거를 남긴 뒤 다음 Phase로 이동하라.
5. scaffold, TODO, placeholder, fatalError stub, mock-only happy path를 완료로 보고하지 마라.
6. 현재 번역 기능의 회귀를 만들지 말고 기존 테스트 실패도 원인을 조사해 네 변경으로 인한 것이면 수정하라.
7. 불가능하거나 Office가 표현할 수 없는 PDF 효과는 silent loss가 아니라 최소 render island와 품질 보고서로 처리하라.

반드시 포함할 테스트:

- PDFSceneExtractionTests
- PDFContentStreamStateResolverTests
- PDFImageMaskTests
- PDFMaskSemanticTests
- PDFTransparencyIslandTests
- OfficeBackdropPolicyTests
- PDFTextReconstructionTests
- PDFTextCompositingSafetyTests
- PDFBidirectionalVerticalTextTests
- PDFType3TextFallbackTests
- OfficeTextBoxContractTests
- PDFVectorRecognitionTests
- PDFNativeGeometryEligibilityTests
- DocumentTemplateClassifierTests
- SinglePageTemplateRoleTests
- OfficeCapabilityPlannerTests
- PPTXWriterContractTests
- DOCXWriterContractTests
- OpenXMLPackageValidationTests
- ExternalRelationshipPolicyTests
- PDFWorkerProtocolTests
- PDFWorkerLifecycleTests
- PDFWorkerSandboxIntegrationTests
- DocumentConversionViewModelTests
- DocumentConversionOutputURLResolverTests
- DocumentConversionVisualRegressionTests
- LargePageTiledVisualValidationTests
- FileWorkspaceOperationGateTests
- FileSelectionSnapshotTests
- SecurityScopedConversionAccessTests
- DocumentConversionAppLifecycleTests
- DocumentConversionWorkspaceIntegrationTests
- DocumentConversionAccessibilityTests

`DOCXWriterContractTests`에는 multi-page/mixed section, root property relationships, body/header/footer relationship chain과 anchor, schema child order, z-order와 마지막 빈 페이지 방지 fixture를 포함하라. `PPTXWriterContractTests`에는 theme와 모든 presentation/master/layout relationship/ID inventory를 포함하라. Link test에는 allowed http(s)/mailto와 차단되는 file/javascript/data/custom/percent-encoded control URI를 모두 넣어라. Operation gate test는 두 public start 메서드의 same-turn 연속 호출, 자기 cancel 활성, mode 전환, 종료 중 hung/already-exited worker를 포함하고 selection test는 새 파일/clear와 OCR 재분석 generation을 구분하라.

필수 검증 명령은 저장소에 맞춰 실행하고, 최소한 다음을 포함하라.

swift package resolve
swift build
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency

Phase 0에서는 지침서의 GN args로 architecture별 complete static archive를 만든 뒤 같은 macOS platform universal archive와 XCFramework를 생성하라. 이후 PDFium artifact, 메인 app, native worker의 architecture와 linkage를 모두 검사하라. App target/link map에는 PDFium이 없고 worker link map에만 정적으로 존재해야 한다.

현재 `script/build_and_run.sh`의 host-only swift build를 universal 증거로 인정하지 마라. Release 경로는 architecture별 독립 `--scratch-path`와 `--triple arm64-apple-macosx14.0`/`x86_64-apple-macosx14.0`에서 `KCDeepL`과 `KCDeepLPDFWorker` product를 각각 build한 뒤 같은 product의 unsigned thin binary끼리만 lipo해야 한다. Worker helper app의 `Contents/MacOS`에 universal worker를 넣고 worker 전용 최소 entitlement로 helper를 먼저 서명한 뒤 바깥 app을 마지막에 서명하라. Debug worker도 Apple Development identity+worker sandbox entitlement로 먼저 서명한다. Release worker와 outer는 Developer ID+Hardened Runtime+secure timestamp를 각각 적용한다. `codesign --deep`은 서명에 금지하고 완성 bundle 검증에만 사용한다. Local debug는 host-only여도 된다.

file <검증할 정적 library 또는 app/worker executable의 실제 경로>
lipo -info <검증할 정적 library 또는 app/worker executable의 실제 경로>
otool -L <최종 app executable의 실제 경로>
otool -L <최종 worker executable의 실제 경로>

앱 bundle 검증은 기존 `script/build_and_run.sh`와 `docs/validation_plan.md`를 따르되, 현재 validation plan을 helper 구조/Info.plist, exact sandbox entitlement, helper/outer identifier·Team, 두 universal executable, inner-first/outer-last signing, 각각의 strict verification, runtime/timestamp와 notarization/stapler/`spctl`까지 갱신하라. 사용자 소유 `application/` 산출물을 무단 덮어쓰지 마라. 배포 검증은 새 staging에서 만든 실제 exported `.app`에만 수행한다. Credentialed distribution은 ditto ZIP→`notarytool submit --wait`→`stapler staple/validate`→`spctl --assess`로 검증하고, credential/network가 없으면 offline readiness라고만 보고 notarized라고 주장하지 마라. Local debug에 notarization이 필수라고 주장하지 마라.

시각 검증:

- Shipping runtime은 같은 PDFium build의 원본 reference와 CoreGraphics OfficePlanPreviewRenderer가 만든 native target-plan+island preview를 동일 DPI/sRGB로 비교하고, OOXML package structural validator를 통과시켜라. 이를 실제 Office 렌더 검증이라고 부르지 마라.
- macOS PowerPoint/Word가 설치된 opt-in release QA 환경에서는 generated OOXML을 open/export/reopen해 repair 여부와 실제 round-trip visual threshold를 corpus 전체에서 검증하라.
- Office가 설치되지 않았다는 이유만으로 사용자 변환 job을 실패시키지 마라. Per-job 보고서에는 internalPlanPreview와 officeRoundTripNotRun을 구분하고, release corpus가 실패한 converter build는 배포하지 마라.
- Office 미설치 CI의 자체 OOXML 검사나 Quick Look을 authoritative Office test라고 부르지 마라.
- 지침서의 SSIM, ΔE2000, edge F1, text bbox/baseline, alpha, template precision threshold를 적용하라.
- Large page가 pixel budget을 넘으면 source/target에 같은 bounded tile grid와 guard band를 적용해 metrics를 streaming 집계하라. 해상도를 조용히 낮추거나 거대한 full-page bitmap을 만들지 말고 tile seam/rotation/CropBox/Office fallback을 검증하라.
- Runtime internal-plan threshold 미달이면 font/geometry/alpha를 보정하고 render island를 확대하는 loop를 최대 횟수까지 수행하라. 그래도 실패하면 false success가 아니라 page/job 실패와 이유를 보고하라. Release Office corpus 차이는 production에서 Office를 호출해 즉석 보정하지 말고 capability rule과 golden regression을 수정한 새 build로 해결하라.

완료 보고 전에 docs/pdf_office_conversion_implementation_guide.md의 ‘완료 정의’를 항목별로 다시 대조하라. 품질 보고서에는 페이지별 native/raster/template 비율, fallback 이유, OCR/font substitution, mixed page-size 처리, visual metrics를 넣어라.

마지막 Git 절차:

- git diff와 git status로 의도한 변경만 확인하라.
- 사용자 소유 untracked 파일을 stage하지 마라.
- 구현·테스트·문서의 의도한 파일만 명시적으로 stage하고 commit하라.
- 원격 main의 최신 상태와 충돌 여부를 안전하게 확인하라.
- 모든 gate가 통과했을 때만 요청대로 GitHub main에 push하라.
- 최종 답변에는 구현 결과, 주요 fallback 원칙, 실행한 검증과 결과, 남은 경고, commit hash와 push 결과를 간결하게 적어라.

중요: 구현량이 크다는 이유만으로 중간 scaffold를 최종 답변으로 넘기지 마라. 안전한 범위에서 계속 구현·검증·개선하고, 실제 외부 권한·라이선스·누락된 필수 자산처럼 네가 해결할 수 없는 blocker가 생긴 경우에만 정확한 증거와 함께 사용자에게 요청하라.
```

## 사용 방법

Luna에게 이 파일만 보내는 것보다 저장소 전체를 열게 한 뒤 위 프롬프트를 전달해야 한다. Luna의 첫 응답에서 다음 항목이 확인되어야 구현을 시작해도 된다.

1. `docs/pdf_office_conversion_implementation_guide.md`를 최우선 source of truth로 인식했다.
2. `.NET/DLL/외부 converter`가 shipping runtime에서 금지됨을 명시했다.
3. `정적 PDFium XCFramework를 격리한 signed/sandboxed native Swift worker + ZIPFoundation + 순수 Swift OOXML writer` 구조를 계획에 반영했다.
4. Phase별 테스트 gate와 기존 untracked 파일 보존·최종 `main` push 조건을 계획에 포함했다.
5. Shared operation gate, selection snapshot/OCR generation 분리, `PendingPersistenceRegistry` 종료 회수를 현재 앱 통합 계획에 포함했다.
6. Text z-interleave, SMask Alpha/Luminosity, Type3/RTL/vertical, single-page background와 DOCX root relationship 보강을 테스트 계획에 포함했다.
7. Debug/release 서명 매트릭스, dual-architecture scratch/triple build, helper-first/outer-last signing과 credentialed notarization gate를 구분했다.

위 항목 중 하나라도 빠졌다면 코딩 전에 프롬프트 준수 여부부터 수정시킨다.
