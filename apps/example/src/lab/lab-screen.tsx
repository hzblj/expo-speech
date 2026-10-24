import {
  type SpeechTranscriberOptions,
  type Transcription,
  TranscriptText,
  type TranscriptWord,
  toSRT,
  toWebVTT,
  useSpeechTranscriber,
  useTranscription,
} from '@hzblj/expo-speech'
import {
  Box,
  Button,
  Island,
  Picker,
  RnScrollView,
  RnText,
  SearchBar,
  SegmentedControl,
  Switch,
  useAppTheme,
  VStack,
} from '@hzblj/kara-ui'
import {useMemo, useState} from 'react'
import {Platform, Share} from 'react-native'

import {DRIVERS, FIRST_CLIP, SESSIONS} from '../f1/radio'
import {Caption} from '../ui/karaoke'
import {Section} from '../ui/page'

const MODES = ['transcription', 'dictation'] as const

/** Every message of the weekend, by session. */
const CLIPS = SESSIONS.flatMap(session => session.clips)

const OPTIONS = SESSIONS.flatMap(session =>
  session.clips.map(clip => ({
    label: `${session.name} · ${clip.driver?.name_acronym ?? '???'} · ${clip.date.toLocaleTimeString('en-GB')}`,
    value: clip.id,
  }))
)

const seconds = (value: number) => `${value.toFixed(2)} s`

/**
 * Every option against one radio message: transcribed fresh (no cache), with its segments, their confidence and
 * alternatives, every word's time, and the transcript as subtitles.
 */
export const LabScreen = () => {
  const [clipId, setClipId] = useState<string | null>(null)
  const [customUrl, setCustomUrl] = useState('')
  const clip = CLIPS.find(candidate => candidate.id === clipId) ?? FIRST_CLIP
  const source = customUrl.trim() || clip?.url

  const [mode, setMode] = useState(0)
  const [onDevice, setOnDevice] = useState(true)
  const [punctuation, setPunctuation] = useState(true)
  const [alternatives, setAlternatives] = useState(true)
  const [names, setNames] = useState(true)
  const [detectSpeech, setDetectSpeech] = useState(true)

  const options = useMemo<SpeechTranscriberOptions>(
    () => ({
      alternatives,
      contextualStrings: names ? DRIVERS.map(driver => driver.last_name) : [],
      detectSpeech,
      locale: 'en-GB',
      mode: MODES[mode],
      onDevice,
      punctuation,
    }),
    [alternatives, names, detectSpeech, mode, onDevice, punctuation]
  )
  const transcriber = useSpeechTranscriber(options)
  const [transcription, setTranscription] = useState<Transcription | null>(null)
  const [pressed, setPressed] = useState<TranscriptWord | null>(null)
  const theme = useAppTheme()
  const {error, progress, progressPhase, state, transcript} = useTranscription(transcription)
  const running = state !== null && !['completed', 'failed', 'cancelled'].includes(state)

  return (
    <RnScrollView
      bg="surface.base"
      content={{gap: 's32', pb: 's96', pt: 's8', px: 's20'}}
      contentInsetAdjustmentBehavior="automatic"
      flex={1}
      testID="lab"
    >
      <Section caption="A message of the weekend, or any audio or video file by its URL." title="Message">
        <Picker onValueChange={setClipId} options={OPTIONS} value={clip?.id ?? ''} />
        <SearchBar
          onChangeText={setCustomUrl}
          placeholder="https://…/radio.mp3"
          testID="custom-url"
          value={customUrl}
        />
      </Section>

      <Section
        caption="Transcription is SpeechTranscriber on iOS 26, dictation is DictationTranscriber; on Android both are the platform recognizer with formatting tuned for quality or for latency."
        title="Mode"
      >
        <SegmentedControl onChange={setMode} selectedIndex={mode} values={['Transcription', 'Dictation']} />
      </Section>

      <Section
        caption={
          Platform.OS === 'ios'
            ? 'iOS 26 always runs on the device. Driver names count in dictation mode.'
            : 'Off, the default recognizer may send the audio to its service.'
        }
        title="Options"
      >
        <Island>
          <VStack bg="surface.primary" borderRadius="large" p="s16" spacing="s12" wide>
            <Switch label="On the device" onValueChange={setOnDevice} value={onDevice} />
            <Switch label="Punctuation" onValueChange={setPunctuation} value={punctuation} />
            <Switch label="Alternatives" onValueChange={setAlternatives} value={alternatives} />
            <Switch label="Driver names as contextual strings" onValueChange={setNames} value={names} />
            <Switch label="Detect speech" onValueChange={setDetectSpeech} value={detectSpeech} />
          </VStack>
        </Island>
      </Section>

      <Island>
        <VStack spacing="s8" wide>
          <Button
            disabled={!source || running}
            label={running ? 'Transcribing…' : 'Transcribe'}
            onPress={() => source && setTranscription(transcriber.transcribe(source))}
          />
        </VStack>
      </Island>

      {state ? (
        <Section
          title={`Result · ${state}${progressPhase && running ? ` · ${progressPhase} ${Math.round(progress * 100)} %` : ''}`}
        >
          {error ? (
            <RnText color="content.destructive" variant="footnote">
              {`${error.code}: ${error.message}`}
            </RnText>
          ) : null}
          <Box bg="surface.primary" borderRadius="large" p="s16">
            {transcript.text ? (
              <Box gap="s8">
                <TranscriptText
                  onWordPress={word => setPressed(word)}
                  style={{fontSize: 17, lineHeight: 24}}
                  transcript={transcript}
                  upcomingWordStyle={{color: theme.color('content.primary')}}
                />
                <Caption color="content.tertiary">
                  {pressed
                    ? `${pressed.text} · ${seconds(pressed.start)} to ${seconds(pressed.end)}`
                    : 'Tap a word for its time'}
                </Caption>
              </Box>
            ) : (
              <RnText color="content.tertiary">No words yet.</RnText>
            )}
          </Box>
        </Section>
      ) : null}

      {transcript.segments.length ? (
        <Section
          caption="A segment is one result of the recognizer. Volatile ones are still being revised."
          title="Segments"
        >
          {transcript.segments.map(segment => (
            <Box bg="surface.primary" borderRadius="large" gap="s8" key={segment.range[0]} p="s16">
              <Caption color={segment.isFinal ? 'content.secondary' : 'content.accent'}>
                {`${seconds(segment.start)} to ${seconds(segment.end)} · ${
                  segment.confidence == null ? 'no confidence' : `${Math.round(segment.confidence * 100)} % sure`
                }${segment.isFinal ? '' : ' · volatile'}`}
              </Caption>
              <RnText variant="body">{segment.text.trim()}</RnText>
              {segment.alternatives.length ? (
                <RnText color="content.tertiary" variant="footnote">
                  {`Or: ${segment.alternatives.map(text => `“${text.trim()}”`).join(', ')}`}
                </RnText>
              ) : null}
              <Box gap="s6" row wrap>
                {segment.words.map(word => (
                  <Box bg="surface.secondary" borderRadius="small" key={word.range[0]} px="s6" py="s2">
                    <RnText monospacedDigit variant="caption">
                      {`${word.text} ${word.start.toFixed(2)}${word.timing === 'estimated' ? '~' : ''}`}
                    </RnText>
                  </Box>
                ))}
              </Box>
            </Box>
          ))}
          <RnText color="content.tertiary" variant="footnote">
            A tilde marks a time the platform did not give and the word got its share of a longer stretch.
          </RnText>
        </Section>
      ) : null}

      {state === 'completed' && transcript.words.length ? (
        <Island>
          <VStack spacing="s8" wide>
            <Button
              label="Share as WebVTT"
              onPress={() => Share.share({message: toWebVTT(transcript)})}
              variant="secondary"
            />
            <Button
              label="Share as SRT"
              onPress={() => Share.share({message: toSRT(transcript)})}
              variant="secondary"
            />
          </VStack>
        </Island>
      ) : null}
    </RnScrollView>
  )
}
