import CryptoKit
import Foundation

struct WordprocessingMLWriter {
    private let emuPerPoint = 12_700.0
    private let twipsPerPoint = 20.0

    func makeParts(
        scene: PDFSceneDocument,
        options: DocumentConversionPipelineOptions = .default
    ) throws -> [OOXMLPart] {
        guard !scene.pages.isEmpty else {
            throw DocumentConversionError.emptyPDF
        }
        let templatePlan = makeTemplatePlan(scene: scene, options: options)
        var parts: [OOXMLPart] = []
        var relationships: [(id: String, type: String, target: String)] = [
            (
                "rId1",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles",
                "styles.xml"
            ),
            (
                "rId2",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings",
                "settings.xml"
            ),
            (
                "rId3",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme",
                "theme/theme1.xml"
            ),
            (
                "rId4",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable",
                "fontTable.xml"
            )
        ]
        var nextRelationshipID = 5
        var nextDocPrID = 1
        var imageAssetNames: [String: String] = [:]
        let headerRelationshipID: String?
        if templatePlan.hasHeader {
            let relationshipID = "rId\(nextRelationshipID)"
            nextRelationshipID += 1
            headerRelationshipID = relationshipID
            relationships.append(
                (
                    relationshipID,
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header",
                    "header1.xml"
                )
            )
        } else {
            headerRelationshipID = nil
        }

        var headerImageRelationships: [(image: PDFSceneImage, id: String)] = []
        var nextHeaderRelationshipID = 1
        var seenHeaderImageKeys = Set<String>()
        let headerImages = (templatePlan.backgroundImage.map { [$0] } ?? [])
            + templatePlan.images
        for image in headerImages {
            let key = templateImageKey(image)
            guard seenHeaderImageKeys.insert(key).inserted else { continue }
            let relationshipID = "rId\(nextHeaderRelationshipID)"
            nextHeaderRelationshipID += 1
            let assetName = options.imageGroupingLevel == .split
                ? "template-object-\(headerImageRelationships.count + 1).png"
                : OfficeImageAssetGrouping.sharedFilename(for: key)
            imageAssetNames[key] = assetName
            parts.append(
                try OOXMLPart(
                    name: "word/media/\(assetName)",
                    data: image.pngData
                )
            )
            headerImageRelationships.append((image, relationshipID))
        }

        var pageXML = ""

        for page in scene.pages {
            try Task.checkCancellation()
            let pageRasterRelationshipID: String?
            if templatePlan.backgroundImage == nil {
                let imageName = "word/media/image\(page.pageIndex + 1).png"
                let relationshipID = "rId\(nextRelationshipID)"
                nextRelationshipID += 1
                pageRasterRelationshipID = relationshipID
                parts.append(try OOXMLPart(name: imageName, data: page.pageImagePNG))
                relationships.append(
                    (
                        relationshipID,
                        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                        "media/image\(page.pageIndex + 1).png"
                    )
                )
            } else {
                pageRasterRelationshipID = nil
            }
            var imageRelationships: [(image: PDFSceneImage, id: String)] = []
            let nativeImages = page.images.filter {
                $0.canRecreate(
                    onPageSafetyNet: page.usesPageRasterFallback,
                    options: options
                ) && !templatePlan.imageKeys.contains(templateImageKey($0))
            }
            for (offset, image) in nativeImages.enumerated() {
                let imageRelationshipID = "rId\(nextRelationshipID)"
                nextRelationshipID += 1
                let assetKey = OfficeImageAssetGrouping.key(
                    image: image,
                    pageIndex: page.pageIndex,
                    occurrenceIndex: offset,
                    level: options.imageGroupingLevel
                )
                let assetName: String
                if let existing = imageAssetNames[assetKey] {
                    assetName = existing
                } else {
                    assetName = options.imageGroupingLevel == .split
                        ? "object-\(page.pageIndex + 1)-\(offset + 1).png"
                        : OfficeImageAssetGrouping.sharedFilename(for: assetKey)
                    imageAssetNames[assetKey] = assetName
                    parts.append(
                        try OOXMLPart(
                            name: "word/media/\(assetName)",
                            data: image.pngData
                        )
                    )
                }
                relationships.append(
                    (
                        imageRelationshipID,
                        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                        "media/\(assetName)"
                    )
                )
                imageRelationships.append((image, imageRelationshipID))
            }

            let pageGeometry = WordPageGeometry(page: page)
            let drawings = makePageDrawings(
                page: page,
                geometry: pageGeometry,
                imageRelationshipID: pageRasterRelationshipID,
                imageRelationships: imageRelationships,
                nextDocPrID: &nextDocPrID,
                options: options,
                templateTextBoxKeys: templatePlan.textBoxKeys,
                templateImageKeys: templatePlan.imageKeys
            )
            let documentText = makeDocumentTextParagraphs(
                page: page,
                options: options,
                templateTextBoxKeys: templatePlan.textBoxKeys
            )
            pageXML += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"1\" w:lineRule=\"exact\"/></w:pPr>\(drawings)</w:p>\(documentText)"
            if page.pageIndex < scene.pages.count - 1 {
                pageXML += "<w:p><w:pPr><w:sectPr>\(sectionProperties(for: pageGeometry, headerRelationshipID: headerRelationshipID))</w:sectPr></w:pPr></w:p>"
            }
        }

        let finalGeometry = WordPageGeometry(page: scene.pages.last!)
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:w10="urn:schemas-microsoft-com:office:word" xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" mc:Ignorable="w14 wp14"><w:body>\(pageXML)<w:sectPr>\(sectionProperties(for: finalGeometry, headerRelationshipID: headerRelationshipID))</w:sectPr></w:body></w:document>
        """
        parts.append(try OOXMLPart(name: "word/document.xml", xml: documentXML))
        parts.append(try OOXMLPart(name: "word/_rels/document.xml.rels", xml: relationshipsXML(relationships)))
        if templatePlan.hasHeader,
           let firstPage = scene.pages.first {
            let headerXML = makeHeaderXML(
                firstPage: firstPage,
                plan: templatePlan,
                geometry: WordPageGeometry(page: firstPage),
                imageRelationships: headerImageRelationships
            )
            parts.append(try OOXMLPart(name: "word/header1.xml", xml: headerXML))
            let headerRelationships: [(id: String, type: String, target: String)] = headerImageRelationships.compactMap { entry in
                guard let assetName = imageAssetNames[templateImageKey(entry.image)] else {
                    return nil
                }
                return (
                    id: entry.id,
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                    target: "media/\(assetName)"
                )
            }
            parts.append(
                try OOXMLPart(
                    name: "word/_rels/header1.xml.rels",
                    xml: relationshipsXML(headerRelationships)
                )
            )
        }
        parts.append(try OOXMLPart(name: "word/styles.xml", xml: Self.stylesXML))
        parts.append(try OOXMLPart(name: "word/settings.xml", xml: Self.settingsXML))
        parts.append(try OOXMLPart(name: "word/theme/theme1.xml", xml: Self.themeXML))
        parts.append(
            try OOXMLPart(
                name: "word/fontTable.xml",
                xml: fontTableXML(scene: scene)
            )
        )
        parts.append(try OOXMLPart(name: "docProps/core.xml", xml: Self.coreProperties))
        parts.append(try OOXMLPart(name: "docProps/app.xml", xml: Self.appProperties))
        parts.append(try OOXMLPart(name: "_rels/.rels", xml: Self.rootRelationships))
        parts.append(try OOXMLPart(name: "[Content_Types].xml", xml: Self.contentTypes(pageCount: scene.pages.count, hasHeader: templatePlan.hasHeader)))
        return parts
    }
}

private struct WordTemplatePlan {
    let backgroundImage: PDFSceneImage?
    let textBoxes: [PDFSceneTextBox]
    let textBoxKeys: Set<String>
    let images: [PDFSceneImage]
    let imageKeys: Set<String>

    var hasHeader: Bool {
        backgroundImage != nil || !textBoxes.isEmpty || !images.isEmpty
    }

    static let empty = WordTemplatePlan(
        backgroundImage: nil,
        textBoxes: [],
        textBoxKeys: [],
        images: [],
        imageKeys: []
    )
}

private struct WordPageGeometry {
    let page: PDFScenePage
    let scale: CGFloat
    let widthPoints: CGFloat
    let heightPoints: CGFloat
    let widthTwips: Int
    let heightTwips: Int

    init(page: PDFScenePage) {
        self.page = page
        let rawWidth = max(1, page.width)
        let rawHeight = max(1, page.height)
        let maxTwips: CGFloat = 31_680
        self.scale = min(1, maxTwips / max(rawWidth * 20, rawHeight * 20))
        self.widthPoints = rawWidth * scale
        self.heightPoints = rawHeight * scale
        self.widthTwips = max(1, Int((widthPoints * 20).rounded()))
        self.heightTwips = max(1, Int((heightPoints * 20).rounded()))
    }
}

private extension WordprocessingMLWriter {
    func makeTemplatePlan(
        scene: PDFSceneDocument,
        options: DocumentConversionPipelineOptions
    ) -> WordTemplatePlan {
        guard options.templatePriority == .repeatedToTemplate,
              scene.pages.count > 1,
              let first = scene.pages.first
        else {
            return .empty
        }

        let sameCanvas = scene.pages.allSatisfy {
            abs($0.width - first.width) <= 0.01
                && abs($0.height - first.height) <= 0.01
                && abs($0.cropBox.minX - first.cropBox.minX) <= 0.01
                && abs($0.cropBox.minY - first.cropBox.minY) <= 0.01
        }

        let sharedTextFingerprints = scene.pages
            .map { page in
                Set(
                    page.templateObjects
                        .filter {
                            $0.role == .sharedTemplate
                                && $0.id.hasPrefix("template-chrome-")
                        }
                        .map(\.sourceFingerprint)
                )
            }
            .dropFirst()
            .reduce(
                Set(
                    first.templateObjects
                        .filter {
                            $0.role == .sharedTemplate
                                && $0.id.hasPrefix("template-chrome-")
                        }
                        .map(\.sourceFingerprint)
                )
            ) { partial, next in
                partial.intersection(next)
            }
        let firstTextFingerprintByKey = Dictionary(
            uniqueKeysWithValues: first.templateObjects
                .filter {
                    $0.role == .sharedTemplate
                        && $0.id.hasPrefix("template-chrome-")
                }
                .map {
                    (String($0.id.dropFirst("template-chrome-".count)), $0.sourceFingerprint)
                }
        )
        let textBoxes = first.textBoxes.filter { textBox in
            guard textBox.role == .templateChrome,
                  let fingerprint = firstTextFingerprintByKey[textBox.id]
            else {
                return false
            }
            return sharedTextFingerprints.contains(fingerprint)
                && textBox.canRecreateOnLayeredTemplate
        }

        let canPromoteImages = sameCanvas
            && scene.pages.allSatisfy { !$0.usesPageRasterFallback }
        let commonImageKeys: Set<String>
        if canPromoteImages {
            commonImageKeys = scene.pages
                .map { page in
                    Set(
                        page.images
                            .filter {
                                $0.hasVisibleReferenceContribution
                                    && $0.canRecreate(
                                        onPageSafetyNet: false,
                                        options: options
                                    )
                            }
                            .map(templateImageKey)
                    )
                }
                .dropFirst()
                .reduce(
                    Set(
                        first.images
                            .filter {
                                $0.hasVisibleReferenceContribution
                                    && $0.canRecreate(
                                        onPageSafetyNet: false,
                                        options: options
                                    )
                            }
                            .map(templateImageKey)
                    )
                ) { partial, next in
                    partial.intersection(next)
                }
        } else {
            commonImageKeys = []
        }

        let backgroundKey = commonImageKeys.first { key in
            first.images.contains { image in
                templateImageKey(image) == key
                    && image.bounds.minX <= first.cropBox.minX + 0.5
                    && image.bounds.minY <= first.cropBox.minY + 0.5
                    && image.bounds.maxX >= first.cropBox.maxX - 0.5
                    && image.bounds.maxY >= first.cropBox.maxY - 0.5
                    && !image.hasAlpha
                    && !image.maskApplied
            }
        }
        let backgroundImage = backgroundKey.flatMap { key in
            first.images.first { templateImageKey($0) == key }
        }
        let images = first.images.filter {
            let key = templateImageKey($0)
            return commonImageKeys.contains(key) && key != backgroundKey
        }
        let imageKeys = Set(images.map(templateImageKey))
            .union(backgroundImage.map { [templateImageKey($0)] } ?? [])
        return WordTemplatePlan(
            backgroundImage: backgroundImage,
            textBoxes: textBoxes,
            textBoxKeys: Set(textBoxes.map(templateTextKey)),
            images: images,
            imageKeys: imageKeys
        )
    }

    func templateTextKey(_ textBox: PDFSceneTextBox) -> String {
        "\(textBox.text)|\(textBox.bounds.debugDescription)|\(textBox.alignment.rawValue)"
    }

    func templateImageKey(_ image: PDFSceneImage) -> String {
        let digest = SHA256.hash(data: image.pngData)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        let clipDescription = image.clip?.bounds.debugDescription ?? ""
        return "\(digest)|\(image.bounds.debugDescription)|\(clipDescription)"
    }

    func makeHeaderXML(
        firstPage: PDFScenePage,
        plan: WordTemplatePlan,
        geometry: WordPageGeometry,
        imageRelationships: [(image: PDFSceneImage, id: String)]
    ) -> String {
        var drawings = ""
        var nextDocPrID = 1
        let imageExtent = (
            cx: emu(geometry.widthPoints),
            cy: emu(geometry.heightPoints)
        )
        if let backgroundImage = plan.backgroundImage,
           let relationshipID = imageRelationships.first(where: {
               templateImageKey($0.image) == templateImageKey(backgroundImage)
           })?.id {
            drawings += "<w:r><w:drawing>\(imageAnchor(page: firstPage, geometry: geometry, relationshipID: relationshipID, docPrID: nextDocPrID, extent: imageExtent))</w:drawing></w:r>"
            nextDocPrID += 1
        }
        for image in plan.images {
            guard let relationshipID = imageRelationships.first(where: {
                templateImageKey($0.image) == templateImageKey(image)
            })?.id else {
                continue
            }
            let bounds = image.officeBounds
            let x = emu((bounds.minX - firstPage.cropBox.minX) * geometry.scale)
            let y = emu((firstPage.height - (bounds.maxY - firstPage.cropBox.minY)) * geometry.scale)
            let width = emu(max(1, bounds.width * geometry.scale))
            let height = emu(max(1, bounds.height * geometry.scale))
            drawings += "<w:r><w:drawing>\(imageAnchor(image: image, x: x, y: y, width: width, height: height, relationshipID: relationshipID, docPrID: nextDocPrID))</w:drawing></w:r>"
            nextDocPrID += 1
        }
        for textBox in plan.textBoxes {
            let bounds = textBox.officeBounds
            let x = emu((bounds.minX - firstPage.cropBox.minX) * geometry.scale)
            let y = emu((firstPage.height - (bounds.maxY - firstPage.cropBox.minY)) * geometry.scale)
            let width = emu(max(1, bounds.width * geometry.scale))
            let height = emu(max(1, bounds.height * geometry.scale))
            drawings += "<w:r><w:drawing>\(textAnchor(textBox: textBox, x: x, y: y, width: width, height: height, docPrID: nextDocPrID, locked: true))</w:drawing></w:r>"
            nextDocPrID += 1
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" mc:Ignorable="w14 wp14"><w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="1" w:lineRule="exact"/></w:pPr>\(drawings)</w:p></w:hdr>
        """
    }

    func makePageDrawings(
        page: PDFScenePage,
        geometry: WordPageGeometry,
        imageRelationshipID: String?,
        imageRelationships: [(image: PDFSceneImage, id: String)],
        nextDocPrID: inout Int,
        options: DocumentConversionPipelineOptions,
        templateTextBoxKeys: Set<String>,
        templateImageKeys: Set<String>
    ) -> String {
        let imageExtent = (
            cx: emu(geometry.widthPoints),
            cy: emu(geometry.heightPoints)
        )
        var result = ""
        if let imageRelationshipID {
            result = "<w:r><w:drawing>\(imageAnchor(page: page, geometry: geometry, relationshipID: imageRelationshipID, docPrID: nextDocPrID, extent: imageExtent))</w:drawing></w:r>"
            nextDocPrID += 1
        }
        enum Overlay {
            case image(PDFSceneImage, String)
            case vector(PDFSceneVector)
        }
        let nativeImages = page.images.filter {
                $0.canRecreate(
                    onPageSafetyNet: page.usesPageRasterFallback,
                    options: options
                ) && !templateImageKeys.contains(templateImageKey($0))
        }
        let imageOverlays = nativeImages.map { image in
            Overlay.image(
                image,
                imageRelationships.first(where: { $0.image.id == image.id })?.id ?? ""
            )
        }
        let nativeVectors = page.vectors.filter {
            $0.canRecreate(
                onPageSafetyNet: page.usesPageRasterFallback,
                options: options
            )
        }
        let overlays: [Overlay]
        if page.usesPageRasterFallback {
            overlays = imageOverlays + nativeVectors.map(Overlay.vector)
        } else {
            overlays = nativeVectors.map(Overlay.vector) + imageOverlays
        }
        func overlaySortKey(_ overlay: Overlay) -> (order: Int, kind: Int, id: String) {
            switch overlay {
            case let .image(image, _):
                return (image.paintOrder, 0, image.id)
            case let .vector(vector):
                return (vector.paintOrder, 1, vector.id)
            }
        }
        let orderedOverlays: [Overlay]
        if page.usesPageRasterFallback {
            orderedOverlays = overlays.sorted(by: { lhs, rhs in
            let left = overlaySortKey(lhs)
            let right = overlaySortKey(rhs)
            if left.order != right.order { return left.order < right.order }
            if left.kind != right.kind { return left.kind < right.kind }
            return left.id < right.id
            })
        } else {
            orderedOverlays = overlays
        }
        for overlay in orderedOverlays {
            switch overlay {
            case let .image(image, relationshipID) where !relationshipID.isEmpty:
                let x = emu((image.bounds.minX - page.cropBox.minX) * geometry.scale)
                let y = emu((page.height - (image.bounds.maxY - page.cropBox.minY)) * geometry.scale)
                let width = emu(max(1, image.bounds.width * geometry.scale))
                let height = emu(max(1, image.bounds.height * geometry.scale))
                result += "<w:r><w:drawing>\(imageAnchor(image: image, x: x, y: y, width: width, height: height, relationshipID: relationshipID, docPrID: nextDocPrID))</w:drawing></w:r>"
                nextDocPrID += 1
            case let .vector(vector):
                let x = emu((vector.bounds.minX - page.cropBox.minX) * geometry.scale)
                let y = emu((page.height - (vector.bounds.maxY - page.cropBox.minY)) * geometry.scale)
                let width = emu(max(1, vector.bounds.width * geometry.scale))
                let height = emu(max(1, vector.bounds.height * geometry.scale))
                result += "<w:r><w:drawing>\(vectorAnchor(vector: vector, x: x, y: y, width: width, height: height, docPrID: nextDocPrID))</w:drawing></w:r>"
                nextDocPrID += 1
            default:
                break
            }
        }
        let templateTextBoxes = page.usesPageRasterFallback
            ? []
            : page.textBoxes.filter {
                $0.role == .templateChrome && $0.canRecreateOnLayeredTemplate
                    && !templateTextBoxKeys.contains(templateTextKey($0))
            }
        let contentTextBoxes = page.textBoxes.filter {
            $0.role == .editableContent
                && $0.canRecreateOnLayeredTemplate
                && shouldUseFloatingTextBox($0, options: options)
        }
        for textBox in templateTextBoxes {
            let bounds = textBox.officeBounds
            let x = emu((bounds.minX - page.cropBox.minX) * geometry.scale)
            let y = emu((page.height - (bounds.maxY - page.cropBox.minY)) * geometry.scale)
            let width = emu(max(1, bounds.width * geometry.scale))
            let height = emu(max(1, bounds.height * geometry.scale))
            result += "<w:r><w:drawing>\(textAnchor(textBox: textBox, x: x, y: y, width: width, height: height, docPrID: nextDocPrID, locked: true))</w:drawing></w:r>"
            nextDocPrID += 1
        }
        for textBox in contentTextBoxes {
            let bounds = textBox.officeBounds
            let x = emu((bounds.minX - page.cropBox.minX) * geometry.scale)
            let y = emu((page.height - (bounds.maxY - page.cropBox.minY)) * geometry.scale)
            let width = emu(max(1, bounds.width * geometry.scale))
            let height = emu(max(1, bounds.height * geometry.scale))
            result += "<w:r><w:drawing>\(textAnchor(textBox: textBox, x: x, y: y, width: width, height: height, docPrID: nextDocPrID))</w:drawing></w:r>"
            nextDocPrID += 1
        }
        return result
    }

    func makeDocumentTextParagraphs(
        page: PDFScenePage,
        options: DocumentConversionPipelineOptions,
        templateTextBoxKeys: Set<String>
    ) -> String {
        guard options.wordTextRepresentation == .documentText else {
            return ""
        }
        return page.textBoxes
            .filter {
                $0.role == .editableContent
                    && $0.canRecreateOnLayeredTemplate
                    && !templateTextBoxKeys.contains(templateTextKey($0))
                    && !shouldUseFloatingTextBox($0, options: options)
            }
            .map(textBoxContent)
            .joined()
    }

    func shouldUseFloatingTextBox(
        _ textBox: PDFSceneTextBox,
        options: DocumentConversionPipelineOptions
    ) -> Bool {
        guard options.wordTextRepresentation == .documentText else {
            return true
        }
        switch options.wordTextBoxAllowance {
        case .never:
            return false
        case .conservative, .balanced, .permissive:
            break
        }

        let fontNames = Set(textBox.lines.flatMap { $0.runs.map(\.fontName) })
        let hasMixedFonts = fontNames.count > 1
        let hasTabs = textBox.lines.contains {
            $0.listTabStop != nil || $0.runs.contains { $0.text.contains("\t") }
        }
        let offsets = textBox.lines.map { $0.bounds.minX - textBox.bounds.minX }
        let indentRange = (offsets.max() ?? 0) - (offsets.min() ?? 0)
        let referenceSize = max(5, textBox.fontSize)
        let hasLargeIndentDrift = indentRange > max(6, referenceSize * 0.5)
        let hasNonLeftMultiLineLayout = textBox.lines.count > 1
            && textBox.alignment != .left

        switch options.wordTextBoxAllowance {
        case .never:
            return false
        case .conservative:
            return hasMixedFonts || hasTabs || indentRange > max(12, referenceSize)
        case .balanced:
            return hasMixedFonts || hasTabs || hasLargeIndentDrift
                || hasNonLeftMultiLineLayout
        case .permissive:
            return hasMixedFonts || hasTabs || hasLargeIndentDrift
                || hasNonLeftMultiLineLayout || textBox.lines.count > 1
        }
    }

    func imageAnchor(
        page: PDFScenePage,
        geometry: WordPageGeometry,
        relationshipID: String,
        docPrID: Int,
        extent: (cx: Int, cy: Int)
    ) -> String {
        anchorPrefix(
            x: 0,
            y: 0,
            width: extent.cx,
            height: extent.cy,
            // Keep the page raster at the bottom of Word's drawing layer.
            // Some Office renderers otherwise use the XML insertion order for
            // transparent PNG pixels and allow an opaque source mask to cover
            // a later textbox despite `behindDoc` being set.
            relativeHeight: 0,
            behindDocument: true,
            locked: true
        ) + """
        <wp:docPr id="\(docPrID)" name="PDF page \(page.pageIndex + 1)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(docPrID)" name="PDF page \(page.pageIndex + 1)"/><pic:cNvPicPr preferRelativeResize="0"/><pic:nvPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(XMLValue.attribute(relationshipID))"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(extent.cx)" cy="\(extent.cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:anchor>
        """
    }

    func vectorAnchor(
        vector: PDFSceneVector,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        docPrID: Int
    ) -> String {
        let fill = vector.fill.map { "<a:solidFill>\(solidFillBody($0))</a:solidFill>" } ?? "<a:noFill/>"
        let line = vector.stroke.map {
            "<a:ln w=\"\(max(1, Int((Double(vector.lineWidth) * emuPerPoint).rounded())))\"><a:solidFill>\(solidFillBody($0))</a:solidFill></a:ln>"
        } ?? "<a:ln><a:noFill/></a:ln>"
        let rotation = vector.kind == .line ? 0 : Int((vector.rotation * 60_000).rounded())
        let geometry: String
        switch vector.kind {
        case .line:
            geometry = "<a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom>"
        case .rectangle, .ellipse:
            geometry = "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
        case .freeform:
            geometry = customGeometry(
                for: vector,
                width: width,
                height: height
            )
        }
        let shape = "<wps:wsp><wps:cNvSpPr/><wps:spPr><a:xfrm rot=\"\(rotation)\"><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm>\(geometry)\(fill)\(line)</wps:spPr><wps:bodyPr/></wps:wsp>"
        return anchorPrefix(
            x: x,
            y: y,
            width: width,
            height: height,
            relativeHeight: 1_000_000 + docPrID,
            behindDocument: false
        ) + "<wp:docPr id=\"\(docPrID)\" name=\"PDF \(vector.kind.rawValue) \(docPrID)\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\">\(shape)</a:graphicData></a:graphic></wp:anchor>"
    }

    func customGeometry(
        for vector: PDFSceneVector,
        width: Int,
        height: Int
    ) -> String {
        let pathWidth = max(1, width)
        let pathHeight = max(1, height)
        let commands = vector.pathCommands.map { command -> String in
            switch command {
            case let .move(point):
                return "<a:moveTo>\(customPathPoint(point, in: vector))</a:moveTo>"
            case let .line(point):
                return "<a:lnTo>\(customPathPoint(point, in: vector))</a:lnTo>"
            case let .cubic(control1, control2, end):
                return "<a:cubicBezTo>\(customPathPoint(control1, in: vector))\(customPathPoint(control2, in: vector))\(customPathPoint(end, in: vector))</a:cubicBezTo>"
            case .close:
                return "<a:close/>"
            }
        }.joined()
        return "<a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/><a:rect l=\"l\" t=\"t\" r=\"r\" b=\"b\"/><a:pathLst><a:path w=\"\(pathWidth)\" h=\"\(pathHeight)\">\(commands)</a:path></a:pathLst></a:custGeom>"
    }

    func customPathPoint(
        _ point: CGPoint,
        in vector: PDFSceneVector
    ) -> String {
        let x = max(
            0,
            Int(((point.x - vector.bounds.minX) * emuPerPoint).rounded())
        )
        let y = max(
            0,
            Int(((vector.bounds.maxY - point.y) * emuPerPoint).rounded())
        )
        return "<a:pt x=\"\(x)\" y=\"\(y)\"/>"
    }

    func textAnchor(
        textBox: PDFSceneTextBox,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        docPrID: Int,
        locked: Bool = false
    ) -> String {
        let leadingInset = textMarginEMU(textBox.officeLeadingInset)
        let trailingInset = textMarginEMU(textBox.officeTrailingInset)
        let shape = """
        <wps:wsp><wps:cNvSpPr txBox="1">\(locked ? "<a:spLocks noSelect=\"1\" noGrp=\"1\" noTextEdit=\"1\" noMove=\"1\" noResize=\"1\" noRot=\"1\"/>" : "")</wps:cNvSpPr><wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></wps:spPr><wps:txbx><w:txbxContent>\(textBoxContent(textBox))</w:txbxContent></wps:txbx><wps:bodyPr rot="0" vert="horz" wrap="none" lIns="\(leadingInset)" tIns="0" rIns="\(trailingInset)" bIns="0" anchor="t"><a:noAutofit/></wps:bodyPr></wps:wsp>
        """
        return anchorPrefix(
            x: x,
            y: y,
            width: width,
            height: height,
            relativeHeight: locked ? docPrID : 1_000_000 + docPrID,
            behindDocument: false,
            locked: locked
        ) + "<wp:docPr id=\"\(docPrID)\" name=\"Text \(docPrID)\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\">\(shape)</a:graphicData></a:graphic></wp:anchor>"
    }

    func imageAnchor(
        image: PDFSceneImage,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        relationshipID: String,
        docPrID: Int
    ) -> String {
        anchorPrefix(
            x: x,
            y: y,
            width: width,
            height: height,
            relativeHeight: docPrID,
            behindDocument: false
        ) + "<wp:docPr id=\"\(docPrID)\" name=\"PDF image \(XMLValue.attribute(image.sourceName))\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(docPrID)\" name=\"PDF image \(XMLValue.attribute(image.sourceName))\"/><pic:cNvPicPr preferRelativeResize=\"0\"/><pic:nvPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(XMLValue.attribute(relationshipID))\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:anchor>"
    }

    func anchorPrefix(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        relativeHeight: Int,
        behindDocument: Bool,
        locked: Bool = false
    ) -> String {
        "<wp:anchor distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\" simplePos=\"0\" relativeHeight=\"\(relativeHeight)\" behindDoc=\"\(behindDocument ? 1 : 0)\" locked=\"\(locked ? 1 : 0)\" layoutInCell=\"1\" allowOverlap=\"1\"><wp:simplePos x=\"0\" y=\"0\"/><wp:positionH relativeFrom=\"page\"><wp:posOffset>\(x)</wp:posOffset></wp:positionH><wp:positionV relativeFrom=\"page\"><wp:posOffset>\(y)</wp:posOffset></wp:positionV><wp:extent cx=\"\(width)\" cy=\"\(height)\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/><wp:wrapNone/>"
    }

    func textBoxContent(_ textBox: PDFSceneTextBox) -> String {
        let alignment: String
        switch textBox.alignment {
        case .left: alignment = "left"
        case .center: alignment = "center"
        case .right: alignment = "right"
        }
        let lines = textBox.lines.isEmpty
            ? [
                PDFSceneTextLine(
                    id: textBox.id,
                    text: textBox.text,
                    bounds: textBox.bounds,
                    runs: [
                        PDFSceneTextRun(
                            PDFTextRun(
                                text: textBox.text,
                                fontName: textBox.fontName,
                                fontSize: textBox.fontSize,
                                textColor: textBox.color,
                                isOfficeCompatible: true
                            )
                        )
                    ],
                    sourceMaskBounds: textBox.bounds,
                    sourceMaskIsSafe: true,
                    extractionSource: textBox.extractionSource
                )
            ]
            : textBox.lines
        return lines.enumerated().map { index, line in
            let previousLine = index > 0 ? lines[index - 1] : nil
            let spacing = lineSpacingTwips(
                for: line,
                previousLine: previousLine
            )
            let insets = textBox.paragraphInsets(for: line)
            let indentation = wordParagraphIndent(insets)
            let tabs = wordTabStops(for: line, in: textBox)
            let runs = line.runs.isEmpty
                ? wordRun(
                    PDFSceneTextRun(
                        PDFTextRun(
                            text: line.text,
                            fontName: textBox.fontName,
                            fontSize: textBox.fontSize,
                            textColor: textBox.color,
                            isOfficeCompatible: true
                        )
                    )
                )
                : line.runs.map(wordRun).joined()
            return "<w:p><w:pPr>\(tabs)<w:spacing w:before=\"0\" w:after=\"0\" w:line=\"\(spacing)\" w:lineRule=\"atLeast\"/>\(indentation)<w:jc w:val=\"\(alignment)\"/></w:pPr>\(runs)</w:p>"
        }.joined()
    }

    func wordRun(_ run: PDFSceneTextRun) -> String {
        let color = rgbHex(run.color)
        let fontSize = max(2, min(144, Int((run.fontSize * 2).rounded())))
        let bold = run.isBold ? "<w:b/><w:bCs/>" : ""
        let italic = run.isItalic ? "<w:i/><w:iCs/>" : ""
        return "<w:r><w:rPr><w:rFonts w:ascii=\"\(XMLValue.attribute(run.fontName))\" w:hAnsi=\"\(XMLValue.attribute(run.fontName))\" w:eastAsia=\"\(XMLValue.attribute(run.fontName))\" w:cs=\"\(XMLValue.attribute(run.fontName))\"/><w:sz w:val=\"\(fontSize)\"/><w:szCs w:val=\"\(fontSize)\"/><w:color w:val=\"\(color)\"/>\(bold)\(italic)</w:rPr>\(wordTextElements(run.text))</w:r>"
    }

    func wordTabStops(
        for line: PDFSceneTextLine,
        in textBox: PDFSceneTextBox
    ) -> String {
        guard let sourceOffset = line.listTabStop,
              line.runs.contains(where: { $0.text.contains("\t") })
        else {
            return ""
        }
        let relativeOffset = max(
            0.5,
            line.bounds.minX + sourceOffset - textBox.bounds.minX
        )
        let position = max(1, Int((relativeOffset * twipsPerPoint).rounded()))
        return "<w:tabs><w:tab w:val=\"left\" w:pos=\"\(position)\"/></w:tabs>"
    }

    func wordParagraphIndent(_ insets: PDFSceneTextParagraphInsets) -> String {
        guard insets.leading > 0.01 || insets.trailing > 0.01 else {
            return ""
        }
        return "<w:ind w:left=\"\(twips(insets.leading))\" w:right=\"\(twips(insets.trailing))\" w:firstLine=\"0\"/>"
    }

    func wordTextElements(_ text: String) -> String {
        var elements = ""
        var fragment = ""
        func appendFragment() {
            guard !fragment.isEmpty else { return }
            elements += "<w:t xml:space=\"preserve\">\(XMLValue.escape(fragment, preserveWhitespace: true))</w:t>"
            fragment.removeAll(keepingCapacity: true)
        }
        for character in text {
            if character == "\t" {
                appendFragment()
                elements += "<w:tab/>"
            } else {
                fragment.append(character)
            }
        }
        appendFragment()
        return elements
    }

    func lineSpacingTwips(
        for line: PDFSceneTextLine,
        previousLine: PDFSceneTextLine?
    ) -> Int {
        let sourceAdvance = previousLine.map {
            // Selection tops preserve baseline-to-baseline advancement. The
            // rendered-ink measurement is intentionally reserved for the
            // text frame's initial top anchor, where it is stable and useful.
            max(0, $0.bounds.maxY - line.bounds.maxY)
        } ?? 0
        let fontHeight = line.runs.map(\.fontSize).max() ?? line.bounds.height
        let points = max(line.bounds.height, fontHeight * 1.05, sourceAdvance)
        return max(1, Int((points * twipsPerPoint).rounded()))
    }

    func fontTableXML(scene: PDFSceneDocument) -> String {
        let fonts = Set(
            scene.pages.flatMap { page in
                page.textBoxes.flatMap { textBox in
                    textBox.lines.flatMap(\.runs).map(\.fontName)
                }
            }
        ).union(["Arial"])
        let body = fonts.sorted().map { fontName in
            "<w:font w:name=\"\(XMLValue.attribute(fontName))\"><w:family w:val=\"\(fontFamily(for: fontName))\"/><w:charset w:val=\"00\"/></w:font>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:fonts xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(body)</w:fonts>"
    }

    func fontFamily(for fontName: String) -> String {
        let normalized = fontName.lowercased()
        if normalized.contains("courier") || normalized.contains("mono") {
            return "modern"
        }
        if normalized.contains("times") || normalized.contains("serif") || normalized.contains("cambria") {
            return "roman"
        }
        return "swiss"
    }

    func sectionProperties(
        for geometry: WordPageGeometry,
        headerRelationshipID: String? = nil
    ) -> String {
        let orientation = geometry.widthPoints > geometry.heightPoints ? " w:orient=\"landscape\"" : ""
        let header = headerRelationshipID.map {
            "<w:headerReference w:type=\"default\" r:id=\"\(XMLValue.attribute($0))\"/>"
        } ?? ""
        return "\(header)<w:pgSz w:w=\"\(geometry.widthTwips)\" w:h=\"\(geometry.heightTwips)\"\(orientation)/><w:pgMar w:top=\"0\" w:right=\"0\" w:bottom=\"0\" w:left=\"0\" w:header=\"0\" w:footer=\"0\" w:gutter=\"0\"/><w:cols w:space=\"0\"/><w:docGrid w:linePitch=\"1\"/>"
    }

    func emu(_ points: CGFloat) -> Int {
        max(1, Int((Double(points) * emuPerPoint).rounded()))
    }

    func textMarginEMU(_ points: CGFloat) -> Int {
        max(0, Int((Double(points) * emuPerPoint).rounded()))
    }

    func twips(_ points: CGFloat) -> Int {
        max(0, Int((Double(points) * twipsPerPoint).rounded()))
    }

    func rgbHex(_ color: PDFTextColor) -> String {
        [color.red, color.green, color.blue]
            .map { String(format: "%02X", Int((max(0, min(1, $0)) * 255).rounded())) }
            .joined()
    }

    func solidFillBody(_ color: PDFTextColor) -> String {
        let hex = rgbHex(color)
        let alpha = Int((max(0, min(1, color.alpha)) * 100_000).rounded())
        return "<a:srgbClr val=\"\(hex)\"><a:alpha val=\"\(alpha)\"/></a:srgbClr>"
    }

    func relationshipsXML(_ relationships: [(id: String, type: String, target: String)]) -> String {
        let body = relationships.map {
            "<Relationship Id=\"\(XMLValue.attribute($0.id))\" Type=\"\(XMLValue.attribute($0.type))\" Target=\"\(XMLValue.attribute($0.target))\"/>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(body)</Relationships>"
    }

    static let rootRelationships = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>"

    static let coreProperties = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>KC DeepL PDF 변환</dc:title><dc:creator>KC DeepL</dc:creator><cp:lastModifiedBy>KC DeepL</cp:lastModifiedBy><dcterms:created xsi:type=\"dcterms:W3CDTF\">2000-01-01T00:00:00Z</dcterms:created></cp:coreProperties>"
    static let appProperties = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\"><Application>KC DeepL</Application><AppVersion>1.0</AppVersion></Properties>"

    static func contentTypes(pageCount: Int, hasHeader: Bool = false) -> String {
        let overrides = [
            "/word/document.xml|application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
            "/word/styles.xml|application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml",
            "/word/settings.xml|application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml",
            "/word/theme/theme1.xml|application/vnd.openxmlformats-officedocument.theme+xml",
            "/word/fontTable.xml|application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"
        ] + (hasHeader
            ? ["/word/header1.xml|application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"]
            : [])
        let images = (1...pageCount).map { _ in "" }.joined()
        _ = images
        let overrideXML = overrides.map { item in
            let parts = item.split(separator: "|", maxSplits: 1).map(String.init)
            return "<Override PartName=\"\(parts[0])\" ContentType=\"\(parts[1])\"/>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/><Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>\(overrideXML)</Types>"
    }

    static let stylesXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:eastAsia=\"Arial\" w:cs=\"Arial\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"0\" w:line=\"1\" w:lineRule=\"exact\"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style></w:styles>"
    static let settingsXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:zoom w:percent=\"100\"/><w:doNotTrackFormatting/><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"
    static let themeXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="KC DeepL"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F2937"/></a:dk2><a:lt2><a:srgbClr val="F3F4F6"/></a:lt2><a:accent1><a:srgbClr val="2563EB"/></a:accent1><a:accent2><a:srgbClr val="7C3AED"/></a:accent2><a:accent3><a:srgbClr val="059669"/></a:accent3><a:accent4><a:srgbClr val="D97706"/></a:accent4><a:accent5><a:srgbClr val="DC2626"/></a:accent5><a:accent6><a:srgbClr val="0891B2"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst/><a:lnStyleLst/><a:effectStyleLst/><a:bgFillStyleLst/></a:fmtScheme></a:themeElements></a:theme>
    """
}
