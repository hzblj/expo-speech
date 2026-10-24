import {
  Speech,
  type SpeechTranscriberOptions,
  type Transcription,
  useSpeechTranscriber,
  useTranscription,
  useTranscriptPlayback,
} from '@hzblj/expo-speech'
import {Box, Pressable, RnIcon, RnScrollView, RnText, useAppTheme} from '@hzblj/kara-ui'
import {setAudioModeAsync, useAudioPlayer, useAudioPlayerStatus} from 'expo-audio'
import {useState} from 'react'
import {Pressable as HoldPressable} from 'react-native'

import {Caption, formatDuration, Karaoke, WordTrack} from '../ui/karaoke'

const OPTIONS: SpeechTranscriberOptions = {detectSpeech: true, locale: 'en-GB', mode: 'dictation'}

/** How loud the microphone is, from 0 to 1: -50 dBFS and below is silence. */
const loudness = (level: number | null) => (level == null ? 0 : Math.min(1, Math.max(0, (level + 50) / 50)))

/**
 * The pit wall's side of the radio: hold the button and talk. The words come as they are heard, the audio is
 * recorded, and once you let go the message plays back with its words lit.
 */
export const LiveScreen = () => {
  const theme = useAppTheme()
  const transcriber = useSpeechTranscriber(OPTIONS)
  const [transcription, setTranscription] = useState<Transcription | null>(null)
  const [refusal, setRefusal] = useState<string | null>(null)
  const {error, level, speaking, state, transcript} = useTranscription(transcription)
  const player = useAudioPlayer(null, {updateInterval: 100})
  const status = useAudioPlayerStatus(player)
  const {getTime, wordIndex} = useTranscriptPlayback(state === 'completed' ? transcript : null, player)
  const listening = state === 'transcribing' || state === 'preparing' || state === 'queued'
  const recorded = state === 'completed' && transcript.audioUri

  const start = async () => {
    setRefusal(null)
    const permission = await Speech.requestPermissionsAsync()

    if (!permission.granted) {
      setRefusal('The microphone is not allowed. Turn it on in Settings to talk to the car.')
      return
    }
    player.pause()
    try {
      setTranscription(transcriber.listen({record: true, volumeInterval: 60}))
    } catch (caught) {
      setRefusal((caught as Error).message)
    }
  }

  const stop = () => {
    transcription?.stop()
  }

  const play = async () => {
    if (!transcript.audioUri) {
      return
    }
    await setAudioModeAsync({playsInSilentMode: true})
    if (status.playing) {
      player.pause()
      return
    }
    if (status.isLoaded && status.currentTime < (status.duration || 0) - 0.1) {
      player.play()
      return
    }
    player.replace({uri: transcript.audioUri})
    player.play()
  }

  const ring = 1 + loudness(level) * 0.6

  return (
    <RnScrollView
      bg="surface.base"
      content={{gap: 's24', pb: 's96', pt: 's8', px: 's20'}}
      contentInsetAdjustmentBehavior="automatic"
      flex={1}
      testID="live"
    >
      <Box align="center" gap="s16" pt="s24">
        <Box center size={168}>
          <Box
            borderRadius="full"
            position="absolute"
            size={120}
            style={{
              backgroundColor: theme.color('fill.accent.primary'),
              opacity: listening ? 0.25 : 0,
              transform: [{scale: ring}],
            }}
          />
          {/* React Native's own Pressable: holding needs press in and press out, which kara's does not expose. */}
          <HoldPressable
            accessibilityHint="Hold to talk, let go to send"
            accessibilityLabel={listening ? 'Listening' : 'Push to talk'}
            accessibilityRole="button"
            onPressIn={start}
            onPressOut={stop}
            testID="push-to-talk"
          >
            <Box bg={listening ? 'fill.accent.primary' : 'surface.primary'} borderRadius="full" center size={120}>
              <RnIcon color={listening ? 'content.on.accent' : 'content.accent'} name="mic-filled" size="s48" />
            </Box>
          </HoldPressable>
        </Box>
        <Caption color={listening ? 'content.accent' : 'content.secondary'}>
          {listening ? (speaking ? 'Speech' : 'Listening') : 'Hold to talk'}
        </Caption>
      </Box>

      <Box bg="surface.primary" borderRadius="large" gap="s12" p="s16" style={{minHeight: 160}}>
        <Caption>{recorded ? `Your message · ${formatDuration(transcript.duration)}` : 'Live'}</Caption>
        {transcript.text ? (
          <Karaoke
            onWordPress={word => player.seekTo(word.start)}
            playing={status.playing}
            transcript={transcript}
            variant="headline"
            wordIndex={wordIndex}
          />
        ) : (
          <RnText color="content.tertiary" variant="headline">
            {listening ? 'Go ahead.' : 'Box this lap, box box.'}
          </RnText>
        )}
        {recorded ? (
          <Box gap="s12">
            <WordTrack
              duration={status.duration || transcript.duration || 0}
              time={getTime()}
              words={transcript.words}
            />
            <Pressable
              accessibilityLabel={status.playing ? 'Pause' : 'Play the message'}
              align="center"
              alignSelf="flex-start"
              bg="fill.accent.base"
              borderRadius="full"
              gap="s8"
              onPress={play}
              px="s16"
              py="s8"
              row
            >
              <RnIcon color="content.accent" name={status.playing ? 'pause' : 'play-arrow'} size="s20" />
              <RnText color="content.accent" variant="subheadlineMedium">
                {status.playing ? 'Pause' : 'Play back'}
              </RnText>
            </Pressable>
          </Box>
        ) : null}
      </Box>

      {refusal || error ? (
        <RnText color="content.destructive" variant="footnote">
          {refusal ?? `${error?.code}: ${error?.message}`}
        </RnText>
      ) : null}

      <RnText color="content.tertiary" variant="footnote">
        Dictation mode, British English, with speech detection. The audio is recorded as a 16 kHz WAV file next to the
        transcript, so the message plays back with every word in time.
      </RnText>
    </RnScrollView>
  )
}
