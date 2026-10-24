import {type SpeechTranscriber, useTranscribe, useTranscriptPlayback, wordIndexAt} from '@hzblj/expo-speech'
import {useWaveformPlayback, WaveformView} from '@hzblj/expo-waveform'
import {Box, Image, RnIcon, RnText, useAppTheme} from '@hzblj/kara-ui'
import {type AudioPlayer, useAudioPlayerStatus} from 'expo-audio'
import {memo, useMemo, useState} from 'react'

import {type RadioClip, teamColor} from '../f1/radio'
import {Caption, formatDuration, Karaoke} from '../ui/karaoke'
import {PlayButton} from '../ui/play-button'
import {Reveal} from '../ui/reveal'

const time = (date: Date) =>
  date.toLocaleTimeString('en-GB', {hour: '2-digit', hour12: false, minute: '2-digit', second: '2-digit'})

/**
 * Failures that say more about the device than the message, said in a line: an iOS simulator often cannot download
 * Apple's speech models, where a phone can.
 */
const QUIET_FAILURES: Partial<Record<string, string>> = {
  'locale-unavailable':
    "No English speech model on this device, so no words. A phone downloads it; a simulator often can't.",
  unsupported: 'Speech recognition is unsupported in this simulator: transcribe on a device.',
}

type RadioCardProps = {
  clip: RadioClip
  transcriber: SpeechTranscriber
  /** The screen's one player; this card follows it while it is the active one. */
  player: AudioPlayer
  active: boolean
  onPlay: (clip: RadioClip) => void
  onSeek: (clip: RadioClip, time: number) => void
}

/** The time under the playhead while the card plays, its length otherwise. */
const Elapsed = ({duration, player}: {duration: number; player: AudioPlayer | null}) =>
  player ? <PlayingElapsed player={player} /> : <ElapsedText seconds={duration} />

const PlayingElapsed = ({player}: {player: AudioPlayer}) => (
  <ElapsedText seconds={useAudioPlayerStatus(player).currentTime} />
)

const ElapsedText = ({seconds}: {seconds: number}) => (
  <RnText color="content.tertiary" monospacedDigit style={{minWidth: 34}} variant="caption">
    {formatDuration(seconds)}
  </RnText>
)

/**
 * A team radio message: the driver in their team's colour, the recording as a waveform (`@hzblj/expo-waveform`) with a
 * tick where every word starts, and its transcript, transcribed on the device as the card comes on screen. The one
 * playing lights its words as they are said; dragging the waveform lights the word under the finger.
 */
export const RadioCard = memo(({active, clip, onPlay, onSeek, player, transcriber}: RadioCardProps) => {
  const theme = useAppTheme()
  const {error, fromCache, progress, progressPhase, state, transcript} = useTranscribe(transcriber, clip.url, {
    cacheKey: clip.url,
  })
  const playback = useWaveformPlayback(active ? player : null)
  const {wordIndex} = useTranscriptPlayback(transcript, active ? player : null)
  const driver = clip.driver
  const color = teamColor(driver)
  const markers = useMemo(() => transcript.words.map(word => word.start), [transcript.words])
  const playing = playback?.playing ?? false
  const settled = state === 'completed' || state === 'failed' || state === 'cancelled'
  // The length from the waveform's own analysis, there before the player knows it.
  const [duration, setDuration] = useState(0)
  // Where the finger is while it scrubs: the words and the time follow it before the player does.
  const [scrub, setScrub] = useState<number | null>(null)
  const litWord = scrub === null ? (active ? wordIndex : -1) : wordIndexAt(transcript, scrub)

  return (
    <Box bg={active ? 'surface.secondary' : 'surface.primary'} borderRadius="large" overflow="hidden" row>
      <Box style={{backgroundColor: color, width: 4}} />
      <Box fill gap="s12" p="s16">
        <Box align="center" gap="s12" row>
          {driver?.headshot_url ? (
            <Image
              accessibilityIgnoresInvertColors
              bg="surface.secondary"
              borderRadius="full"
              contentFit="cover"
              size={40}
              source={{uri: driver.headshot_url}}
            />
          ) : (
            <Box bg="surface.secondary" borderRadius="full" center size={40}>
              <RnIcon color="content.secondary" name="sports-motorsports" size="s20" />
            </Box>
          )}
          <Box fill gap="s2">
            <Box align="baseline" gap="s8" row>
              <RnText monospacedDigit style={{color, fontWeight: '700'}} variant="headline">
                {driver ? String(driver.driver_number) : '?'}
              </RnText>
              <RnText style={{fontWeight: '700', letterSpacing: 1}} variant="headline">
                {driver?.name_acronym ?? 'RADIO'}
              </RnText>
              <RnText color="content.secondary" numberOfLines={1} shrink variant="subheadline">
                {driver ? `${driver.first_name} ${driver.last_name}` : ''}
              </RnText>
            </Box>
            <Caption>{`${driver?.team_name ?? 'Team radio'} · ${time(clip.date)}`}</Caption>
          </Box>
        </Box>

        <Box align="center" gap="s12" row>
          <PlayButton
            color={color}
            label={`${playing ? 'Pause' : 'Play'} ${driver?.full_name ?? 'the radio'} at ${time(clip.date)}`}
            onPress={() => onPlay(clip)}
            playing={playing}
          />
          <WaveformView
            accessibilityLabel={`${driver?.name_acronym ?? 'Team'} radio`}
            color={theme.color('content.tertiary')}
            markers={markers}
            onLoad={event => setDuration(event.duration)}
            onScrub={setScrub}
            onScrubEnd={() => setScrub(null)}
            onScrubStart={setScrub}
            onSeek={seconds => onSeek(clip, seconds)}
            playback={playback}
            progress={0}
            progressColor={color}
            source={clip.url}
            style={{flex: 1, height: 40}}
            testID={`waveform-${clip.id}`}
          />
          {scrub === null ? (
            <Elapsed duration={duration} player={active ? player : null} />
          ) : (
            <ElapsedText seconds={scrub} />
          )}
        </Box>

        <Reveal
          pending={
            progressPhase ? (
              <Caption color="content.tertiary">
                {progressPhase === 'downloading'
                  ? `Downloading ${Math.round(progress * 100)} %`
                  : progressPhase === 'installing'
                    ? `Installing the English model ${Math.round(progress * 100)} %`
                    : 'Transcribing'}
              </Caption>
            ) : null
          }
          ready={settled || Boolean(transcript.text)}
        >
          {state === 'failed' ? (
            <RnText
              color={error && error.code in QUIET_FAILURES ? 'content.tertiary' : 'content.destructive'}
              variant="footnote"
            >
              {(error && QUIET_FAILURES[error.code]) ?? error?.message ?? 'The transcription failed'}
            </RnText>
          ) : settled && transcript.text.trim() === '' ? (
            <RnText color="content.tertiary" variant="body">
              Only engine noise on this one.
            </RnText>
          ) : (
            <Karaoke playing={active || scrub !== null} transcript={transcript} wordIndex={litWord} />
          )}
        </Reveal>

        {state === 'completed' && transcript.words.length > 0 ? (
          <Caption color="content.tertiary">
            {`${transcript.words.length} words${fromCache ? ' · from cache' : ''}`}
          </Caption>
        ) : null}
      </Box>
    </Box>
  )
})
