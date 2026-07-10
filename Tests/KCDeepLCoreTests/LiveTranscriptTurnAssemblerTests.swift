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

    func testDiscardsOrphanTranslationOnlyTurn() {
        var assembler = LiveTranscriptTurnAssembler(speaker: .me)

        XCTAssertTrue(
            assembler.update(
                field: .translation,
                text: "The pattern is in the speech bubble."
            ).isEmpty
        )

        XCTAssertTrue(assembler.finish().isEmpty)
        XCTAssertTrue(assembler.draft.isEmpty)
    }

    func testAppendsLateTranslationOnlyTextToExistingTurnMessage() {
        var assembler = LiveTranscriptTurnAssembler(speaker: .me)

        let changes = assembler.update(field: .original, text: "이거 뭐야?")
            + assembler.update(field: .translation, text: "What is this?")

        XCTAssertEqual(changes.count, 1)
        guard case .append(let firstMessage) = changes[0] else {
            return XCTFail("Expected initial paired message")
        }

        XCTAssertTrue(
            assembler.update(
                field: .translation,
                text: "What is this? Please check it."
            ).isEmpty
        )
        let finalChanges = assembler.finish()

        XCTAssertEqual(finalChanges.count, 1)
        guard case .update(let updatedMessage) = finalChanges[0] else {
            return XCTFail("Expected update on the existing message")
        }
        XCTAssertEqual(updatedMessage.id, firstMessage.id)
        XCTAssertEqual(updatedMessage.originalText, "이거 뭐야?")
        XCTAssertEqual(updatedMessage.translatedText, "What is this? Please check it.")
    }

    func testKeepsLaterSegmentAlignedAfterCombinedTranslation() {
        var assembler = LiveTranscriptTurnAssembler(speaker: .me)

        XCTAssertTrue(assembler.update(field: .original, text: "A. B.").isEmpty)

        let firstChanges = assembler.update(field: .translation, text: "X Y.")
        guard firstChanges.count == 1 else {
            return XCTFail("Expected one first-pair change, got \(firstChanges.count)")
        }
        guard case .append(let firstMessage) = firstChanges[0] else {
            return XCTFail("Expected the first paired message")
        }
        XCTAssertEqual(firstMessage.originalText, "A.")
        XCTAssertEqual(firstMessage.translatedText, "X Y.")

        let settlementChanges = assembler.update(field: .original, text: "A. B. C.")
        guard settlementChanges.count == 1 else {
            return XCTFail("Expected one settlement change, got \(settlementChanges.count)")
        }
        guard case .update(let settledMessage) = settlementChanges[0] else {
            return XCTFail("Expected the unmatched source segment to settle into the previous message")
        }
        XCTAssertEqual(settledMessage.id, firstMessage.id)
        XCTAssertEqual(settledMessage.originalText, "A. B.")
        XCTAssertEqual(settledMessage.translatedText, "X Y.")

        let nextChanges = assembler.update(field: .translation, text: "X Y. Z.")
        guard nextChanges.count == 1 else {
            return XCTFail("Expected one later-pair change, got \(nextChanges.count)")
        }
        guard case .append(let nextMessage) = nextChanges[0] else {
            return XCTFail("Expected the later source and translation to remain paired")
        }
        XCTAssertEqual(nextMessage.originalText, "C.")
        XCTAssertEqual(nextMessage.translatedText, "Z.")
    }

    func testReplacesLikelyRecognitionRevisionInsteadOfDuplicatingIt() {
        var assembler = LiveTranscriptTurnAssembler(speaker: .me)

        XCTAssertTrue(assembler.update(field: .original, text: "I scream").isEmpty)
        XCTAssertTrue(assembler.update(field: .original, text: "ice cream").isEmpty)

        XCTAssertEqual(assembler.draft.originalText, "ice cream")
    }

    func testMergesOverlappingIncrementalTranscriptChunks() {
        var assembler = LiveTranscriptTurnAssembler(speaker: .me)

        XCTAssertTrue(assembler.update(field: .original, text: "hello wor").isEmpty)
        XCTAssertTrue(assembler.update(field: .original, text: "world").isEmpty)

        XCTAssertEqual(assembler.draft.originalText, "hello world")
    }
}
