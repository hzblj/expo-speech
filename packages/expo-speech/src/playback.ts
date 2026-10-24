import {indexAt} from './transcript'

/**
 * Anything that plays audio and says where it is: expo-audio's `AudioPlayer` and expo-video's `VideoPlayer` both are.
 * Events it does not have are never heard, so either works.
 */
export type PlaybackSource = {
  currentTime: number
  playing: boolean
  playbackRate?: number
  addListener(eventName: never, listener: (event: never) => void): {remove(): void}
}

type Listenable = {addListener(eventName: string, listener: (event: Record<string, unknown>) => void): {remove(): void}}

type Clock = {time: number; at: number; playing: boolean; rate: number}

export type PlaybackFollowerOptions = {
  /** Seconds added to the player's time before looking the word up, for audio that starts later than the transcript. */
  offset?: number
  now?: () => number
  setTimeout?: (callback: () => void, milliseconds: number) => unknown
  clearTimeout?: (handle: unknown) => void
}

/**
 * Follows a player through a list of timed items (words or segments) and calls back when the current one changes.
 *
 * Players report their time a few times a second (expo-audio every 500 ms by default), too seldom for words. The
 * follower takes the last report, its moment and the playback rate, and wakes itself exactly when the next item starts,
 * so the highlight moves on time without polling. Every new report sets the clock right again.
 */
export class PlaybackFollower {
  private clock: Clock = {at: 0, playing: false, rate: 1, time: 0}
  private index = -1
  private timer: unknown = null
  private readonly now: () => number
  private readonly schedule: (callback: () => void, milliseconds: number) => unknown
  private readonly cancel: (handle: unknown) => void

  constructor(
    private starts: readonly {start: number}[],
    private readonly onChange: (index: number, time: number) => void,
    private readonly options: PlaybackFollowerOptions = {}
  ) {
    this.now = options.now ?? (() => performance.now())
    this.schedule = options.setTimeout ?? ((callback, milliseconds) => setTimeout(callback, milliseconds))
    this.cancel = options.clearTimeout ?? (handle => clearTimeout(handle as ReturnType<typeof setTimeout>))
  }

  /** The player's time now, as the follower reckons it. */
  get time() {
    const {at, playing, rate, time} = this.clock

    return playing ? time + ((this.now() - at) / 1000) * rate : time
  }

  get currentIndex() {
    return this.index
  }

  /** A report from the player. Any field left out keeps its last value. */
  report(update: {time?: number; playing?: boolean; rate?: number}) {
    const time = update.time ?? this.time

    this.clock = {
      at: this.now(),
      playing: update.playing ?? this.clock.playing,
      rate: update.rate ?? this.clock.rate,
      time,
    }
    this.tick()
  }

  /** New items, for a transcript that grew while it plays. */
  setItems(starts: readonly {start: number}[]) {
    this.starts = starts
    this.tick()
  }

  dispose() {
    if (this.timer !== null) {
      this.cancel(this.timer)
      this.timer = null
    }
  }

  private tick = () => {
    this.dispose()

    const time = this.time + (this.options.offset ?? 0)
    const index = indexAt(this.starts, time)

    if (index !== this.index) {
      this.index = index
      this.onChange(index, time)
    }

    const next = this.starts[index + 1]

    if (this.clock.playing && this.clock.rate > 0 && next) {
      // A millisecond late rather than early, so the wake-up lands on the next item.
      this.timer = this.schedule(this.tick, Math.max(0, ((next.start - time) / this.clock.rate) * 1000 + 1))
    }
  }
}

const number = (value: unknown) => (typeof value === 'number' && Number.isFinite(value) ? value : undefined)
const boolean = (value: unknown) => (typeof value === 'boolean' ? value : undefined)

/**
 * Feeds a follower from a player's events: expo-audio's `playbackStatusUpdate`, expo-video's `timeUpdate`,
 * `playingChange` and `playbackRateChange`. Returns the unsubscribe.
 */
export const followPlayer = (player: PlaybackSource, follower: PlaybackFollower) => {
  const source = player as unknown as Listenable

  follower.report({playing: player.playing, rate: player.playbackRate ?? 1, time: player.currentTime})

  const subscriptions = [
    source.addListener('playbackStatusUpdate', status =>
      follower.report({
        playing: boolean(status.playing),
        rate: number(status.playbackRate),
        time: number(status.currentTime),
      })
    ),
    source.addListener('timeUpdate', event => follower.report({time: number(event.currentTime)})),
    source.addListener('playingChange', event =>
      follower.report({playing: boolean(event.isPlaying), time: player.currentTime})
    ),
    source.addListener('playbackRateChange', event => follower.report({rate: number(event.playbackRate)})),
  ]

  return () => {
    for (const subscription of subscriptions) {
      subscription.remove()
    }
  }
}
