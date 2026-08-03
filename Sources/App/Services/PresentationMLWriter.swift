import Foundation

struct PresentationMLWriter {
    private let emuPerPoint = 12_700.0

    func makeParts(scene: PDFSceneDocument) throws -> [OOXMLPart] {
        guard let first = scene.pages.first else {
            throw DocumentConversionError.emptyPDF
        }
        let canvasWidth = max(1, scene.pages.map(\.width).max() ?? first.width)
        let canvasHeight = max(1, scene.pages.map(\.height).max() ?? first.height)
        let slideWidth = emu(canvasWidth)
        let slideHeight = emu(canvasHeight)
        var parts: [OOXMLPart] = []
        for page in scene.pages {
            try Task.checkCancellation()
            let slideNumber = page.pageIndex + 1
            let mediaName = "ppt/media/image\(slideNumber).png"
            parts.append(try OOXMLPart(name: mediaName, data: page.pageImagePNG))

            var relationships: [(id: String, type: String, target: String)] = [
                (
                    "rId1",
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout",
                    "../slideLayouts/slideLayout1.xml"
                ),
                (
                    "rId2",
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                    "../media/image\(slideNumber).png"
                )
            ]
            let imageRelationships: [(image: PDFSceneImage, id: String)] = page.images.enumerated().map { offset, image in
                let relationshipID = "rId\(offset + 3)"
                relationships.append(
                    (
                        relationshipID,
                        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                        "../media/object-\(slideNumber)-\(offset + 1).png"
                    )
                )
                return (image, relationshipID)
            }
            for (offset, image) in page.images.enumerated() {
                parts.append(
                    try OOXMLPart(
                        name: "ppt/media/object-\(slideNumber)-\(offset + 1).png",
                        data: image.pngData
                    )
                )
            }
            let slideXML = makeSlideXML(
                page: page,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                slideWidth: slideWidth,
                slideHeight: slideHeight,
                imageRelationships: imageRelationships
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
        let presentationXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="1" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(slideWidth)" cy="\(slideHeight)" type="custom"/><p:notesSz cx="\(slideWidth)" cy="\(slideHeight)"/><p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr></p:defaultTextStyle></p:presentation>
        """
        parts.append(try OOXMLPart(name: "ppt/presentation.xml", xml: presentationXML))

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
        parts.append(try OOXMLPart(name: "ppt/_rels/presentation.xml.rels", xml: relationshipsXML(presentationRels)))

        let masterXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="KC DeepL Master"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(slideWidth)" cy="\(slideHeight)"/><a:chOff x="0" y="0"/><a:chExt cx="\(slideWidth)" cy="\(slideHeight)"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
        """
        parts.append(try OOXMLPart(name: "ppt/slideMasters/slideMaster1.xml", xml: masterXML))
        parts.append(
            try OOXMLPart(
                name: "ppt/slideMasters/_rels/slideMaster1.xml.rels",
                xml: relationshipsXML([
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
                ])
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
        parts.append(try OOXMLPart(name: "[Content_Types].xml", xml: Self.contentTypes(format: .pptx, pages: scene.pages.count)))
        return parts
    }
}

private extension PresentationMLWriter {
    func makeSlideXML(
        page: PDFScenePage,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        slideWidth: Int,
        slideHeight: Int,
        imageRelationships: [(image: PDFSceneImage, id: String)]
    ) -> String {
        let pageOffsetX: CGFloat = 0
        let pageOffsetY: CGFloat = canvasHeight - page.height
        let nativeVectors = page.vectors
            .filter(\.canOverlayOnPageSafetyNet)
            .sorted { $0.paintOrder < $1.paintOrder }
        var shapeID = 3
        let imageX = emu(pageOffsetX)
        let imageY = emu(pageOffsetY)
        let imageWidth = emu(page.width)
        let imageHeight = emu(page.height)
        var shapes = """
        <p:pic><p:nvPicPr><p:cNvPr id="2" name="PDF page \(page.pageIndex + 1)"/><p:cNvPicPr preferRelativeResize="0"><a:picLocks noSelect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\(imageX)" y="\(imageY)"/><a:ext cx="\(imageWidth)" cy="\(imageHeight)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
        """
        enum Overlay {
            case image(PDFSceneImage, String)
            case vector(PDFSceneVector)
        }
        let overlays = page.images.filter(\.canOverlayOnPageSafetyNet).map { image in
            Overlay.image(
                image,
                imageRelationships.first(where: { $0.image.id == image.id })?.id ?? ""
            )
        } + nativeVectors.map(Overlay.vector)
        func overlaySortKey(_ overlay: Overlay) -> (order: Int, kind: Int, id: String) {
            switch overlay {
            case let .image(image, _):
                return (image.paintOrder, 0, image.id)
            case let .vector(vector):
                return (vector.paintOrder, 1, vector.id)
            }
        }
        for overlay in overlays.sorted(by: { lhs, rhs in
            let left = overlaySortKey(lhs)
            let right = overlaySortKey(rhs)
            if left.order != right.order { return left.order < right.order }
            if left.kind != right.kind { return left.kind < right.kind }
            return left.id < right.id
        }) {
            switch overlay {
            case let .image(image, relationshipID) where !relationshipID.isEmpty:
                let x = emu(pageOffsetX + image.bounds.minX - page.cropBox.minX)
                let y = emu(pageOffsetY + page.height - (image.bounds.maxY - page.cropBox.minY))
                shapes += imageShape(
                    image: image,
                    id: shapeID,
                    relationshipID: relationshipID,
                    x: x,
                    y: y,
                    width: max(1, emu(image.bounds.width)),
                    height: max(1, emu(image.bounds.height))
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
        for textBox in page.textBoxes
        where textBox.visualPolicy == .replaceSourcePaint {
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
                height: height
            )
            shapeID += 1
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="PDF page \(page.pageIndex + 1)"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(slideWidth)" cy="\(slideHeight)"/><a:chOff x="0" y="0"/><a:chExt cx="\(slideWidth)" cy="\(slideHeight)"/></a:xfrm></p:grpSpPr>\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
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
        return "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"PDF image \(XMLValue.attribute(image.sourceName))\"/><p:cNvPicPr preferRelativeResize=\"0\"/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(XMLValue.attribute(relationshipID))\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
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
        let geometry = vector.kind == .line ? "line" : "rect"
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"PDF \(vector.kind.rawValue) \(id)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm rot=\"\(rotation)\"><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"\(geometry)\"><a:avLst/></a:prstGeom>\(fill)\(line)</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr/></a:p></p:txBody></p:sp>"
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
        height: Int
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
        let paragraphs = lines.enumerated().map { index, line in
            let previousLine = index > 0 ? lines[index - 1] : nil
            let spacing = lineSpacingPoints(
                for: line,
                previousLine: previousLine
            )
            let insets = textBox.paragraphInsets(for: line)
            let marginAttributes = drawingParagraphMarginAttributes(insets)
            let tabs = drawingTabStops(for: line, in: textBox)
            let runs = line.runs.isEmpty
                ? drawingRun(
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
                : line.runs.map(drawingRun).joined()
            return "<a:p><a:pPr\(marginAttributes) algn=\"\(paragraphAlignment)\"><a:lnSpc><a:spcPts val=\"\(spacing)\"/></a:lnSpc>\(tabs)</a:pPr>\(runs)<a:endParaRPr/></a:p>"
        }.joined()
        return """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Text \(id)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln w="0"><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr lIns="\(leadingInset)" tIns="0" rIns="\(trailingInset)" bIns="0" wrap="none" anchor="t" vert="horz"><a:noAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>
        """
    }

    func drawingRun(_ run: PDFSceneTextRun) -> String {
        let colorHex = rgbHex(run.color)
        let alpha = Int((max(0, min(1, run.color.alpha)) * 100_000).rounded())
        let fontSize = max(500, min(7200, Int((run.fontSize * 100).rounded())))
        let bold = run.isBold ? " b=\"1\"" : ""
        let italic = run.isItalic ? " i=\"1\"" : ""
        return "<a:r><a:rPr lang=\"en-US\" sz=\"\(fontSize)\"\(bold)\(italic)><a:solidFill><a:srgbClr val=\"\(colorHex)\"><a:alpha val=\"\(alpha)\"/></a:srgbClr></a:solidFill><a:latin typeface=\"\(XMLValue.attribute(run.fontName))\"/><a:ea typeface=\"\(XMLValue.attribute(run.fontName))\"/><a:cs typeface=\"\(XMLValue.attribute(run.fontName))\"/></a:rPr>\(drawingTextElements(run.text))</a:r>"
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

    static func contentTypes(format: DocumentConversionFormat, pages: Int) -> String {
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
            return contentTypesXML(overrides: overrides, imageExtension: "png")
        case .docx:
            return ""
        }
    }

    static func contentTypesXML(overrides: [String], imageExtension: String) -> String {
        let overrideXML = overrides.map { item in
            let components = item.split(separator: "|", maxSplits: 1).map(String.init)
            return "<Override PartName=\"\(components[0])\" ContentType=\"\(components[1])\"/>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"\(imageExtension)\" ContentType=\"image/png\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/><Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>\(overrideXML)</Types>"
    }

    static let themeXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="KC DeepL"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F2937"/></a:dk2><a:lt2><a:srgbClr val="F3F4F6"/></a:lt2><a:accent1><a:srgbClr val="2563EB"/></a:accent1><a:accent2><a:srgbClr val="7C3AED"/></a:accent2><a:accent3><a:srgbClr val="059669"/></a:accent3><a:accent4><a:srgbClr val="D97706"/></a:accent4><a:accent5><a:srgbClr val="DC2626"/></a:accent5><a:accent6><a:srgbClr val="0891B2"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst/><a:lnStyleLst/><a:effectStyleLst/><a:bgFillStyleLst/></a:fmtScheme></a:themeElements></a:theme>
    """
}
