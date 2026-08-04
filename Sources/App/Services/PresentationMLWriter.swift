import CryptoKit
import Foundation

struct PresentationMLWriter {
    private let emuPerPoint = 12_700.0

    private struct MasterPlan {
        let backgroundPage: PDFScenePage?
        /// Fingerprint of the repeated page-level background represented by
        /// `backgroundPage`.  A deck can contain title/divider slides with a
        /// different background, so only slides carrying this fingerprint may
        /// omit their local raster and reveal the master layer.
        let backgroundTemplateFingerprint: String?
        /// A decoded, repeated full-page PDF image that can be used as a
        /// true master background. Unlike a page screenshot this leaves the
        /// slide-local text/images above it editable.
        let backgroundImage: PDFSceneImage?
        let textBoxes: [PDFSceneTextBox]
        let textBoxKeys: Set<String>
        let vectors: [PDFSceneVector]
        let vectorKeys: Set<String>
        let images: [PDFSceneImage]
        let imageKeys: Set<String>

        static let empty = MasterPlan(
            backgroundPage: nil,
            backgroundTemplateFingerprint: nil,
            backgroundImage: nil,
            textBoxes: [],
            textBoxKeys: [],
            vectors: [],
            vectorKeys: [],
            images: [],
            imageKeys: []
        )
    }

    func makeParts(
        scene: PDFSceneDocument,
        options: DocumentConversionPipelineOptions = .default
    ) throws -> [OOXMLPart] {
        guard let first = scene.pages.first else {
            throw DocumentConversionError.emptyPDF
        }
        let canvasWidth = max(1, scene.pages.map(\.width).max() ?? first.width)
        let canvasHeight = max(1, scene.pages.map(\.height).max() ?? first.height)
        let slideWidth = emu(canvasWidth)
        let slideHeight = emu(canvasHeight)
        let usedTypefaceNames = Set(
            scene.pages.flatMap { page in
                page.textBoxes.flatMap { textBox in
                    textBox.lines.flatMap { line in
                        line.runs.map(\.fontName)
                    }
                }
            }
        )
        let embeddedFonts = OfficeEmbeddedFontCatalog.presentationFonts(
            usedTypefaceNames: usedTypefaceNames
        )
        let masterPlan = makeMasterPlan(scene: scene, options: options)
        var parts: [OOXMLPart] = []
        var imageAssetNames: [String: String] = [:]
        for page in scene.pages {
            try Task.checkCancellation()
            let slideNumber = page.pageIndex + 1
            let omitPageRaster = shouldOmitPageRaster(
                page: page,
                masterPlan: masterPlan
            )
            let includePageRaster = !omitPageRaster
            if includePageRaster {
                let mediaName = "ppt/media/image\(slideNumber).png"
                parts.append(try OOXMLPart(name: mediaName, data: page.pageImagePNG))
            }

            var relationships: [(id: String, type: String, target: String)] = [
                (
                    "rId1",
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout",
                    "../slideLayouts/slideLayout1.xml"
                )
            ]
            if includePageRaster {
                relationships.append(
                    (
                        "rId2",
                        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                        "../media/image\(slideNumber).png"
                    )
                )
            }
            let nativeImages = page.images.filter {
                $0.canRecreate(
                    onPageSafetyNet: page.usesPageRasterFallback,
                    options: options
                ) && !masterPlan.imageKeys.contains(templateImageKey($0))
            }
            var imageRelationships: [(image: PDFSceneImage, id: String)] = []
            for (offset, image) in nativeImages.enumerated() {
                let relationshipID = "rId\(offset + 3)"
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
                        ? "object-\(slideNumber)-\(offset + 1).png"
                        : OfficeImageAssetGrouping.sharedFilename(for: assetKey)
                    imageAssetNames[assetKey] = assetName
                    parts.append(
                        try OOXMLPart(
                            name: "ppt/media/\(assetName)",
                            data: image.pngData
                        )
                    )
                }
                relationships.append(
                    (
                        relationshipID,
                        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                        "../media/\(assetName)"
                    )
                )
                imageRelationships.append((image, relationshipID))
            }
            let slideXML = makeSlideXML(
                page: page,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                slideWidth: slideWidth,
                slideHeight: slideHeight,
                imageRelationships: imageRelationships,
                options: options,
                includePageRaster: includePageRaster,
                masterTextBoxKeys: masterPlan.textBoxKeys,
                masterVectorKeys: masterPlan.vectorKeys,
                masterImageKeys: masterPlan.imageKeys
            )
            parts.append(try OOXMLPart(name: "ppt/slides/slide\(slideNumber).xml", xml: slideXML))
            parts.append(
                try OOXMLPart(
                    name: "ppt/slides/_rels/slide\(slideNumber).xml.rels",
                    xml: relationshipsXML(relationships)
                )
            )
        }

        // rId1...rId4 are reserved by the presentation itself (master,
        // presProps, viewProps and tableStyles).  Starting slide relationships
        // at rId3 produced duplicate relationship IDs in multi-page PPTX
        // files, which PowerPoint/LibreOffice correctly reject.
        let firstSlideRelationshipID = 5
        let slideIDs = scene.pages.map {
            "<p:sldId id=\"\(256 + $0.pageIndex)\" r:id=\"rId\($0.pageIndex + firstSlideRelationshipID)\"/>"
        }.joined()
        var presentationRels: [(id: String, type: String, target: String)] = [
            (
                "rId1",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster",
                "slideMasters/slideMaster1.xml"
            ),
            (
                "rId2",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps",
                "presProps.xml"
            ),
            (
                "rId3",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps",
                "viewProps.xml"
            ),
            (
                "rId4",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles",
                "tableStyles.xml"
            )
        ]
        for page in scene.pages {
            presentationRels.append(
                (
                    "rId\(page.pageIndex + firstSlideRelationshipID)",
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide",
                    "slides/slide\(page.pageIndex + 1).xml"
                )
            )
        }

        var nextFontRelationshipID = firstSlideRelationshipID + scene.pages.count
        var nextFontPartIndex = 1
        var embeddedFontEntries: [String] = []
        for font in embeddedFonts {
            var faceEntries: [String] = []
            for face in font.faces {
                let relationshipID = "rId\(nextFontRelationshipID)"
                let partName = "ppt/fonts/font\(nextFontPartIndex).fntdata"
                parts.append(try OOXMLPart(name: partName, data: face.eotData))
                presentationRels.append(
                    (
                        relationshipID,
                        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/font",
                        "fonts/font\(nextFontPartIndex).fntdata"
                    )
                )
                faceEntries.append(
                    "<p:\(face.variant.elementName) r:id=\"\(relationshipID)\"/>"
                )
                nextFontRelationshipID += 1
                nextFontPartIndex += 1
            }
            embeddedFontEntries.append(
                "<p:embeddedFont><p:font typeface=\"\(XMLValue.attribute(font.typeface))\" panose=\"\(font.panose)\" pitchFamily=\"\(font.pitchFamily)\" charset=\"\(font.charset)\"/>\(faceEntries.joined())</p:embeddedFont>"
            )
        }
        let embeddedFontListXML = embeddedFontEntries.isEmpty
            ? ""
            : "<p:embeddedFontLst>\(embeddedFontEntries.joined())</p:embeddedFontLst>"
        let embeddingAttributes = embeddedFontEntries.isEmpty
            ? ""
            : " embedTrueTypeFonts=\"1\" saveSubsetFonts=\"0\""

        let presentationXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"\(embeddingAttributes)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(slideWidth)" cy="\(slideHeight)"/><p:notesSz cx="\(slideWidth)" cy="\(slideHeight)"/>\(embeddedFontListXML)<p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr></p:defaultTextStyle></p:presentation>
        """
        parts.append(try OOXMLPart(name: "ppt/presentation.xml", xml: presentationXML))
        parts.append(try OOXMLPart(name: "ppt/_rels/presentation.xml.rels", xml: relationshipsXML(presentationRels)))

        var masterRelationships: [(id: String, type: String, target: String)] = [
            (
                "rId1",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout",
                "../slideLayouts/slideLayout1.xml"
            ),
            (
                "rId2",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme",
                "../theme/theme1.xml"
            )
        ]
        var masterShapes = ""
        var nextMasterShapeID = 3
        var nextMasterRelationshipID = 3
        if let backgroundImage = masterPlan.backgroundImage {
            let relationshipID = "rId\(nextMasterRelationshipID)"
            nextMasterRelationshipID += 1
            masterRelationships.append(
                (
                    relationshipID,
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                    "../media/master-background.png"
                )
            )
            parts.append(
                try OOXMLPart(
                    name: "ppt/media/master-background.png",
                    data: backgroundImage.pngData
                )
            )
            let bounds = backgroundImage.officeBounds
            let x = emu(bounds.minX - first.cropBox.minX)
            let y = emu(canvasHeight - (bounds.maxY - first.cropBox.minY))
            masterShapes += imageShape(
                image: backgroundImage,
                id: nextMasterShapeID,
                relationshipID: relationshipID,
                x: x,
                y: y,
                width: max(1, emu(bounds.width)),
                height: max(1, emu(bounds.height))
            )
            nextMasterShapeID += 1
        } else if let backgroundPage = masterPlan.backgroundPage {
            let relationshipID = "rId\(nextMasterRelationshipID)"
            nextMasterRelationshipID += 1
            masterRelationships.append(
                (
                    relationshipID,
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                    "../media/master-background.png"
                )
            )
            parts.append(
                try OOXMLPart(
                    name: "ppt/media/master-background.png",
                    data: backgroundPage.pageImagePNG
                )
            )
            masterShapes += pageRasterShape(
                relationshipID: relationshipID,
                id: nextMasterShapeID,
                width: slideWidth,
                height: slideHeight,
                name: "Shared PDF template background"
            )
            nextMasterShapeID += 1
        }
        for vector in masterPlan.vectors.sorted(by: { $0.paintOrder < $1.paintOrder }) {
            let x = emu(vector.bounds.minX - first.cropBox.minX)
            let y = emu(canvasHeight - (vector.bounds.maxY - first.cropBox.minY))
            masterShapes += vectorShape(
                vector: vector,
                id: nextMasterShapeID,
                x: x,
                y: y,
                width: max(1, emu(vector.bounds.width)),
                height: max(1, emu(vector.bounds.height))
            )
            nextMasterShapeID += 1
        }
        for (offset, image) in masterPlan.images.enumerated() {
            let relationshipID = "rId\(nextMasterRelationshipID)"
            nextMasterRelationshipID += 1
            let assetName = "master-object-\(offset + 1).png"
            masterRelationships.append(
                (
                    relationshipID,
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                    "../media/\(assetName)"
                )
            )
            parts.append(
                try OOXMLPart(
                    name: "ppt/media/\(assetName)",
                    data: image.pngData
                )
            )
            let bounds = image.officeBounds
            let x = emu(bounds.minX - first.cropBox.minX)
            let y = emu(canvasHeight - (bounds.maxY - first.cropBox.minY))
            masterShapes += imageShape(
                image: image,
                id: nextMasterShapeID,
                relationshipID: relationshipID,
                x: x,
                y: y,
                width: max(1, emu(bounds.width)),
                height: max(1, emu(bounds.height))
            )
            nextMasterShapeID += 1
        }
        for textBox in masterPlan.textBoxes {
            let bounds = textBox.officeBounds
            let x = emu(bounds.minX - first.cropBox.minX)
            let y = emu(canvasHeight - (bounds.maxY - first.cropBox.minY))
            masterShapes += textShape(
                textBox: textBox,
                id: nextMasterShapeID,
                x: x,
                y: y,
                width: max(1, emu(bounds.width)),
                height: max(1, emu(bounds.height)),
                locked: true
            )
            nextMasterShapeID += 1
        }
        let masterXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="KC DeepL Master"><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(slideWidth)" cy="\(slideHeight)"/><a:chOff x="0" y="0"/><a:chExt cx="\(slideWidth)" cy="\(slideHeight)"/></a:xfrm></p:grpSpPr>\(masterShapes)</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
        """
        parts.append(try OOXMLPart(name: "ppt/slideMasters/slideMaster1.xml", xml: masterXML))
        parts.append(
            try OOXMLPart(
                name: "ppt/slideMasters/_rels/slideMaster1.xml.rels",
                xml: relationshipsXML(masterRelationships)
            )
        )

        let layoutXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """
        parts.append(try OOXMLPart(name: "ppt/slideLayouts/slideLayout1.xml", xml: layoutXML))
        parts.append(
            try OOXMLPart(
                name: "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
                xml: relationshipsXML([
                    (
                        "rId1",
                        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster",
                        "../slideMasters/slideMaster1.xml"
                    )
                ])
            )
        )
        parts.append(try OOXMLPart(name: "ppt/theme/theme1.xml", xml: Self.themeXML))
        parts.append(try OOXMLPart(name: "ppt/presProps.xml", xml: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:presProps xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:extLst/></p:presProps>"))
        parts.append(try OOXMLPart(name: "ppt/viewProps.xml", xml: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:viewPr xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" lastView=\"sldView\"><p:normalViewPr><p:restoredLeft sz=\"15620\"/><p:restoredTop sz=\"94660\"/></p:normalViewPr><p:guideLst/><p:slideViewPr><p:cSldViewPr><p:scale><a:sx n=\"1\" d=\"1\"/><a:sy n=\"1\" d=\"1\"/></p:scale><p:origin x=\"0\" y=\"0\"/></p:cSldViewPr></p:slideViewPr><p:notesViewPr><p:cSldViewPr><p:scale><a:sx n=\"1\" d=\"1\"/><a:sy n=\"1\" d=\"1\"/></p:scale><p:origin x=\"0\" y=\"0\"/></p:cSldViewPr></p:notesViewPr><p:gridSpacing cx=\"72008\" cy=\"72008\"/></p:viewPr>"))
        parts.append(try OOXMLPart(name: "ppt/tableStyles.xml", xml: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><a:tblStyleLst xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" def=\"\"/>"))
        parts.append(try OOXMLPart(name: "docProps/core.xml", xml: Self.coreProperties(title: "KC DeepL PDF 변환")))
        parts.append(try OOXMLPart(name: "docProps/app.xml", xml: Self.appProperties(application: "KC DeepL")))
        parts.append(try OOXMLPart(name: "_rels/.rels", xml: Self.rootRelationships(documentTarget: "ppt/presentation.xml")))
        parts.append(
            try OOXMLPart(
                name: "[Content_Types].xml",
                xml: Self.contentTypes(
                    format: .pptx,
                    pages: scene.pages.count,
                    hasEmbeddedFonts: !embeddedFontEntries.isEmpty
                )
            )
        )
        return parts
    }
}

private extension PresentationMLWriter {
    private func makeMasterPlan(
        scene: PDFSceneDocument,
        options: DocumentConversionPipelineOptions
    ) -> MasterPlan {
        guard options.templatePriority == .repeatedToTemplate,
              scene.pages.count > 1,
              let first = scene.pages.first
        else {
            return .empty
        }

        let sameCanvas = scene.pages.allSatisfy {
            abs($0.width - first.width) <= 0.01
                && abs($0.height - first.height) <= 0.01
        }
        let identicalBackground = sameCanvas
            && scene.pages.allSatisfy { !$0.usesPageRasterFallback }
            && scene.pages.dropFirst().allSatisfy {
                $0.pageImagePNG == first.pageImagePNG
            }

        // Requiring an object to occur on *every* page is too strict for
        // normal decks: title/divider slides commonly use a different
        // background while the body slides share the same master. Promote a
        // native object when it is present on a stable majority of pages.
        let minimumRepeatedPages = max(
            2,
            Int(ceil(Double(scene.pages.count) * 0.5))
        )

        let pageBackgroundFingerprint: (PDFScenePage) -> String? = { page in
            page.templateObjects.first {
                $0.id.hasPrefix("page-template-")
            }?.sourceFingerprint
        }
        var backgroundPageCounts: [String: Int] = [:]
        for page in scene.pages where !page.usesPageRasterFallback {
            if let fingerprint = pageBackgroundFingerprint(page) {
                backgroundPageCounts[fingerprint, default: 0] += 1
            }
        }
        let repeatedBackgroundFingerprint = backgroundPageCounts
            .filter { $0.value >= minimumRepeatedPages }
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key < rhs.key
            }?.key
        let backgroundPage = repeatedBackgroundFingerprint.flatMap { fingerprint in
            scene.pages.first {
                !($0.usesPageRasterFallback)
                    && pageBackgroundFingerprint($0) == fingerprint
            }
        } ?? (identicalBackground ? first : nil)
        let backgroundTemplateFingerprint = repeatedBackgroundFingerprint
            ?? (identicalBackground ? pageBackgroundFingerprint(first) : nil)

        var textPageCounts: [String: Int] = [:]
        for page in scene.pages {
            for fingerprint in Set(
                page.templateObjects
                    .filter {
                        $0.role == .sharedTemplate
                            && $0.id.hasPrefix("template-chrome-")
                    }
                    .map(\.sourceFingerprint)
            ) {
                textPageCounts[fingerprint, default: 0] += 1
            }
        }
        let sharedTextFingerprints = Set(
            textPageCounts.compactMap { fingerprint, count in
                count >= minimumRepeatedPages ? fingerprint : nil
            }
        )
        var textRepresentatives: [String: PDFSceneTextBox] = [:]
        for page in scene.pages {
            for textBox in page.textBoxes where textBox.role == .templateChrome {
                guard let fingerprint = templateTextFingerprint(
                    page: page,
                    textBox: textBox
                ), sharedTextFingerprints.contains(fingerprint),
                textBox.canRecreateOnLayeredTemplate
                else { continue }
                textRepresentatives[fingerprint] = textBox
            }
        }
        let textBoxes = sharedTextFingerprints.sorted().compactMap {
            textRepresentatives[$0]
        }

        var vectorPageCounts: [String: Int] = [:]
        var vectorRepresentatives: [String: PDFSceneVector] = [:]
        for page in scene.pages {
            let candidates = page.vectors.filter {
                $0.canRecreate(
                    onPageSafetyNet: false,
                    options: options
                )
            }
            for vector in candidates {
                let key = templateVectorKey(vector)
                vectorPageCounts[key, default: 0] += 1
                vectorRepresentatives[key] = vector
            }
        }
        let commonVectorKeys = Set(
            vectorPageCounts.compactMap { key, count in
                count >= minimumRepeatedPages ? key : nil
            }
        )
        let vectors = commonVectorKeys
            .sorted()
            .compactMap { vectorRepresentatives[$0] }

        var imagePageCounts: [String: Int] = [:]
        var imageRepresentatives: [String: PDFSceneImage] = [:]
        for page in scene.pages {
            let candidates = page.images.filter { image in
                image.hasVisibleReferenceContribution
                    && image.canRecreate(
                        onPageSafetyNet: false,
                        options: options
                    )
            }
            for image in candidates {
                let key = templateImageKey(image)
                imagePageCounts[key, default: 0] += 1
                imageRepresentatives[key] = image
            }
        }
        let commonImageKeys = Set(
            imagePageCounts.compactMap { key, count in
                count >= minimumRepeatedPages ? key : nil
            }
        )
        let backgroundImageKey = imageRepresentatives.first { key, image in
            commonImageKeys.contains(key)
                && sameCanvas
                && image.bounds.minX <= first.cropBox.minX + 0.5
                && image.bounds.minY <= first.cropBox.minY + 0.5
                && image.bounds.maxX >= first.cropBox.maxX - 0.5
                && image.bounds.maxY >= first.cropBox.maxY - 0.5
                && !image.hasAlpha
                && !image.maskApplied
                && image.clip == nil
        }?.key
        let backgroundImage = backgroundImageKey.flatMap {
            imageRepresentatives[$0]
        }
        let images = commonImageKeys
            .subtracting(backgroundImageKey.map { [$0] } ?? [])
            .sorted()
            .compactMap { imageRepresentatives[$0] }
        return MasterPlan(
            backgroundPage: backgroundPage,
            backgroundTemplateFingerprint: backgroundTemplateFingerprint,
            backgroundImage: backgroundImage,
            textBoxes: textBoxes,
            textBoxKeys: sharedTextFingerprints,
            vectors: vectors,
            vectorKeys: commonVectorKeys,
            images: images,
            imageKeys: commonImageKeys
        )
    }

    private func shouldOmitPageRaster(
        page: PDFScenePage,
        masterPlan: MasterPlan
    ) -> Bool {
        if let backgroundImage = masterPlan.backgroundImage {
            let backgroundKey = templateImageKey(backgroundImage)
            return !page.usesPageRasterFallback
                && page.images.contains { templateImageKey($0) == backgroundKey }
        }
        return masterPlan.backgroundPage != nil
            && !page.usesPageRasterFallback
            && page.templateObjects.first(where: {
                $0.id.hasPrefix("page-template-")
            })?.sourceFingerprint == masterPlan.backgroundTemplateFingerprint
    }

    private func templateTextFingerprint(
        page: PDFScenePage,
        textBox: PDFSceneTextBox
    ) -> String? {
        page.templateObjects.first {
            $0.id == "template-chrome-\(textBox.id)"
        }?.sourceFingerprint
    }

    func templateImageKey(_ image: PDFSceneImage) -> String {
        let digest = SHA256.hash(data: image.pngData)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        let clipDescription = image.clip?.bounds.debugDescription ?? ""
        return "\(digest)|\(image.bounds.debugDescription)|\(clipDescription)"
    }

    func templateVectorKey(_ vector: PDFSceneVector) -> String {
        var value = "\(vector.kind.rawValue)|\(vector.bounds.debugDescription)|\(vector.lineWidth)|\(vector.rotation)|"
        value += vector.stroke.map { "stroke:\($0.red),\($0.green),\($0.blue),\($0.alpha)|" } ?? "stroke:none|"
        value += vector.fill.map { "fill:\($0.red),\($0.green),\($0.blue),\($0.alpha)|" } ?? "fill:none|"
        for command in vector.pathCommands {
            switch command {
            case let .move(point): value += "m:\(point.x),\(point.y);"
            case let .line(point): value += "l:\(point.x),\(point.y);"
            case let .cubic(control1, control2, end):
                value += "c:\(control1.x),\(control1.y),\(control2.x),\(control2.y),\(end.x),\(end.y);"
            case .close: value += "z;"
            }
        }
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func pageRasterShape(
        relationshipID: String,
        id: Int,
        width: Int,
        height: Int,
        name: String
    ) -> String {
        "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"\(XMLValue.attribute(name))\"/><p:cNvPicPr preferRelativeResize=\"0\"><a:picLocks noSelect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(XMLValue.attribute(relationshipID))\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
    }

    private func makeSlideXML(
        page: PDFScenePage,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        slideWidth: Int,
        slideHeight: Int,
        imageRelationships: [(image: PDFSceneImage, id: String)],
        options: DocumentConversionPipelineOptions,
        includePageRaster: Bool,
        masterTextBoxKeys: Set<String>,
        masterVectorKeys: Set<String>,
        masterImageKeys: Set<String>
    ) -> String {
        let pageOffsetX: CGFloat = 0
        let pageOffsetY: CGFloat = canvasHeight - page.height
        let nativeVectors = page.vectors.filter {
            $0.canRecreate(
                onPageSafetyNet: page.usesPageRasterFallback,
                options: options
            ) && !masterVectorKeys.contains(templateVectorKey($0))
        }
            .sorted { $0.paintOrder < $1.paintOrder }
        var shapeID = 3
        let imageWidth = emu(page.width)
        let imageHeight = emu(page.height)
        var shapes = includePageRaster
            ? pageRasterShape(
                relationshipID: "rId2",
                id: 2,
                width: imageWidth,
                height: imageHeight,
                name: "PDF page \(page.pageIndex + 1)"
            )
            : ""
        let templateTextBoxes = page.usesPageRasterFallback
            ? []
            : page.textBoxes.filter { textBox in
                guard textBox.role == .templateChrome,
                      textBox.canRecreateOnLayeredTemplate
                else { return false }
                guard let fingerprint = templateTextFingerprint(
                    page: page,
                    textBox: textBox
                ) else {
                    return true
                }
                return !masterTextBoxKeys.contains(fingerprint)
            }
        let contentTextBoxes = page.textBoxes.filter {
            $0.role == .editableContent && $0.canRecreateOnLayeredTemplate
        }
        enum Overlay {
            case image(PDFSceneImage, String)
            case vector(PDFSceneVector)
        }
        let nativeImages = page.images.filter {
            $0.canRecreate(
                onPageSafetyNet: page.usesPageRasterFallback,
                options: options
            ) && !masterImageKeys.contains(templateImageKey($0))
        }
        let imageOverlays = nativeImages.map { image in
            Overlay.image(
                image,
                imageRelationships.first(where: { $0.image.id == image.id })?.id ?? ""
            )
        }
        let overlays: [Overlay]
        if page.usesPageRasterFallback {
            overlays = imageOverlays + nativeVectors.map(Overlay.vector)
        } else {
            // A layered template is a real background asset, not a flattened
            // foreground safety-net. Replay drawing paths first, then their
            // image assets, before editable text is appended below.
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
        // PDF painting is order-dependent across *all* graphics operators.
        // Resource dictionary order is unrelated to the content stream order,
        // so emitting vectors first and images second can put a photo in front
        // of a later footer, watermark, or mask.  Keep the original operator
        // sequence regardless of whether the slide uses a raster safety net
        // or a clean layered background.
        let orderedOverlays = overlays.sorted(by: { lhs, rhs in
            let left = overlaySortKey(lhs)
            let right = overlaySortKey(rhs)
            if left.order != right.order { return left.order < right.order }
            if left.kind != right.kind { return left.kind < right.kind }
            return left.id < right.id
        })
        for overlay in orderedOverlays {
            switch overlay {
            case let .image(image, relationshipID) where !relationshipID.isEmpty:
                let officeBounds = image.officeBounds
                let x = emu(pageOffsetX + officeBounds.minX - page.cropBox.minX)
                let y = emu(pageOffsetY + page.height - (officeBounds.maxY - page.cropBox.minY))
                shapes += imageShape(
                    image: image,
                    id: shapeID,
                    relationshipID: relationshipID,
                    x: x,
                    y: y,
                    width: max(1, emu(officeBounds.width)),
                    height: max(1, emu(officeBounds.height))
                )
                shapeID += 1
            case let .vector(vector):
                let x = emu(pageOffsetX + vector.bounds.minX - page.cropBox.minX)
                let y = emu(pageOffsetY + page.height - (vector.bounds.maxY - page.cropBox.minY))
                shapes += vectorShape(
                    vector: vector,
                    id: shapeID,
                    x: x,
                    y: y,
                    width: max(1, emu(vector.bounds.width)),
                    height: max(1, emu(vector.bounds.height))
                )
                shapeID += 1
            default:
                break
            }
        }
        for textBox in templateTextBoxes {
            let bounds = textBox.officeBounds
            let x = emu(pageOffsetX + bounds.minX - page.cropBox.minX)
            let y = emu(pageOffsetY + page.height - (bounds.maxY - page.cropBox.minY))
            shapes += textShape(
                textBox: textBox,
                id: shapeID,
                x: x,
                y: y,
                width: max(1, emu(bounds.width)),
                height: max(1, emu(bounds.height)),
                locked: true
            )
            shapeID += 1
        }
        for textBox in contentTextBoxes {
            let bounds = textBox.officeBounds
            let x = emu(pageOffsetX + bounds.minX - page.cropBox.minX)
            let y = emu(pageOffsetY + page.height - (bounds.maxY - page.cropBox.minY))
            let width = max(1, emu(bounds.width))
            let height = max(1, emu(bounds.height))
            shapes += textShape(
                textBox: textBox,
                id: shapeID,
                x: x,
                y: y,
                width: width,
                height: height,
                locked: false
            )
            shapeID += 1
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld showMasterSp="1" showMasterPhAnim="1" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="PDF page \(page.pageIndex + 1)"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(slideWidth)" cy="\(slideHeight)"/><a:chOff x="0" y="0"/><a:chExt cx="\(slideWidth)" cy="\(slideHeight)"/></a:xfrm></p:grpSpPr>\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
    }

    func imageShape(
        image: PDFSceneImage,
        id: Int,
        relationshipID: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> String {
        if let clip = image.clip {
            return clippedImageShape(
                image: image,
                clip: clip,
                id: id,
                relationshipID: relationshipID,
                x: x,
                y: y,
                width: width,
                height: height
            )
        }
        return "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"PDF image \(XMLValue.attribute(image.sourceName))\"/><p:cNvPicPr preferRelativeResize=\"0\"/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(XMLValue.attribute(relationshipID))\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
    }

    func clippedImageShape(
        image: PDFSceneImage,
        clip: PDFSceneImageClip,
        id: Int,
        relationshipID: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> String {
        let geometry = customGeometry(
            pathCommands: clip.pathCommands,
            bounds: image.officeBounds,
            width: width,
            height: height
        )
        let sourceCrop = imageSourceCrop(
            image: image,
            visibleBounds: image.officeBounds
        )
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"PDF clipped image \(XMLValue.attribute(image.sourceName))\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm>\(geometry)<a:blipFill rotWithShape=\"1\"><a:blip r:embed=\"\(XMLValue.attribute(relationshipID))\"/>\(sourceCrop)<a:stretch><a:fillRect/></a:stretch></a:blipFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>"
    }

    func imageSourceCrop(
        image: PDFSceneImage,
        visibleBounds: CGRect
    ) -> String {
        guard image.bounds.width > 0, image.bounds.height > 0 else { return "" }
        let left = normalizedCrop(
            (visibleBounds.minX - image.bounds.minX) / image.bounds.width
        )
        let top = normalizedCrop(
            (image.bounds.maxY - visibleBounds.maxY) / image.bounds.height
        )
        let right = normalizedCrop(
            (image.bounds.maxX - visibleBounds.maxX) / image.bounds.width
        )
        let bottom = normalizedCrop(
            (visibleBounds.minY - image.bounds.minY) / image.bounds.height
        )
        guard left > 0 || top > 0 || right > 0 || bottom > 0 else { return "" }
        return "<a:srcRect l=\"\(left)\" t=\"\(top)\" r=\"\(right)\" b=\"\(bottom)\"/>"
    }

    func normalizedCrop(_ value: CGFloat) -> Int {
        Int((min(1, max(0, value)) * 100_000).rounded())
    }

    func vectorShape(
        vector: PDFSceneVector,
        id: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> String {
        let fill = vector.fill.map { solidFill($0) } ?? "<a:noFill/>"
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
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"PDF \(vector.kind.rawValue) \(id)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm rot=\"\(rotation)\"><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm>\(geometry)\(fill)\(line)</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr/></a:p></p:txBody></p:sp>"
    }

    func customGeometry(
        for vector: PDFSceneVector,
        width: Int,
        height: Int
    ) -> String {
        customGeometry(
            pathCommands: vector.pathCommands,
            bounds: vector.bounds,
            width: width,
            height: height
        )
    }

    func customGeometry(
        pathCommands: [PDFSceneVectorPathCommand],
        bounds: CGRect,
        width: Int,
        height: Int
    ) -> String {
        let pathWidth = max(1, width)
        let pathHeight = max(1, height)
        let commands = pathCommands.map { command -> String in
            switch command {
            case let .move(point):
                return "<a:moveTo>\(customPathPoint(point, in: bounds))</a:moveTo>"
            case let .line(point):
                return "<a:lnTo>\(customPathPoint(point, in: bounds))</a:lnTo>"
            case let .cubic(control1, control2, end):
                return "<a:cubicBezTo>\(customPathPoint(control1, in: bounds))\(customPathPoint(control2, in: bounds))\(customPathPoint(end, in: bounds))</a:cubicBezTo>"
            case .close:
                return "<a:close/>"
            }
        }.joined()
        return "<a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/><a:rect l=\"l\" t=\"t\" r=\"r\" b=\"b\"/><a:pathLst><a:path w=\"\(pathWidth)\" h=\"\(pathHeight)\">\(commands)</a:path></a:pathLst></a:custGeom>"
    }

    func customPathPoint(_ point: CGPoint, in bounds: CGRect) -> String {
        let maximumX = max(1, Int((bounds.width * emuPerPoint).rounded()))
        let maximumY = max(1, Int((bounds.height * emuPerPoint).rounded()))
        let x = min(
            maximumX,
            max(
                0,
                Int(
                    (
                        (point.x - bounds.minX)
                            * emuPerPoint
                    ).rounded()
                )
            )
        )
        let y = min(
            maximumY,
            max(
                0,
                Int(
                    (
                        (bounds.maxY - point.y)
                            * emuPerPoint
                    ).rounded()
                )
            )
        )
        return "<a:pt x=\"\(x)\" y=\"\(y)\"/>"
    }

    func solidFill(_ color: PDFTextColor) -> String {
        "<a:solidFill>\(solidFillBody(color))</a:solidFill>"
    }

    func solidFillBody(_ color: PDFTextColor) -> String {
        let hex = rgbHex(color)
        let alpha = Int((max(0, min(1, color.alpha)) * 100_000).rounded())
        return "<a:srgbClr val=\"\(hex)\"><a:alpha val=\"\(alpha)\"/></a:srgbClr>"
    }

    func textShape(
        textBox: PDFSceneTextBox,
        id: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        locked: Bool = false
    ) -> String {
        let leadingInset = textMarginEMU(textBox.officeLeadingInset)
        let trailingInset = textMarginEMU(textBox.officeTrailingInset)
        let paragraphAlignment: String
        switch textBox.alignment {
        case .left: paragraphAlignment = "l"
        case .center: paragraphAlignment = "ctr"
        case .right: paragraphAlignment = "r"
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
        let usesSoftLineBreaks = canUseSoftLineBreaks(lines, in: textBox)
        let topInset = usesSoftLineBreaks
            ? textMarginEMU(softLineBreakTopInset(for: lines))
            : 0
        let paragraphs = drawingParagraphs(
            for: lines,
            textBox: textBox,
            alignment: paragraphAlignment,
            usesSoftLineBreaks: usesSoftLineBreaks
        )
        let locks = locked
            ? "<a:spLocks noSelect=\"1\" noGrp=\"1\" noTextEdit=\"1\" noMove=\"1\" noResize=\"1\" noRot=\"1\"/>"
            : ""
        let name = locked ? "PDF template text \(id)" : "Text \(id)"
        return """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr txBox="1">\(locks)</p:cNvSpPr><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln w="0"><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr lIns="\(leadingInset)" tIns="\(topInset)" rIns="\(trailingInset)" bIns="0" wrap="none" anchor="t" vert="horz"><a:noAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>
        """
    }

    /// A PDF paragraph often arrives as separate visual lines.  Serializing
    /// each line as an independent DrawingML paragraph makes Office apply its
    /// default paragraph-cell height between them, which compresses wrapped
    /// lines even if every source line has the correct coordinate.  When the
    /// source lines are a continuous, left-aligned paragraph, preserve their
    /// one-text-box editability with soft line breaks and one source-derived
    /// line-spacing value.  A hanging indent keeps a wrapped list item aligned
    /// at its original body edge without splitting it into separate objects.
    func drawingParagraphs(
        for lines: [PDFSceneTextLine],
        textBox: PDFSceneTextBox,
        alignment: String,
        usesSoftLineBreaks: Bool
    ) -> String {
        if usesSoftLineBreaks {
            return softLineBreakParagraph(
                lines: lines,
                textBox: textBox,
                alignment: alignment
            )
        }

        return lines.enumerated().map { index, line in
            let previousLine = index > 0 ? lines[index - 1] : nil
            let spacing = lineSpacingPoints(
                for: line,
                previousLine: previousLine
            )
            let insets = textBox.paragraphInsets(for: line)
            let marginAttributes = drawingParagraphMarginAttributes(insets)
            let tabs = drawingTabStops(for: line, in: textBox)
            return "<a:p><a:pPr\(marginAttributes) algn=\"\(alignment)\"><a:lnSpc><a:spcPts val=\"\(spacing)\"/></a:lnSpc>\(tabs)</a:pPr>\(drawingRuns(for: line, textBox: textBox))<a:endParaRPr/></a:p>"
        }.joined()
    }

    func softLineBreakParagraph(
        lines: [PDFSceneTextLine],
        textBox: PDFSceneTextBox,
        alignment: String
    ) -> String {
        let spacing = softLineBreakSpacingPoints(for: lines)
        let margins = softLineBreakMarginAttributes(
            for: lines,
            in: textBox
        )
        let tabs = lines.first.map {
            drawingTabStops(for: $0, in: textBox)
        } ?? ""
        let content = lines.enumerated().map { index, line in
            let lineBreak = index == 0 ? "" : "<a:br/>"
            return "\(lineBreak)\(drawingRuns(for: line, textBox: textBox))"
        }.joined()
        return "<a:p><a:pPr\(margins) algn=\"\(alignment)\"><a:lnSpc><a:spcPts val=\"\(spacing)\"/></a:lnSpc>\(tabs)</a:pPr>\(content)<a:endParaRPr/></a:p>"
    }

    func drawingRuns(
        for line: PDFSceneTextLine,
        textBox: PDFSceneTextBox
    ) -> String {
        if !line.runs.isEmpty {
            return line.runs.map(drawingRun).joined()
        }
        return drawingRun(
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
    }

    func canUseSoftLineBreaks(
        _ lines: [PDFSceneTextLine],
        in textBox: PDFSceneTextBox
    ) -> Bool {
        guard lines.count > 1,
              textBox.alignment == .left,
              let first = lines.first
        else {
            return false
        }

        let referenceSize = max(5, first.runs.map(\.fontSize).max() ?? textBox.fontSize)
        let maximumIndent = max(72, referenceSize * 5)
        let continuationOffsets = lines.dropFirst().map {
            $0.bounds.minX - first.bounds.minX
        }
        guard continuationOffsets.allSatisfy({
            $0 >= -0.5 && $0 <= maximumIndent
        }) else {
            return false
        }

        // One DrawingML paragraph has one line-spacing value.  Keep source
        // lines as separate paragraphs when their measured baseline advances
        // are intentionally non-uniform, such as a stack of independent
        // captions that PDFKit happened to place close together.
        let advances = zip(lines, lines.dropFirst()).map { previous, current in
            previous.bounds.maxY - current.bounds.maxY
        }
        guard advances.allSatisfy({
            $0 > 0 && $0 <= max(72, referenceSize * 3)
        }), let firstAdvance = advances.first
        else {
            return false
        }
        let advanceTolerance = max(1, referenceSize * 0.12)
        guard advances.allSatisfy({
            abs($0 - firstAdvance) <= advanceTolerance
        }) else {
            return false
        }

        let continuationIndent = continuationOffsets.sorted()[
            continuationOffsets.count / 2
        ]
        let indentTolerance = max(1, referenceSize * 0.12)
        return continuationOffsets.allSatisfy {
            abs($0 - continuationIndent) <= indentTolerance
        }
    }

    func softLineBreakSpacingPoints(for lines: [PDFSceneTextLine]) -> Int {
        let advances = zip(lines, lines.dropFirst()).map { previous, current in
            previous.bounds.maxY - current.bounds.maxY
        }.sorted()
        let sourceAdvance = advances.isEmpty
            ? 0
            : advances[advances.count / 2]
        let fontHeight = lines.flatMap(\.runs).map(\.fontSize).max()
            ?? lines.map(\.bounds.height).max()
            ?? 0
        // `lnSpc` is a baseline-to-baseline distance. PDFKit selection cells
        // are commonly taller than the source's measured baseline advance,
        // especially for list items, so using the cell height expands wrapped
        // paragraphs. Keep the source advance whenever it is typographically
        // viable and retain only a conservative minimum for malformed input.
        let points = max(fontHeight * 0.8, sourceAdvance)
        return max(100, Int((points * 100).rounded()))
    }

    /// A fixed DrawingML line spacing (`a:lnSpc`) puts the first glyph closer
    /// to a text frame's top edge than Office's natural line cell.  Restore
    /// the missing top reserve once on the frame, rather than adding a dummy
    /// text run or moving every visual line independently.  The reserve is
    /// proportional to the em square, so it remains stable across fonts and
    /// preserves the exact source-derived baseline advance below it.
    func softLineBreakTopInset(for lines: [PDFSceneTextLine]) -> CGFloat {
        let fontSize = lines.flatMap(\.runs).map(\.fontSize).max()
            ?? lines.map(\.bounds.height).max()
            ?? 0
        return max(0, min(18, fontSize * 0.30))
    }

    func softLineBreakMarginAttributes(
        for lines: [PDFSceneTextLine],
        in textBox: PDFSceneTextBox
    ) -> String {
        guard let first = lines.first, lines.count > 1 else { return "" }
        let firstOffset = max(0, first.bounds.minX - textBox.bounds.minX)
        let continuationOffsets = lines.dropFirst().map {
            max(0, $0.bounds.minX - textBox.bounds.minX)
        }.sorted()
        guard !continuationOffsets.isEmpty else {
            return ""
        }
        let continuationOffset = continuationOffsets[
            continuationOffsets.count / 2
        ]

        var attributes = ""
        if continuationOffset > 0.01 {
            attributes += " marL=\"\(textMarginEMU(continuationOffset))\""
        }
        let hangingIndent = firstOffset - continuationOffset
        if abs(hangingIndent) > 0.01 {
            attributes += " indent=\"\(signedTextMarginEMU(hangingIndent))\""
        }
        return attributes
    }

    func drawingRun(_ run: PDFSceneTextRun) -> String {
        let colorHex = rgbHex(run.color)
        let alpha = Int((max(0, min(1, run.color.alpha)) * 100_000).rounded())
        let fontSize = max(500, min(7200, Int((run.fontSize * 100).rounded())))
        let bold = run.isBold ? " b=\"1\"" : ""
        let italic = run.isItalic ? " i=\"1\"" : ""
        let characterSpacing = drawingCharacterSpacing(for: run)
        let spacingAttribute = characterSpacing == 0
            ? ""
            : " spc=\"\(characterSpacing)\""
        return "<a:r><a:rPr lang=\"en-US\" sz=\"\(fontSize)\"\(bold)\(italic)\(spacingAttribute)><a:solidFill><a:srgbClr val=\"\(colorHex)\"><a:alpha val=\"\(alpha)\"/></a:srgbClr></a:solidFill><a:latin typeface=\"\(XMLValue.attribute(run.fontName))\"/><a:ea typeface=\"\(XMLValue.attribute(run.fontName))\"/><a:cs typeface=\"\(XMLValue.attribute(run.fontName))\"/></a:rPr>\(drawingTextElements(run.text))</a:r>"
    }

    /// Adds the source-line tracking correction to a small, face-level
    /// DrawingML calibration for the bundled Barlow Regular font. Both values
    /// are expressed in hundredths of a point, the OOXML `spc` unit.
    func drawingCharacterSpacing(for run: PDFSceneTextRun) -> Int {
        let sourceSpacing = Int((run.characterSpacing * 100).rounded())
        let faceCalibration = run.fontName.caseInsensitiveCompare("Barlow") == .orderedSame
            && !run.isBold
            && !run.isItalic
            ? 4
            : 0
        return sourceSpacing + faceCalibration
    }

    func drawingTabStops(
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
        let position = max(1, emu(relativeOffset))
        return "<a:tabLst><a:tab pos=\"\(position)\"/></a:tabLst>"
    }

    func drawingParagraphMarginAttributes(
        _ insets: PDFSceneTextParagraphInsets
    ) -> String {
        var attributes = ""
        if insets.leading > 0.01 {
            attributes += " marL=\"\(textMarginEMU(insets.leading))\""
        }
        if insets.trailing > 0.01 {
            attributes += " marR=\"\(textMarginEMU(insets.trailing))\""
        }
        return attributes
    }

    func drawingTextElements(_ text: String) -> String {
        var elements = ""
        var fragment = ""
        func appendFragment() {
            guard !fragment.isEmpty else { return }
            elements += "<a:t xml:space=\"preserve\">\(XMLValue.escape(fragment, preserveWhitespace: true))</a:t>"
            fragment.removeAll(keepingCapacity: true)
        }
        for character in text {
            if character == "\t" {
                appendFragment()
                elements += "<a:tab/>"
            } else {
                fragment.append(character)
            }
        }
        appendFragment()
        return elements
    }

    func lineSpacingPoints(
        for line: PDFSceneTextLine,
        previousLine: PDFSceneTextLine?
    ) -> Int {
        let sourceAdvance = previousLine.map {
            // PDF visual-line selection tops retain the source baseline
            // advance even where a particular line's first painted pixel is
            // affected by anti-aliasing or glyph shape. Rendered ink is used
            // only to calibrate the text frame's initial top anchor.
            max(0, $0.bounds.maxY - line.bounds.maxY)
        } ?? 0
        let fontHeight = line.runs.map(\.fontSize).max() ?? line.bounds.height
        let points = max(line.bounds.height, fontHeight * 1.05, sourceAdvance)
        return max(100, Int((points * 100).rounded()))
    }

    func emu(_ points: CGFloat) -> Int {
        max(1, Int((Double(points) * emuPerPoint).rounded()))
    }

    func textMarginEMU(_ points: CGFloat) -> Int {
        max(0, Int((Double(points) * emuPerPoint).rounded()))
    }

    func signedTextMarginEMU(_ points: CGFloat) -> Int {
        Int((Double(points) * emuPerPoint).rounded())
    }

    func rgbHex(_ color: PDFTextColor) -> String {
        [color.red, color.green, color.blue]
            .map { String(format: "%02X", Int((max(0, min(1, $0)) * 255.0).rounded())) }
            .joined()
    }

    func relationshipsXML(_ relationships: [(id: String, type: String, target: String)]) -> String {
        let body = relationships.map {
            "<Relationship Id=\"\(XMLValue.attribute($0.id))\" Type=\"\(XMLValue.attribute($0.type))\" Target=\"\(XMLValue.attribute($0.target))\"/>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(body)</Relationships>"
    }

    static func rootRelationships(documentTarget: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"\(documentTarget)\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>"
    }

    static func coreProperties(title: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>\(XMLValue.escape(title))</dc:title><dc:creator>KC DeepL</dc:creator><cp:lastModifiedBy>KC DeepL</cp:lastModifiedBy><dcterms:created xsi:type=\"dcterms:W3CDTF\">2000-01-01T00:00:00Z</dcterms:created></cp:coreProperties>"
    }

    static func appProperties(application: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\"><Application>\(XMLValue.escape(application))</Application><AppVersion>1.0</AppVersion></Properties>"
    }

    static func contentTypes(
        format: DocumentConversionFormat,
        pages: Int,
        hasEmbeddedFonts: Bool = false
    ) -> String {
        switch format {
        case .pptx:
            let overrides = [
                "/ppt/presentation.xml|application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
                "/ppt/presProps.xml|application/vnd.openxmlformats-officedocument.presentationml.presProps+xml",
                "/ppt/viewProps.xml|application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml",
                "/ppt/tableStyles.xml|application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml",
                "/ppt/slideMasters/slideMaster1.xml|application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml",
                "/ppt/slideLayouts/slideLayout1.xml|application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml",
                "/ppt/theme/theme1.xml|application/vnd.openxmlformats-officedocument.theme+xml"
            ] + (1...pages).map { "/ppt/slides/slide\($0).xml|application/vnd.openxmlformats-officedocument.presentationml.slide+xml" }
            let fontDefault = hasEmbeddedFonts
                ? "<Default Extension=\"fntdata\" ContentType=\"application/x-fontdata\"/>"
                : ""
            return contentTypesXML(
                overrides: overrides,
                imageExtension: "png",
                additionalDefaults: fontDefault
            )
        case .docx:
            return ""
        }
    }

    static func contentTypesXML(
        overrides: [String],
        imageExtension: String,
        additionalDefaults: String = ""
    ) -> String {
        let overrideXML = overrides.map { item in
            let components = item.split(separator: "|", maxSplits: 1).map(String.init)
            return "<Override PartName=\"\(components[0])\" ContentType=\"\(components[1])\"/>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"\(imageExtension)\" ContentType=\"image/png\"/>\(additionalDefaults)<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/><Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>\(overrideXML)</Types>"
    }

    static let themeXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="KC DeepL"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F2937"/></a:dk2><a:lt2><a:srgbClr val="F3F4F6"/></a:lt2><a:accent1><a:srgbClr val="2563EB"/></a:accent1><a:accent2><a:srgbClr val="7C3AED"/></a:accent2><a:accent3><a:srgbClr val="059669"/></a:accent3><a:accent4><a:srgbClr val="D97706"/></a:accent4><a:accent5><a:srgbClr val="DC2626"/></a:accent5><a:accent6><a:srgbClr val="0891B2"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst/><a:lnStyleLst/><a:effectStyleLst/><a:bgFillStyleLst/></a:fmtScheme></a:themeElements></a:theme>
    """
}
