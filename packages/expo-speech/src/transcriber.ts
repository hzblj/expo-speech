import {ExpoSpeech, type SpeechTranscriber, type Transcription} from './ExpoSpeechModule'
import {resolveSource} from './source'
import type {SpeechSource, TranscribeOptions} from './types'

/**
 * `transcribe` lives in JavaScript, on the native class's prototype: a `require()`d asset becomes a URI here, which
 * only React Native can resolve, and the native side gets a URI and headers.
 */
ExpoSpeech.SpeechTranscriber.prototype.transcribe = function transcribe(
  this: SpeechTranscriber,
  source: SpeechSource,
  options: TranscribeOptions = {}
): Transcription {
  const {headers, uri} = resolveSource(source)

  return this.transcribeUri(uri, {...options, headers: {...headers, ...options.headers}})
}
