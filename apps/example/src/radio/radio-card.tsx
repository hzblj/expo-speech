import {type SpeechTranscriber, useTranscribe, useTranscriptPlayback} from '@hzblj/expo-speech'
import {Box, Image, Pressable, RnIcon, RnText, Skeleton} from '@hzblj/kara-ui'
import {type AudioPlayer, useAudioPlayerStatus} from 'expo-audio'
import {memo} from 'react'

import {type RadioClip, teamColor} from '../f1/radio'
import {Caption, formatDuration, Karaoke, WordTrack} from '../ui/karaoke'

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
  /** The screen's one player; this card plays it when it is the active one. */
  player: AudioPlayer
  active: boolean
  onPlay: (clip: RadioClip, audioUri: string) => void
}

/** The playing card's live parts: the lit words (once there are any) and the track, which re-render with the player. */
const NowPlaying = ({
  player,
  transcript,
}: {
  player: AudioPlayer
  transcript: ReturnType<typeof useTranscribe>['transcript']
}) => {
  const status = useAudioPlayerStatus(player)
  const {getTime, wordIndex} = useTranscriptPlayback(transcript, player)

  return (
    <Box gap="s12">
      {transcript.text ? (
        <Karaoke playing={status.playing} transcript={transcript} variant="headline" wordIndex={wordIndex} />
      ) : null}
      <WordTrack duration={status.duration || transcript.duration || 0} time={getTime()} words={transcript.words} />
    </Box>
  )
}

/** Play or pause as the player is, and the time: where it is while it plays, its length otherwise. */
const PlayState = ({duration, player}: {duration: number; player: AudioPlayer | null}) =>
  player ? <PlayingState player={player} /> : <IdleState duration={duration} />

const IdleState = ({duration}: {duration: number}) => (
  <Box align="flex-end" gap="s4">
    <RnIcon color="content.secondary" name="play-arrow" />
    <RnText color="content.tertiary" style={{fontVariant: ['tabular-nums']}} variant="caption">
      {formatDuration(duration)}
    </RnText>
  </Box>
)

const PlayingState = ({player}: {player: AudioPlayer}) => {
  const status = useAudioPlayerStatus(player)

  return (
    <Box align="flex-end" gap="s4">
      <RnIcon color="content.accent" name={status.playing ? 'pause' : 'play-arrow'} />
      <RnText color="content.accent" style={{fontVariant: ['tabular-nums']}} variant="caption">
        {formatDuration(status.currentTime)}
      </RnText>
    </Box>
  )
}

/**
 * A team radio message: the driver in their team's colour, when it was sent and how long it is, and its transcript,
 * transcribed as the card comes on screen. The one playing lights its words as they are said.
 */
export const RadioCard = memo(({active, clip, onPlay, player, transcriber}: RadioCardProps) => {
  const {error, progress, progressPhase, state, transcript, transcription} = useTranscribe(transcriber, clip.url, {
    cacheKey: clip.url,
  })
  const driver = clip.driver
  const color = teamColor(driver)
  const settled = state === 'completed' || state === 'failed' || state === 'cancelled'
  const audioUri = transcript.audioUri ?? clip.url

  return (
    <Pressable
      accessibilityLabel={`${active ? 'Play or pause' : 'Play'} ${driver?.full_name ?? 'radio'} at ${time(clip.date)}`}
      accessibilityRole="button"
      bg={active ? 'surface.secondary' : 'surface.primary'}
      borderRadius="large"
      onPress={() => onPlay(clip, audioUri)}
      overflow="hidden"
      row
    >
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
              <RnText style={{color, fontVariant: ['tabular-nums'], fontWeight: '700'}} variant="headline">
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
          <PlayState duration={transcript.duration ?? 0} player={active ? player : null} />
        </Box>

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
        ) : transcript.text ? (
          active ? null : (
            <Karaoke transcript={transcript} />
          )
        ) : (
          <Box gap="s6">
            <Skeleton h={14} />
            <Skeleton h={14} w="60%" />
            {progressPhase ? (
              <Caption color="content.tertiary">
                {progressPhase === 'downloading'
                  ? `Downloading ${Math.round(progress * 100)} %`
                  : progressPhase === 'installing'
                    ? `Installing the English model ${Math.round(progress * 100)} %`
                    : 'Transcribing'}
              </Caption>
            ) : null}
          </Box>
        )}

        {active ? <NowPlaying player={player} transcript={transcript} /> : null}

        {transcription?.fromCache || (state === 'completed' && transcript.words.length > 0) ? (
          <Caption color="content.tertiary">
            {`${transcript.words.length} words${transcription?.fromCache ? ' · from cache' : ''}`}
          </Caption>
        ) : null}
      </Box>
    </Pressable>
  )
})
