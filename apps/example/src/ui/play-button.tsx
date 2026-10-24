import {Box, Pressable, RnIcon} from '@hzblj/kara-ui'
import type {ColorValue} from 'react-native'

type PlayButtonProps = {
  /** The fill: the team's colour on the radio. */
  color: ColorValue
  playing: boolean
  onPress: () => void
  /** What VoiceOver and TalkBack say for it. */
  label: string
  size?: number
}

/** A round play or pause button. */
export const PlayButton = ({color, label, onPress, playing, size = 40}: PlayButtonProps) => (
  <Pressable accessibilityLabel={label} accessibilityRole="button" borderRadius="full" onPress={onPress}>
    <Box borderRadius="full" center size={size} style={{backgroundColor: color}}>
      <RnIcon color="content.on.accent" name={playing ? 'pause' : 'play-arrow'} size="s20" />
    </Box>
  </Pressable>
)
