import {type SpeechTranscriberOptions, useSpeechTranscriber} from '@hzblj/expo-speech'
import {useMemo} from 'react'

import type {Driver} from './f1/openf1'

/** Pit wall words a general model gets wrong: "box" heard as "bucks", "deg" as "dog". */
const JARGON = [
  'box',
  'box box',
  'box this lap',
  'push',
  'copy',
  'DRS',
  'undercut',
  'overcut',
  'deg',
  'graining',
  'blistering',
  'tyres',
  'mediums',
  'softs',
  'hards',
  'inters',
  'safety car',
  'VSC',
  'pit wall',
  'Plan A',
  'Plan B',
  'lift and coast',
  'brake bias',
  'diff',
  'engine mode',
  'gap',
]

/**
 * The transcriber for team radio: British English, the session's driver names and the jargon above as contextual
 * strings (honoured by dictation on iOS and by Android's biasing), two clips at a time.
 */
export const useRadioTranscriber = (drivers: Driver[] | null) => {
  const names = useMemo(
    () => (drivers ?? []).flatMap(driver => [driver.last_name, driver.first_name]).filter(Boolean),
    [drivers]
  )
  const options = useMemo<SpeechTranscriberOptions>(
    () => ({
      contextualStrings: [...names, ...JARGON],
      locale: 'en-GB',
      maxConcurrent: 2,
    }),
    [names]
  )

  return useSpeechTranscriber(options)
}
