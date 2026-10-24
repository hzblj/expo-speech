import {Image} from 'react-native'

import type {SpeechSource} from './types'

/**
 * A source as a URI and its headers. A `require()`d asset resolves to the packager's URL in development and to the
 * bundled file in a release build; the native side downloads the first and reads the second.
 */
export const resolveSource = (source: SpeechSource): {uri: string; headers: Record<string, string>} => {
  if (typeof source === 'number') {
    const asset = Image.resolveAssetSource(source)

    if (!asset?.uri) {
      throw new Error(`expo-speech: the asset ${source} has no URI`)
    }

    return {headers: {}, uri: asset.uri}
  }

  if (typeof source === 'string') {
    return {headers: {}, uri: source}
  }

  return {headers: source.headers ?? {}, uri: source.uri}
}
