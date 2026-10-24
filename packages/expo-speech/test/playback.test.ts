import assert from 'node:assert/strict'
import {test} from 'node:test'

import {PlaybackFollower} from '../src/playback'

/** A clock and timers that move only when told to. */
const fakeTime = () => {
  let now = 0
  let timers: {at: number; callback: () => void; id: number}[] = []
  let ids = 0

  return {
    advance(milliseconds: number) {
      const target = now + milliseconds
      for (;;) {
        const next = timers.filter(timer => timer.at <= target).sort((a, b) => a.at - b.at)[0]
        if (!next) {
          break
        }
        now = next.at
        timers = timers.filter(timer => timer !== next)
        next.callback()
      }
      now = target
    },
    options: {
      clearTimeout: (handle: unknown) => {
        timers = timers.filter(timer => timer.id !== handle)
      },
      now: () => now,
      setTimeout: (callback: () => void, milliseconds: number) => {
        ids += 1
        timers.push({at: now + milliseconds, callback, id: ids})
        return ids
      },
    },
    get pending() {
      return timers.length
    },
  }
}

const words = [{start: 0.5}, {start: 1}, {start: 2.5}]

test('the follower moves on exactly when the next word starts, without reports in between', () => {
  const time = fakeTime()
  const changes: number[] = []
  const follower = new PlaybackFollower(words, index => changes.push(index), time.options)

  follower.report({playing: true, rate: 1, time: 0})
  assert.deepEqual(changes, [])

  time.advance(499)
  assert.deepEqual(changes, [])
  time.advance(2)
  assert.deepEqual(changes, [0])
  time.advance(500)
  assert.deepEqual(changes, [0, 1])
  time.advance(2000)
  assert.deepEqual(changes, [0, 1, 2])
  assert.equal(time.pending, 0)
})

test('the playback rate shortens the wait, a pause stops it, a seek jumps', () => {
  const time = fakeTime()
  const changes: number[] = []
  const follower = new PlaybackFollower(words, index => changes.push(index), time.options)

  follower.report({playing: true, rate: 2, time: 0})
  time.advance(260)
  assert.deepEqual(changes, [0])

  follower.report({playing: false})
  time.advance(5000)
  assert.deepEqual(changes, [0])

  follower.report({time: 2.6})
  assert.deepEqual(changes, [0, 2])
  follower.report({time: 0})
  assert.deepEqual(changes, [0, 2, -1])
})

test('reports set the reckoned time right', () => {
  const time = fakeTime()
  const follower = new PlaybackFollower(words, () => undefined, time.options)

  follower.report({playing: true, rate: 1, time: 1})
  time.advance(250)
  assert.equal(follower.time, 1.25)

  follower.report({time: 1.2})
  time.advance(100)
  assert.ok(Math.abs(follower.time - 1.3) < 1e-9)
  follower.dispose()
})

test('new items take effect at once', () => {
  const time = fakeTime()
  const changes: number[] = []
  const follower = new PlaybackFollower([], index => changes.push(index), time.options)

  follower.report({playing: true, time: 1.1})
  follower.setItems(words)
  assert.deepEqual(changes, [1])
})

test('once the last word has ended, every word is said and none is current', () => {
  const time = fakeTime()
  const changes: number[] = []
  const timed = [
    {end: 0.9, start: 0.5},
    {end: 1.4, start: 1},
  ]
  const follower = new PlaybackFollower(timed, index => changes.push(index), time.options)

  follower.report({playing: true, rate: 1, time: 1.2})
  assert.deepEqual(changes, [1])

  // Woken when the last word ends, not left on it.
  time.advance(201)
  assert.deepEqual(changes, [1, 2])
  assert.equal(time.pending, 0)

  // A seek back makes it current again.
  follower.report({time: 1.1})
  assert.deepEqual(changes, [1, 2, 1])

  // A player stopped at its end reports a time past the last word.
  follower.report({playing: false, time: 3})
  assert.deepEqual(changes, [1, 2, 1, 2])
})
