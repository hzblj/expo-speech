import Foundation

/// The root mean square of each stretch of `frames` samples, as the samples come in buffers of any size: a live meter's
/// levels, from 0 to 1. The same rules as `LevelMeter.kt`.
public struct LevelMeter: Sendable {
  public let frames: Int
  private var sum: Float = 0
  private var count = 0

  public init(frames: Int) {
    self.frames = max(1, frames)
  }

  /// The levels of the stretches these samples complete; a stretch they leave open goes on with the next ones.
  public mutating func add(_ samples: UnsafeBufferPointer<Float>, muted: Bool = false) -> [Float] {
    var levels: [Float] = []
    for sample in samples {
      let value = muted ? 0 : sample
      sum += value * value
      count += 1
      if count >= frames {
        levels.append(min(1, (sum / Float(count)).squareRoot()))
        sum = 0
        count = 0
      }
    }
    return levels
  }
}
