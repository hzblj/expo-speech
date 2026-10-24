import XCTest

@testable import ExpoSpeechCore

final class TranscriptAssemblerTests: XCTestCase {
  private func slice(_ text: String, _ range: [Int]) -> String {
    let utf16 = Array(text.utf16)
    return String(decoding: utf16[range[0]..<range[1]], as: UTF16.self)
  }

  func testWordsKeepTheirTimesAndOffsets() {
    let result = RecognizedResult(
      runs: [
        RecognizedRun(text: "Box,", start: 0.06, end: 0.72, confidence: 0.84),
        RecognizedRun(text: " box,", start: 0.72, end: 1.44, confidence: 0.57),
        RecognizedRun(text: " this", start: 1.8, end: 2.16, confidence: 0.97),
      ], start: 0.06, end: 2.16, isFinal: true)
    let assembler = TranscriptAssembler(locale: "en-GB")
    let segment = assembler.appendFinal([result])[0]

    XCTAssertEqual(segment.text, "Box, box, this")
    XCTAssertEqual(segment.words.map(\.text), ["Box,", "box,", "this"])
    XCTAssertEqual(segment.words.map(\.timing), ["measured", "measured", "measured"])
    XCTAssertEqual(segment.words[1].start, 0.72)
    XCTAssertEqual(segment.words[2].end, 2.16)
    for word in segment.words {
      XCTAssertEqual(slice(assembler.transcript.text, word.range), word.text)
    }
    XCTAssertEqual(segment.confidence!, (0.84 + 0.57 + 0.97) / 3, accuracy: 0.0001)
  }

  func testSegmentsFollowEachOtherWithASpaceWhereNeitherHasOne() {
    let assembler = TranscriptAssembler(locale: "en-GB")
    assembler.appendFinal([RecognizedResult(runs: [RecognizedRun(text: "Box box")], start: 0, end: 1, isFinal: true)])
    let second = assembler.appendFinal([
      RecognizedResult(runs: [RecognizedRun(text: "push now")], start: 1, end: 2, isFinal: true)
    ])[0]

    XCTAssertEqual(assembler.transcript.text, "Box box push now")
    XCTAssertEqual(second.range, [7, 16])
    XCTAssertEqual(slice(assembler.transcript.text, second.words[0].range), "push")
  }

  func testAppleSpacingIsKept() {
    let assembler = TranscriptAssembler(locale: "en-GB")
    assembler.appendFinal([
      RecognizedResult(runs: [RecognizedRun(text: "Box this")], start: 0, end: 1, isFinal: true),
      RecognizedResult(runs: [RecognizedRun(text: " lap.")], start: 1, end: 2, isFinal: true),
      RecognizedResult(runs: [RecognizedRun(text: " Push ")], start: 2, end: 3, isFinal: true),
      RecognizedResult(runs: [RecognizedRun(text: "now.")], start: 3, end: 4, isFinal: true),
    ])

    XCTAssertEqual(assembler.transcript.text, "Box this lap. Push now.")
    XCTAssertEqual(assembler.transcript.words.map(\.text), ["Box", "this", "lap.", "Push", "now."])
  }

  func testUntimedWordsShareTheResultsTimeByLength() {
    let result = RecognizedResult(runs: [RecognizedRun(text: " Verstappen is two")], start: 2, end: 4, isFinal: false)
    let assembler = TranscriptAssembler(locale: "en-GB")
    let volatile = assembler.setVolatile(result)!

    XCTAssertFalse(volatile.isFinal)
    XCTAssertEqual(volatile.words.map(\.timing), ["estimated", "estimated", "estimated"])
    XCTAssertEqual(volatile.words[0].start, 2)
    XCTAssertEqual(volatile.words[2].end, 4, accuracy: 0.0001)
    XCTAssertGreaterThan(volatile.words[0].end - volatile.words[0].start, volatile.words[1].end - volatile.words[1].start)
  }

  func testAMultiWordRunIsSplitWithEstimatedTimes() {
    let result = RecognizedResult(
      runs: [
        RecognizedRun(text: "box this lap", start: 1.44, end: 2.6),
        RecognizedRun(text: " Verstappen", start: 2.67, end: 3.3),
      ], start: 1.44, end: 3.3, isFinal: true)
    let words = TranscriptAssembler(locale: "en-GB").appendFinal([result])[0].words

    XCTAssertEqual(words.map(\.text), ["box", "this", "lap", "Verstappen"])
    XCTAssertEqual(words.map(\.timing), ["estimated", "estimated", "estimated", "measured"])
    XCTAssertEqual(words[0].start, 1.44)
    XCTAssertEqual(words[2].end, 2.6, accuracy: 0.0001)
  }

  func testUntimedWordsBetweenTimedOnesFillTheGap() {
    let result = RecognizedResult(
      runs: [
        RecognizedRun(text: "Box", start: 0, end: 0.5),
        RecognizedRun(text: " this "),
        RecognizedRun(text: "lap", start: 1.5, end: 2),
      ], start: 0, end: 2, isFinal: true)
    let words = TranscriptAssembler(locale: "en-GB").appendFinal([result])[0].words

    XCTAssertEqual(words[1].text, "this")
    XCTAssertEqual(words[1].start, 0.5)
    XCTAssertEqual(words[1].end, 1.5, accuracy: 0.0001)
  }

  func testAFinalResultReplacesTheVolatileOne() {
    let assembler = TranscriptAssembler(locale: "en-GB")
    assembler.setVolatile(RecognizedResult(runs: [RecognizedRun(text: "Box bo")], start: 0, end: 1, isFinal: false))
    XCTAssertEqual(assembler.transcript.text, "Box bo")

    assembler.appendFinal([RecognizedResult(runs: [RecognizedRun(text: "Box box")], start: 0, end: 1, isFinal: true)])
    XCTAssertEqual(assembler.transcript.text, "Box box")
    XCTAssertNil(assembler.currentVolatile)

    assembler.setVolatile(RecognizedResult(runs: [RecognizedRun(text: "push")], start: 1, end: 2, isFinal: false))
    XCTAssertEqual(assembler.transcript.text, "Box box push")
    XCTAssertEqual(assembler.transcript.segments.last?.range, [7, 12])
    XCTAssertEqual(assembler.finalTranscript.text, "Box box")
  }

  func testWordsOffsetsCountUTF16() {
    let assembler = TranscriptAssembler(locale: "cs-CZ")
    assembler.appendFinal([
      RecognizedResult(runs: [RecognizedRun(text: "Boxuj 🏁 teď")], start: 0, end: 1, isFinal: true)
    ])
    let text = assembler.transcript.text

    XCTAssertEqual(assembler.transcript.words.map { slice(text, $0.range) }, ["Boxuj", "🏁", "teď"])
  }

  func testEmptyResultsAreDropped() {
    let assembler = TranscriptAssembler(locale: "en-GB")
    XCTAssertEqual(assembler.appendFinal([RecognizedResult(runs: [], start: 0, end: 0, isFinal: true)]).count, 0)
    XCTAssertNil(assembler.setVolatile(RecognizedResult(runs: [], start: 0, end: 0, isFinal: false)))
  }

  func testTheTranscriptEncodesForJavaScript() throws {
    let assembler = TranscriptAssembler(locale: "en-GB")
    assembler.appendFinal([RecognizedResult(runs: [RecognizedRun(text: "Box", start: 0, end: 1)], start: 0, end: 1, isFinal: true)])
    let json = assembler.transcript.json

    XCTAssertEqual(json["text"] as? String, "Box")
    XCTAssertTrue(json["duration"] is NSNull)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
  }
  func testPunctuationInARunOfItsOwnStaysWithItsWord() {
    let result = RecognizedResult(
      runs: [
        RecognizedRun(text: "heating", start: 4.68, end: 5.2),
        RecognizedRun(text: ".", start: 6.72, end: 6.72),
        RecognizedRun(text: " I", start: 6.72, end: 6.75),
      ], start: 4.68, end: 6.75, isFinal: true)
    let assembler = TranscriptAssembler(locale: "en-GB")
    let words = assembler.appendFinal([result])[0].words

    XCTAssertEqual(words.map(\.text), ["heating.", "I"])
    XCTAssertEqual(words[0].start, 4.68)
    XCTAssertEqual(words[0].end, 6.72)
    XCTAssertEqual(slice(assembler.transcript.text, words[0].range), "heating.")
  }
}
