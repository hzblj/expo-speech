import Foundation

/// `autoStop` for the microphone: fires once, `afterSilence` seconds after the last thing heard, or `withoutSpeech`
/// seconds after the microphone opened while nothing has been. Heard is text that changed (letters and digits only, so a
/// result that only gains punctuation or capitals as it settles is not new speech) or speech detected. Nothing fires
/// while speech is detected or while paused; either restarts the wait when it ends. The same rules as `AutoStop.kt`.
public final class AutoStop: @unchecked Sendable {
  private let afterSilence: Double?
  private let withoutSpeech: Double?
  private let queue: DispatchQueue
  private let onFire: @Sendable () -> Void
  private let lock = NSLock()
  private var generation = 0
  private var started = false
  private var heardAnything = false
  private var speaking = false
  private var paused = false
  private var finished = false
  private var lastText = ""

  /// `nil` when both are off.
  public init?(
    afterSilence: Double?, withoutSpeech: Double?, queue: DispatchQueue = .global(), onFire: @escaping @Sendable () -> Void
  ) {
    guard afterSilence != nil || withoutSpeech != nil else {
      return nil
    }
    self.afterSilence = afterSilence
    self.withoutSpeech = withoutSpeech
    self.queue = queue
    self.onFire = onFire
  }

  /// The microphone opened: the wait for speech starts.
  public func start() {
    update { started = true }
  }

  /// A result's text; only a change counts.
  public func heard(_ text: String) {
    let words = String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    reschedule {
      guard !words.isEmpty, words != lastText else {
        return false
      }
      lastText = words
      heardAnything = true
      return true
    }
  }

  public func speech(_ detected: Bool) {
    update {
      speaking = detected
      heardAnything = heardAnything || detected
    }
  }

  public func setPaused(_ paused: Bool) {
    update { self.paused = paused }
  }

  /// Never fires after this.
  public func cancel() {
    update { finished = true }
  }

  private func update(_ change: () -> Void) {
    reschedule {
      change()
      return true
    }
  }

  /// Applies the change and, when it changed anything, replaces the pending wait with the one the state calls for.
  private func reschedule(after change: () -> Bool) {
    lock.withLock {
      guard change() else {
        return
      }
      generation += 1
      guard started, !finished, !speaking, !paused, let delay = heardAnything ? afterSilence : withoutSpeech else {
        return
      }
      let scheduled = generation
      queue.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.fire(scheduled)
      }
    }
  }

  private func fire(_ scheduled: Int) {
    let due = lock.withLock { () -> Bool in
      guard scheduled == generation, !finished else {
        return false
      }
      finished = true
      return true
    }
    if due {
      onFire()
    }
  }
}
