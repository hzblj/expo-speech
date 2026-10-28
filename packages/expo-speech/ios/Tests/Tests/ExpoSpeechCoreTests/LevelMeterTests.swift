import XCTest

@testable import ExpoSpeechCore

/// A live meter's levels. The same cases as `LevelMeterTest.kt`.
final class LevelMeterTests: XCTestCase {
  private func levels(_ meter: inout LevelMeter, _ samples: [Float], muted: Bool = false) -> [Float] {
    samples.withUnsafeBufferPointer { meter.add($0, muted: muted) }
  }

  func testOneLevelPerStretchAcrossBuffers() {
    var meter = LevelMeter(frames: 4)
    XCTAssertEqual(levels(&meter, [0.5, -0.5, 0.5]), [])
    XCTAssertEqual(levels(&meter, [-0.5, 0, 0, 0, 0, 1]), [0.5, 0])
    XCTAssertEqual(levels(&meter, [1, 1, 1]), [1])
  }

  func testMutedIsSilence() {
    var meter = LevelMeter(frames: 2)
    XCTAssertEqual(levels(&meter, [1, 1, 1, 1], muted: true), [0, 0])
  }

  func testAtLeastOneFrame() {
    var meter = LevelMeter(frames: 0)
    XCTAssertEqual(levels(&meter, [0.25, -0.25]), [0.25, 0.25])
  }
}
