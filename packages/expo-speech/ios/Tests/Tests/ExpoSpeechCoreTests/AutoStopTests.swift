import XCTest

@testable import ExpoSpeechCore

/// `autoStop`'s timing, at a few tens of milliseconds. The same cases as `AutoStopTest.kt`.
final class AutoStopTests: XCTestCase {
  private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Date] = []

    var count: Int { lock.withLock { times.count } }
    var first: Date? { lock.withLock { times.first } }

    func record() {
      lock.withLock { times.append(Date()) }
    }
  }

  private func make(afterSilence: Double?, withoutSpeech: Double?) -> (AutoStop, Fired) {
    let fired = Fired()
    let autoStop = AutoStop(afterSilence: afterSilence, withoutSpeech: withoutSpeech) { fired.record() }!
    return (autoStop, fired)
  }

  private func wait(_ seconds: Double) {
    let done = expectation(description: "waited")
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.fulfill() }
    wait(for: [done], timeout: seconds + 1)
  }

  func testOffWhenNeitherIsSet() {
    XCTAssertNil(AutoStop(afterSilence: nil, withoutSpeech: nil) {})
  }

  func testStopsWhenNothingIsSaid() {
    let (autoStop, fired) = make(afterSilence: 0.05, withoutSpeech: 0.1)
    let started = Date()
    autoStop.start()
    wait(0.25)
    XCTAssertEqual(fired.count, 1)
    XCTAssertGreaterThanOrEqual(fired.first!.timeIntervalSince(started), 0.1)
  }

  func testWaitsForTheMicrophoneToOpen() {
    let (_, fired) = make(afterSilence: 0.05, withoutSpeech: 0.05)
    wait(0.15)
    XCTAssertEqual(fired.count, 0)
  }

  func testEachNewTextRestartsTheSilence() {
    let (autoStop, fired) = make(afterSilence: 0.1, withoutSpeech: nil)
    autoStop.start()
    autoStop.heard("box")
    wait(0.06)
    autoStop.heard("box box")
    wait(0.06)
    XCTAssertEqual(fired.count, 0)
    wait(0.1)
    XCTAssertEqual(fired.count, 1)
  }

  func testPunctuationAddedAsAResultSettlesIsNotSpeech() {
    let (autoStop, fired) = make(afterSilence: 0.1, withoutSpeech: nil)
    autoStop.start()
    autoStop.heard("box this lap")
    wait(0.06)
    autoStop.heard("Box this lap.")
    wait(0.07)
    XCTAssertEqual(fired.count, 1)
  }

  func testWithoutAfterSilenceItRunsOnOnceSomethingIsHeard() {
    let (autoStop, fired) = make(afterSilence: nil, withoutSpeech: 0.05)
    autoStop.start()
    autoStop.heard("push now")
    wait(0.15)
    XCTAssertEqual(fired.count, 0)
  }

  func testNothingFiresWhileSpeechIsDetected() {
    let (autoStop, fired) = make(afterSilence: 0.05, withoutSpeech: 0.05)
    autoStop.start()
    autoStop.speech(true)
    wait(0.15)
    XCTAssertEqual(fired.count, 0)
    autoStop.speech(false)
    wait(0.15)
    XCTAssertEqual(fired.count, 1)
  }

  func testPausingHoldsTheWaitAndResumingStartsItAgain() {
    let (autoStop, fired) = make(afterSilence: 0.1, withoutSpeech: nil)
    autoStop.start()
    autoStop.heard("box")
    autoStop.setPaused(true)
    wait(0.2)
    XCTAssertEqual(fired.count, 0)
    autoStop.setPaused(false)
    wait(0.05)
    XCTAssertEqual(fired.count, 0)
    wait(0.15)
    XCTAssertEqual(fired.count, 1)
  }

  func testFiresOnceAndNeverAfterCancel() {
    let (autoStop, fired) = make(afterSilence: 0.03, withoutSpeech: 0.03)
    autoStop.start()
    wait(0.1)
    autoStop.heard("again")
    wait(0.1)
    XCTAssertEqual(fired.count, 1)

    let (cancelled, none) = make(afterSilence: 0.03, withoutSpeech: 0.03)
    cancelled.start()
    cancelled.cancel()
    wait(0.1)
    XCTAssertEqual(none.count, 0)
  }
}

/// The listen and transcriber options as JavaScript sends them.
final class OptionsTests: XCTestCase {
  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
  }

  func testOnDeviceDefaultsToRequired() throws {
    XCTAssertEqual(try decode(TranscriberOptions.self, "{}").onDevice, .required)
    XCTAssertEqual(try decode(TranscriberOptions.self, #"{"onDevice":"preferred"}"#).onDevice, .preferred)
    XCTAssertEqual(try decode(TranscriberOptions.self, #"{"onDevice":"off"}"#).onDevice, .off)
  }

  func testTheCacheTellsOnDeviceModesApart() throws {
    let required = try decode(TranscriberOptions.self, #"{"onDevice":"required"}"#)
    let preferred = try decode(TranscriberOptions.self, #"{"onDevice":"preferred"}"#)
    XCTAssertNotEqual(required.fingerprint, preferred.fingerprint)
  }

  func testListenOptions() throws {
    let options = try decode(
      ListenOptions.self,
      #"{"autoStop":{"afterSilence":1500,"withoutSpeech":5000},"voiceProcessing":true,"ios":{"audioSession":"manual"}}"#)
    XCTAssertEqual(options.stopAfterSilence, 1.5)
    XCTAssertEqual(options.stopWithoutSpeech, 5)
    XCTAssertTrue(options.voiceProcessing)
    XCTAssertEqual(options.audioSession, "manual")

    let defaults = try decode(ListenOptions.self, "{}")
    XCTAssertNil(defaults.stopAfterSilence)
    XCTAssertNil(defaults.stopWithoutSpeech)
    XCTAssertFalse(defaults.voiceProcessing)
  }
}
