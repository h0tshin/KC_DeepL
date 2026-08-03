import Foundation

struct WordprocessingMLWriter {
    private let emuPerPoint = 12_700.0
    private let twipsPerPoint = 20.0

    func makeParts(scene: PDFSceneDocument) throws -> [OOXMLPart] {
        guard !scene.pages.isEmpty else {
            throw DocumentConversionError.emptyPDF
        }
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
        var pageXML = ""
        var nextRelationshipID = 5
        var nextDocPrID = 1

        for page in scene.pages {
            try Task.checkCancellation()
            let imageName = "word/media/image\(page.pageIndex + 1).png"
            let relationshipID = "rId\(nextRelationshipID)"
            nextRelationshipID += 1
            parts.append(try OOXMLPart(name: imageName, data: page.pageImagePNG))
            relationships.append(
                (
                    relationshipID,
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                    "media/image\(page.pageIndex + 1).png"
                )
            )
            var imageRelationships: [(image: PDFSceneImage, id: String)] = []
            for (offset, image) in page.images.enumerated() {
                let imageRelationshipID = "rId\(nextRelationshipID)"
                nextRelationshipID += 1
                relationships.append(
                    (
                        imageRelationshipID,
                        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                        "media/object-\(page.pageIndex + 1)-\(offset + 1).png"
                    )
                )
                parts.append(
                    try OOXMLPart(
                        name: "word/media/object-\(page.pageIndex + 1)-\(offset + 1).png",
                        data: image.pngData
                    )
                )
                imageRelationships.append((image, imageRelationshipID))
            }

            let pageGeometry = WordPageGeometry(page: page)
            let drawings = makePageDrawings(
                page: page,
                geometry: pageGeometry,
                imageRelationshipID: relationshipID,
                imageRelationships: imageRelationships,
                nextDocPrID: &nextDocPrID
            )
            let section = page.pageIndex == scene.pages.count - 1
                ? ""
                : "<w:sectPr>\(sectionProperties(for: pageGeometry))</w:sectPr>"
            pageXML += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"1\" w:lineRule=\"exact\"/>\(section)</w:pPr>\(drawings)</w:p>"
        }

        let finalGeometry = WordPageGeometry(page: scene.pages.last!)
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:w10="urn:schemas-microsoft-com:office:word" xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" mc:Ignorable="w14 wp14"><w:body>\(pageXML)<w:sectPr>\(sectionProperties(for: finalGeometry))</w:sectPr></w:body></w:document>
        """
        parts.append(try OOXMLPart(name: "word/document.xml", xml: documentXML))
        parts.append(try OOXMLPart(name: "word/_rels/document.xml.rels", xml: relationshipsXML(relationships)))
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
        parts.append(try OOXMLPart(name: "[Content_Types].xml", xml: Self.contentTypes(pageCount: scene.pages.count)))
        return parts
    }
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
    func makePageDrawings(
        page: PDFScenePage,
        geometry: WordPageGeometry,
        imageRelationshipID: String,
        imageRelationships: [(image: PDFSceneImage, id: String)],
        nextDocPrID: inout Int
    ) -> String {
        let imageExtent = (
            cx: emu(geometry.widthPoints),
            cy: emu(geometry.heightPoints)
        )
        var result = "<w:r><w:drawing>\(imageAnchor(page: page, geometry: geometry, relationshipID: imageRelationshipID, docPrID: nextDocPrID, extent: imageExtent))</w:drawing></w:r>"
        nextDocPrID += 1
        enum Overlay {
            case image(PDFSceneImage, String)
            case vector(PDFSceneVector)
        }
        let overlays = page.images.filter(\.canOverlayOnPageSafetyNet).map { image in
            Overlay.image(
                image,
                imageRelationships.first(where: { $0.image.id == image.id })?.id ?? ""
            )
        } + page.vectors.filter(\.canOverlayOnPageSafetyNet).map(Overlay.vector)
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
        for textBox in page.textBoxes
        where textBox.visualPolicy == .replaceSourcePaint {
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
        let line = "<a:ln w=\"\(max(1, Int((Double(vector.lineWidth) * emuPerPoint).rounded())))\"><a:solidFill>\(solidFillBody(vector.stroke))</a:solidFill></a:ln>"
        let rotation = vector.kind == .line ? 0 : Int((vector.rotation * 60_000).rounded())
        let geometry = vector.kind == .line ? "line" : "rect"
        let shape = "<wps:wsp><wps:cNvSpPr/><wps:spPr><a:xfrm rot=\"\(rotation)\"><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"\(geometry)\"><a:avLst/></a:prstGeom>\(fill)\(line)</wps:spPr><wps:bodyPr/></wps:wsp>"
        return anchorPrefix(
            x: x,
            y: y,
            width: width,
            height: height,
            relativeHeight: 1_000_000 + docPrID,
            behindDocument: false
        ) + "<wp:docPr id=\"\(docPrID)\" name=\"PDF \(vector.kind.rawValue) \(docPrID)\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\">\(shape)</a:graphicData></a:graphic></wp:anchor>"
    }

    func textAnchor(
        textBox: PDFSceneTextBox,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        docPrID: Int
    ) -> String {
        let leadingInset = emu(textBox.officeLeadingInset)
        let trailingInset = emu(textBox.officeTrailingInset)
        let shape = """
        <wps:wsp><wps:cNvSpPr txBox="1"/><wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></wps:spPr><wps:txbx><w:txbxContent>\(textBoxContent(textBox))</w:txbxContent></wps:txbx><wps:bodyPr rot="0" vert="horz" wrap="none" lIns="\(leadingInset)" tIns="0" rIns="\(trailingInset)" bIns="0" anchor="t"><a:noAutofit/></wps:bodyPr></wps:wsp>
        """
        return anchorPrefix(
            x: x,
            y: y,
            width: width,
            height: height,
            relativeHeight: 1_000_000 + docPrID,
            behindDocument: false
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
            let nextLine = index + 1 < lines.count ? lines[index + 1] : nil
            let spacing = lineSpacingTwips(
                for: line,
                nextLine: nextLine
            )
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
            return "<w:p><w:pPr>\(tabs)<w:spacing w:before=\"0\" w:after=\"0\" w:line=\"\(spacing)\" w:lineRule=\"atLeast\"/><w:jc w:val=\"\(alignment)\"/></w:pPr>\(runs)</w:p>"
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
        guard let sourceOffset = line.listTabStop else { return "" }
        let relativeOffset = max(
            0.5,
            line.bounds.minX + sourceOffset - textBox.bounds.minX
        )
        let position = max(1, Int((relativeOffset * twipsPerPoint).rounded()))
        return "<w:tabs><w:tab w:val=\"left\" w:pos=\"\(position)\"/></w:tabs>"
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
        nextLine: PDFSceneTextLine?
    ) -> Int {
        let sourceAdvance = nextLine.map {
            max(0, line.bounds.minY - $0.bounds.minY)
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

    func sectionProperties(for geometry: WordPageGeometry) -> String {
        let orientation = geometry.widthPoints > geometry.heightPoints ? " w:orient=\"landscape\"" : ""
        return "<w:pgSz w:w=\"\(geometry.widthTwips)\" w:h=\"\(geometry.heightTwips)\"\(orientation)/><w:pgMar w:top=\"0\" w:right=\"0\" w:bottom=\"0\" w:left=\"0\" w:header=\"0\" w:footer=\"0\" w:gutter=\"0\"/><w:cols w:space=\"0\"/><w:docGrid w:linePitch=\"1\"/>"
    }

    func emu(_ points: CGFloat) -> Int {
        max(1, Int((Double(points) * emuPerPoint).rounded()))
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

    static func contentTypes(pageCount: Int) -> String {
        let overrides = [
            "/word/document.xml|application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
            "/word/styles.xml|application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml",
            "/word/settings.xml|application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml",
            "/word/theme/theme1.xml|application/vnd.openxmlformats-officedocument.theme+xml",
            "/word/fontTable.xml|application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"
        ]
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
