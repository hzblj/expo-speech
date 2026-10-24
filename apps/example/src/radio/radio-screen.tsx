import {FlagView} from '@hzblj/expo-flags-kit'
import {Box, Chip, EmptyState, Island, RnFlatList, RnText} from '@hzblj/kara-ui'
import {setAudioModeAsync, useAudioPlayer} from 'expo-audio'
import {useCallback, useEffect, useRef, useState} from 'react'

import {DRIVERS, flagCode, MEETING, type RadioClip, SESSIONS} from '../f1/radio'
import {useRadioTranscriber} from '../speech'
import {Caption} from '../ui/karaoke'
import {RadioCard} from './radio-card'

/** The weekend, and a chip for each of its sessions. */
const Header = ({onSelect, selected}: {selected: number | null; onSelect: (sessionKey: number) => void}) => {
  const flag = flagCode(MEETING.country_code)

  return (
    <Box gap="s16" pb="s8">
      <Box align="center" gap="s12" row>
        {flag ? <FlagView code={flag as never} style={{borderRadius: 4, height: 24, width: 36}} /> : null}
        <Box fill gap="s2">
          <RnText style={{fontWeight: '700'}} variant="headingXs">
            {MEETING.meeting_name}
          </RnText>
          <Caption>{`${MEETING.circuit_short_name} · ${MEETING.year}`}</Caption>
        </Box>
      </Box>
      <Box gap="s8" row wrap>
        {SESSIONS.map(session => (
          <Chip
            key={session.key}
            label={session.name}
            onPress={() => onSelect(session.key)}
            selected={session.key === selected}
          />
        ))}
      </Box>
    </Box>
  )
}

/**
 * A weekend's team radio, newest first, a session at a time, each message transcribed on the device as it comes on screen:
 * cached by URL, so scrolling back or reopening the app costs nothing. Tap one to hear it with its words lit.
 */
export const RadioScreen = () => {
  const [selected, setSelected] = useState<number | null>(SESSIONS[0]?.key ?? null)
  const clips = SESSIONS.find(session => session.key === selected)?.clips ?? []
  const transcriber = useRadioTranscriber(DRIVERS)
  const player = useAudioPlayer(null, {updateInterval: 100})
  const [playing, setPlaying] = useState<string | null>(null)
  // Read by the callback, so it stays the same and only the cards whose state changes re-render.
  const playingRef = useRef(playing)
  playingRef.current = playing

  useEffect(() => {
    setAudioModeAsync({playsInSilentMode: true})
  }, [])

  // A message that played to its end lets go: its card is at rest again, and a tap plays it from the start.
  useEffect(() => {
    const subscription = player.addListener('playbackStatusUpdate', status => {
      if (status.didJustFinish) {
        setPlaying(null)
      }
    })
    return () => subscription.remove()
  }, [player])

  const onPlay = useCallback(
    (clip: RadioClip, audioUri: string) => {
      if (playingRef.current !== clip.id) {
        player.replace({uri: audioUri})
        player.play()
        setPlaying(clip.id)
      } else if (player.playing) {
        player.pause()
      } else {
        if (player.duration > 0 && player.currentTime >= player.duration - 0.1) {
          player.seekTo(0)
        }
        player.play()
      }
    },
    [player]
  )

  return (
    <RnFlatList
      ListEmptyComponent={
        <Island>
          <EmptyState description="No team radio in this session." icon="radio" title="Radio silence" />
        </Island>
      }
      ListHeaderComponent={<Header onSelect={setSelected} selected={selected} />}
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
