import {FlagView} from '@hzblj/expo-flags-kit'
import {Box, Chip, EmptyState, Island, RnFlatList, RnText, Skeleton} from '@hzblj/kara-ui'
import {setAudioModeAsync, useAudioPlayer} from 'expo-audio'
import {useCallback, useEffect, useState} from 'react'

import {flagCode} from '../f1/openf1'
import {type RadioClip, useLatestWeekend, useRadioClips} from '../f1/radio-clips'
import {useRadioTranscriber} from '../speech'
import {Caption} from '../ui/karaoke'
import {RadioCard} from './radio-card'

const Header = ({
  onSelect,
  selected,
  weekend,
}: {
  weekend: ReturnType<typeof useLatestWeekend>
  selected: number | null
  onSelect: (sessionKey: number) => void
}) => {
  const {meeting, sessions} = weekend
  const flag = meeting ? flagCode(meeting.country_code) : null

  return (
    <Box gap="s16" pb="s8">
      {meeting ? (
        <Box align="center" gap="s12" row>
          {flag ? <FlagView code={flag as never} style={{borderRadius: 4, height: 24, width: 36}} /> : null}
          <Box fill gap="s2">
            <RnText style={{fontWeight: '700'}} variant="headingXs">
              {meeting.meeting_name}
            </RnText>
            <Caption>{`${meeting.circuit_short_name} · ${meeting.year}`}</Caption>
          </Box>
        </Box>
      ) : (
        <Skeleton h={44} />
      )}
      <Box gap="s8" row wrap>
        {sessions.map(session => (
          <Chip
            key={session.session_key}
            label={session.session_name}
            onPress={() => onSelect(session.session_key)}
            selected={session.session_key === selected}
          />
        ))}
      </Box>
    </Box>
  )
}

/**
 * The latest weekend's team radio, newest first, each message transcribed on the device as it comes on screen:
 * cached by URL, so scrolling back or reopening the app costs nothing. Tap one to hear it with its words lit.
 */
export const RadioScreen = () => {
  const weekend = useLatestWeekend()
  const [sessionKey, setSessionKey] = useState<number | null>(null)
  const selected = sessionKey ?? weekend.sessions[0]?.session_key ?? null
  const {clips, drivers, error, loading} = useRadioClips(selected)
  const transcriber = useRadioTranscriber(drivers)
  const player = useAudioPlayer(null, {updateInterval: 100})
  const [playing, setPlaying] = useState<string | null>(null)

  useEffect(() => {
    setAudioModeAsync({playsInSilentMode: true})
  }, [])

  const onPlay = useCallback(
    (clip: RadioClip, audioUri: string) => {
      if (playing === clip.id) {
        if (player.playing) {
          player.pause()
        } else {
          player.play()
        }
        return
      }
      player.replace({uri: audioUri})
      player.play()
      setPlaying(clip.id)
    },
    [player, playing]
  )

  return (
    <RnFlatList
      ListEmptyComponent={
        loading ? null : (
          <Island>
            <EmptyState
              description={error ? error.message : 'No team radio in this session yet.'}
              icon="radio"
              title={error ? 'OpenF1 is not answering' : 'Radio silence'}
            />
          </Island>
        )
      }
      ListHeaderComponent={<Header onSelect={setSessionKey} selected={selected} weekend={weekend} />}
      bg="surface.base"
      content={{gap: 's12', pb: 's96', pt: 's8', px: 's16'}}
      contentInsetAdjustmentBehavior="automatic"
      data={transcriber ? clips : []}
      flex={1}
      keyExtractor={clip => clip.id}
      renderItem={({item}) => (
        <RadioCard active={item.id === playing} clip={item} onPlay={onPlay} player={player} transcriber={transcriber} />
      )}
      testID="radio"
    />
  )
}
