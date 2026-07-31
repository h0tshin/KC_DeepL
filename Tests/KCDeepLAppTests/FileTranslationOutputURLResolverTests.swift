import Foundation
import XCTest
@testable import KCDeepL
import KCDeepLCore

final class FileTranslationOutputURLResolverTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepL-OutputResolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testSuggestedFilenameIncludesTargetLanguage() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Annual Report.pdf")

        let filename = try FileTranslationOutputURLResolver().suggestedFilename(
            for: sourceURL,
            targetLanguage: .korean
        )

        XCTAssertEqual(filename, "Annual Report.ko.translated.pdf")
    }

    func testExplicitDestinationAddsPDFExtension() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let destination = temporaryDirectory.appendingPathComponent("translated")

        let resolved = try FileTranslationOutputURLResolver().resolve(
            sourceURL: sourceURL,
            targetLanguage: .english,
            locationRawValue: FileTranslationOutputLocation.ask.rawValue,
            explicitlySelectedURL: destination
        )

        XCTAssertEqual(resolved.pathExtension, "pdf")
        XCTAssertEqual(resolved.lastPathComponent, "translated.pdf")
    }

    func testResolverNeverOverwritesSource() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")

        XCTAssertThrowsError(
            try FileTranslationOutputURLResolver().resolve(
                sourceURL: sourceURL,
                targetLanguage: .korean,
                locationRawValue: FileTranslationOutputLocation.ask.rawValue,
                explicitlySelectedURL: sourceURL
            )
        ) { error in
            XCTAssertEqual(
                error as? FileTranslationOutputURLResolverError,
                .sourceWouldBeOverwritten
            )
        }
    }

    func testResolverUsesNumberedNameWhenDestinationExists() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let destination = temporaryDirectory.appendingPathComponent("translated.pdf")
        try Data("existing".utf8).write(to: destination)

        let resolved = try FileTranslationOutputURLResolver().resolve(
            sourceURL: sourceURL,
            targetLanguage: .korean,
            locationRawValue: FileTranslationOutputLocation.ask.rawValue,
            explicitlySelectedURL: destination
        )

        XCTAssertEqual(resolved.lastPathComponent, "translated (2).pdf")
    }
}
