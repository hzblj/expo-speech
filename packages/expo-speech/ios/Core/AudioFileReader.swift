import AVFoundation
import Foundation

/// A decoded stretch of audio and where it starts in the file.
public struct AudioChunk: @unchecked Sendable {
  public let buffer: AVAudioPCMBuffer
  public let start: CMTime
}

/// Decodes the audio track of any file AVFoundation reads (mp3, m4a, wav, caf, aiff, and the audio of mp4 or mov)
/// into PCM in the format the engine wants, resampled and mixed down by `AVAssetReader` itself. Chunks are decoded
/// as they are asked for, so a long file never sits in memory and the engine sets the pace.
public final class AudioFileReader: @unchecked Sendable {
  public let url: URL
  /// The file's length in seconds.
  public let duration: Double
  /// The part to read, in seconds of the file.
  public let range: ClosedRange<Double>
  private let asset: AVURLAsset
  private let track: AVAssetTrack

  public init(url: URL, start: Double? = nil, end: Double? = nil) async throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw SpeechFailure(.audio, "There is no file at \(url.path)")
    }

    let asset = AVURLAsset(url: url)
    let tracks: [AVAssetTrack]
    let duration: CMTime

    do {
      tracks = try await asset.loadTracks(withMediaType: .audio)
      duration = try await asset.load(.duration)
    } catch {
      throw SpeechFailure(.audio, "The file could not be read: \(error.localizedDescription)")
    }
    guard let track = tracks.first else {
      throw SpeechFailure(.audio, "The file has no audio track")
    }

    let seconds = duration.isNumeric ? duration.seconds : 0
    let from = max(0, start ?? 0)
    let to = min(seconds > 0 ? seconds : .greatestFiniteMagnitude, end ?? .greatestFiniteMagnitude)

    self.url = url
    self.asset = asset
    self.track = track
    self.duration = seconds
    self.range = from...max(from, to)
  }

  /// Chunks in `format`: interleaved linear PCM, 16-bit integer or 32-bit float.
  public func chunks(in format: AVAudioFormat) throws -> Chunks {
    try Chunks(reader: self, format: format)
  }

  public struct Chunks: AsyncSequence, @unchecked Sendable {
    public typealias Element = AudioChunk

    fileprivate let reader: AVAssetReader
    fileprivate let output: AVAssetReaderTrackOutput
    fileprivate let format: AVAudioFormat

    fileprivate init(reader file: AudioFileReader, format: AVAudioFormat) throws {
      let reader: AVAssetReader

      do {
        reader = try AVAssetReader(asset: file.asset)
      } catch {
        throw SpeechFailure(.audio, "The file could not be opened: \(error.localizedDescription)")
      }

      let isFloat = format.commonFormat == .pcmFormatFloat32
      let output = AVAssetReaderTrackOutput(
        track: file.track,
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: format.sampleRate,
          AVNumberOfChannelsKey: format.channelCount,
          AVLinearPCMBitDepthKey: isFloat ? 32 : 16,
          AVLinearPCMIsFloatKey: isFloat,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ])
      reader.add(output)

      if file.range.lowerBound > 0 || file.range.upperBound < file.duration {
        reader.timeRange = CMTimeRange(
          start: CMTime(seconds: file.range.lowerBound, preferredTimescale: 48_000),
          end: CMTime(seconds: file.range.upperBound, preferredTimescale: 48_000))
      }
      guard reader.startReading() else {
        throw SpeechFailure(.audio, "The file could not be decoded: \(reader.error?.localizedDescription ?? "unknown")")
      }

      self.reader = reader
      self.output = output
      // The buffers are interleaved, whatever the engine's format says.
      self.format =
        AVAudioFormat(
          commonFormat: format.commonFormat, sampleRate: format.sampleRate, channels: format.channelCount,
          interleaved: true) ?? format
    }

    public func makeAsyncIterator() -> Iterator {
      Iterator(sequence: self)
    }

    public struct Iterator: AsyncIteratorProtocol {
      let sequence: Chunks

      public mutating func next() async throws -> AudioChunk? {
        try Task.checkCancellation()

        while let sample = sequence.output.copyNextSampleBuffer() {
          let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))

          guard frames > 0 else {
            continue
          }
          guard let buffer = AVAudioPCMBuffer(pcmFormat: sequence.format, frameCapacity: frames) else {
            throw SpeechFailure(.audio, "Could not allocate an audio buffer")
          }
          buffer.frameLength = frames

          let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)

          guard status == noErr else {
            throw SpeechFailure(.audio, "The audio could not be decoded (\(status))")
          }
          return AudioChunk(buffer: buffer, start: CMSampleBufferGetPresentationTimeStamp(sample))
        }

        if sequence.reader.status == .failed {
          throw SpeechFailure(
            .audio, "The file could not be decoded: \(sequence.reader.error?.localizedDescription ?? "unknown")")
        }
        return nil
      }
    }

    /// Stops decoding, for a transcription cancelled half way.
    public func cancel() {
      reader.cancelReading()
    }
  }
}
