import XCTest
@testable import KCDeepLCore

final class LiveTranscriptTurnAssemblerTests: XCTestCase {
    func testPairsTranslationThatArrivesBeforeOriginal() {
        var assembler = LiveTranscriptTurnAssembler(speaker: .me)

        XCTAssertTrue(assembler.update(field: .translation, text: "Hello.").isEmpty)
        XCTAssertEqual(assembler.draft.translatedText, "Hello.")

        let changes = assembler.update(field: .original, text: "안녕하세요.")

        XCTAssertEqual(changes.count, 1)
        guard case .append(let message) = changes[0] else {
            return XCTFail("Expected appended paired message")
        }
        XCTAssertEqual(message.originalText, "안녕하세요.")
        XCTAssertEqual(message.translatedText, "Hello.")
        XCTAssertTrue(assembler.draft.isEmpty)
    }

    func testMergesExtraOriginalSegmentsIntoLastMessageOnTurnComplete() {
        var assembler = LiveTranscriptTurnAssembler(speaker: .me)

        XCTAssertTrue(assembler.update(field: .original, text: "안녕하세요. 잘 가요.").isEmpty)
        let paired = assembler.update(field: .translation, text: "Hello and goodbye.")

        XCTAssertEqual(paired.count, 1)
        guard case .append(let firstMessage) = paired[0] else {
            return XCTFail("Expected first paired message")
        }
        XCTAssertEqual(firstMessage.originalText, "안녕하세요.")
        XCTAssertEqual(firstMessage.translatedText, "Hello and goodbye.")
        XCTAssertEqual(assembler.draft.originalText, "잘 가요.")

        let finalChanges = assembler.finish()

        XCTAssertEqual(finalChanges.count, 1)
        guard case .update(let updatedMessage) = finalChanges[0] else {
            return XCTFail("Expected update for the existing turn message")
        }
        XCTAssertEqual(updatedMessage.id, firstMessage.id)
        XCTAssertEqual(updatedMessage.originalText, "안녕하세요. 잘 가요.")
        XCTAssertEqual(updatedMessage.translatedText, "Hello and goodbye.")
        XCTAssertTrue(assembler.draft.isEmpty)
    }

    func testMergesExtraTranslationSegmentsIntoLastMessageOnTurnComplete() {
        var assembler = LiveTranscriptTurnAssembler(speaker: .me)

        XCTAssertTrue(assembler.update(field: .translation, text: "Hello. Goodbye.").isEmpty)
        let paired = assembler.update(field: .original, text: "안녕하세요 그리고 잘 가요.")

        XCTAssertEqual(paired.count, 1)
        guard case .append(let firstMessage) = paired[0] else {
            return XCTFail("Expected first paired message")
        }
        XCTAssertEqual(firstMessage.originalText, "안녕하세요 그리고 잘 가요.")
        XCTAssertEqual(firstMessage.translatedText, "Hello.")
        XCTAssertEqual(assembler.draft.translatedText, "Goodbye.")

        let finalChanges = assembler.finish()

        XCTAssertEqual(finalChanges.count, 1)
        guard case .update(let updatedMessage) = finalChanges[0] else {
            return XCTFail("Expected update for the existing turn message")
        }
        XCTAssertEqual(updatedMessage.id, firstMessage.id)
        XCTAssertEqual(updatedMessage.originalText, "안녕하세요 그리고 잘 가요.")
        XCTAssertEqual(updatedMessage.translatedText, "Hello. Goodbye.")
        XCTAssertTrue(assembler.draft.isEmpty)
    }

    func testKeepsNewlineSeparatedOriginalAndTranslationAligned() {
        var assembler = LiveTranscriptTurnAssembler(speaker: .other)

        let firstChanges = assembler.update(
            field: .original,
            text: "First source sentence.\nSecond source sentence."
        )
        XCTAssertTrue(firstChanges.isEmpty)

        let secondChanges = assembler.update(
            field: .translation,
            text: "첫 문장입니다\n두 번째 문장입니다"
        )
        XCTAssertEqual(secondChanges.count, 1)

        guard case .append(let firstMessage) = secondChanges[0] else {
            return XCTFail("Expected first paired message")
        }
        XCTAssertEqual(firstMessage.originalText, "First source sentence.")
        XCTAssertEqual(firstMessage.translatedText, "첫 문장입니다")
        XCTAssertEqual(assembler.draft.originalText, "Second source sentence.")
        XCTAssertEqual(assembler.draft.translatedText, "두 번째 문장입니다")

        let finalChanges = assembler.finish()

        XCTAssertEqual(finalChanges.count, 1)
        guard case .append(let secondMessage) = finalChanges[0] else {
            return XCTFail("Expected second paired message")
        }
        XCTAssertEqual(secondMessage.originalText, "Second source sentence.")
        XCTAssertEqual(secondMessage.translatedText, "두 번째 문장입니다")
        XCTAssertTrue(assembler.draft.isEmpty)
    }

    func testCumulativeTranscriptDoesNotDuplicateConsumedSegments() {
        var assembler = LiveTranscriptTurnAssembler(speaker: .me)

        XCTAssertTrue(assembler.update(field: .original, text: "버전 4.0입니다 다음").isEmpty)
        XCTAssertEqual(assembler.draft.originalText, "버전 4.0입니다 다음")

        XCTAssertTrue(assembler.update(field: .original, text: "버전 4.0입니다 다음 단계입니다").isEmpty)
        XCTAssertEqual(assembler.draft.originalText, "버전 4.0입니다 다음 단계입니다")

        let changes = assembler.update(field: .translation, text: "It is version 4.0. This is the next step.")

        XCTAssertEqual(changes.count, 1)
        guard case .append(let message) = changes[0] else {
            return XCTFail("Expected paired message")
        }
        XCTAssertEqual(message.originalText, "버전 4.0입니다")
        XCTAssertEqual(message.translatedText, "It is version 4.0.")

        let finalChanges = assembler.finish()
        XCTAssertEqual(finalChanges.count, 1)
        guard case .append(let secondMessage) = finalChanges[0] else {
            return XCTFail("Expected paired message with the remaining cumulative content")
        }
        XCTAssertNotEqual(secondMessage.id, message.id)
        XCTAssertEqual(secondMessage.originalText, "다음 단계입니다")
        XCTAssertEqual(secondMessage.translatedText, "This is the next step.")
    }
}
