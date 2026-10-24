import {Platform, Settings} from 'react-native'

/**
 * How the captures drive the app on iOS: launch arguments, which land in NSUserDefaults
 * (`xcrun simctl launch <device> <bundle id> -capturePlay 1 -captureRoute /styles`). The iOS 27 simulator takes no
 * scripted taps, and a link from outside asks before it opens. Android takes the `?play=` link and taps.
 */
export const capture: {play?: string; route?: string} =
  Platform.OS === 'ios'
    ? {
        play: Settings.get('capturePlay') as string | undefined,
        route: Settings.get('captureRoute') as string | undefined,
      }
    : {}
