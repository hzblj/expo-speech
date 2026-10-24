import assert from 'node:assert/strict'
import {test} from 'node:test'

import {
  applyTranscriptUpdate,
  emptyTranscript,
  finalTranscript,
  isWordActive,
  segmentIndexAt,
  toSRT,
  toWebVTT,
  wordIndexAt,
} from '../src/transcript'
import type {TranscriptSegment, TranscriptWord} from '../src/types'

/** A segment the way the native side places it: `text` starting at `offset` of the transcript. */
const segment = (
  text: string,
  offset: number,
  start: number,
  end: number,
  isFinal = true,
  words: [string, number, number][] = []
): TranscriptSegment => {
  let cursor = 0
  const placed = words.map<TranscriptWord>(([word, wordStart, wordEnd]) => {
    const at = text.indexOf(word, cursor)
    cursor = at + word.length
    return {
      confidence: 0.9,
      end: wordEnd,
      range: [offset + at, offset + at + word.length],
      start: wordStart,
      text: word,
      timing: 'measured',
    }
  })
  return {
    alternatives: [],
    confidence: 0.9,
    end,
    isFinal,
    language: null,
    range: [offset, offset + text.length],
    start,
    text,
    words: placed,
  }
}

const first = segment('Box, box.', 0, 0, 1, true, [
  ['Box,', 0, 0.4],
  ['box.', 0.5, 1],
])
const second = segment(' Push now.', 9, 1.2, 2, true, [
  ['Push', 1.2, 1.5],
  ['now.', 1.6, 2],
])

test('final segments are appended and the volatile one replaced', () => {
  let transcript = emptyTranscript('en-GB')

  transcript =
    applyTranscriptUpdate(transcript, {segments: [], volatile: segment('Box bo', 0, 0, 1, false)}) ?? transcript
  assert.equal(transcript.text, 'Box bo')

  transcript =
    applyTranscriptUpdate(transcript, {segments: [first], volatile: segment(' Pu', 9, 1, 2, false)}) ?? transcript
  assert.equal(transcript.text, 'Box, box. Pu')
  assert.equal(transcript.segments.length, 2)

  transcript = applyTranscriptUpdate(transcript, {segments: [second], volatile: null}) ?? transcript
  assert.equal(transcript.text, 'Box, box. Push now.')
  assert.deepEqual(
    transcript.words.map(word => transcript.text.slice(word.range[0], word.range[1])),
    ['Box,', 'box.', 'Push', 'now.']
  )
})

test('an update already in the snapshot is skipped, a gap asks for a fresh read', () => {
  const transcript = applyTranscriptUpdate(emptyTranscript('en-GB'), {segments: [first, second], volatile: null})
  assert.ok(transcript)

  assert.equal(applyTranscriptUpdate(transcript, {segments: [first], volatile: null})?.text, 'Box, box. Push now.')
  assert.equal(applyTranscriptUpdate(emptyTranscript(), {segments: [second], volatile: null}), null)
  assert.equal(applyTranscriptUpdate(emptyTranscript(), {segments: [], volatile: segment(' x', 9, 0, 1, false)}), null)
})

test('the final transcript drops the volatile tail', () => {
  const transcript = applyTranscriptUpdate(emptyTranscript(), {
    segments: [first],
    volatile: segment(' Pu', 9, 1, 2, false),
  })
  assert.equal(transcript && finalTranscript(transcript).text, 'Box, box.')
})

test('words and segments are found by time', () => {
  const transcript = applyTranscriptUpdate(emptyTranscript(), {segments: [first, second], volatile: null})
  assert.ok(transcript)

  assert.equal(wordIndexAt(transcript, -1), -1)
  assert.equal(wordIndexAt(transcript, 0), 0)
  assert.equal(wordIndexAt(transcript, 0.45), 0)
  assert.equal(wordIndexAt(transcript, 1.55), 2)
  assert.equal(wordIndexAt(transcript, 99), 3)
  assert.equal(segmentIndexAt(transcript, 1.3), 1)
  assert.equal(isWordActive(transcript.words[0] as TranscriptWord, 0.45), false)
  assert.equal(isWordActive(transcript.words[1] as TranscriptWord, 0.6), true)
})

test('subtitles: WebVTT and SRT, long segments split between words', () => {
  const transcript = applyTranscriptUpdate(emptyTranscript(), {segments: [first, second], volatile: null})
  assert.ok(transcript)

  assert.equal(
    toWebVTT(transcript),
    'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nBox, box.\n\n00:00:01.200 --> 00:00:02.000\nPush now.\n'
  )
  assert.equal(
    toSRT(transcript, {maxCharacters: 5}),
    '1\n00:00:00,000 --> 00:00:00,400\nBox,\n\n2\n00:00:00,500 --> 00:00:01,000\nbox.\n\n3\n00:00:01,200 --> 00:00:01,500\nPush\n\n4\n00:00:01,600 --> 00:00:02,000\nnow.\n'
  )
})
