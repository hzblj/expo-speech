import {type LocaleStatus, Speech, type SpeechAvailability, type SpeechMode} from '@hzblj/expo-speech'
import {
  Badge,
  Box,
  HStack,
  Island,
  Pressable,
  RnFlatList,
  RnText,
  SegmentedControl,
  Spacer,
  Text,
  VStack,
} from '@hzblj/kara-ui'
import {useCallback, useEffect, useState} from 'react'
import {Platform} from 'react-native'

import {Caption} from '../ui/karaoke'

const MODES: SpeechMode[] = ['transcription', 'dictation']

/** English names for what the engines offer, where the JavaScript engine has no `Intl.DisplayNames` (Hermes). */
const LANGUAGES: Record<string, string> = {
  ar: 'Arabic',
  ca: 'Catalan',
  cmn: 'Mandarin',
  cs: 'Czech',
  da: 'Danish',
  de: 'German',
  el: 'Greek',
  en: 'English',
  es: 'Spanish',
  fi: 'Finnish',
  fr: 'French',
  he: 'Hebrew',
  hi: 'Hindi',
  hr: 'Croatian',
  hu: 'Hungarian',
  id: 'Indonesian',
  it: 'Italian',
  ja: 'Japanese',
  ko: 'Korean',
  ms: 'Malay',
  nb: 'Norwegian',
  nl: 'Dutch',
  pl: 'Polish',
  pt: 'Portuguese',
  ro: 'Romanian',
  ru: 'Russian',
  sk: 'Slovak',
  sv: 'Swedish',
  th: 'Thai',
  tr: 'Turkish',
  uk: 'Ukrainian',
  vi: 'Vietnamese',
  wuu: 'Wu',
  yue: 'Cantonese',
  zh: 'Chinese',
}

const REGIONS: Record<string, string> = {
  AE: 'United Arab Emirates',
  AT: 'Austria',
  AU: 'Australia',
  BE: 'Belgium',
  BR: 'Brazil',
  CA: 'Canada',
  CH: 'Switzerland',
  CL: 'Chile',
  CN: 'China',
  CO: 'Colombia',
  CZ: 'Czechia',
  DE: 'Germany',
  DK: 'Denmark',
  ES: 'Spain',
  FI: 'Finland',
  FR: 'France',
  GB: 'United Kingdom',
  HK: 'Hong Kong',
  IE: 'Ireland',
  IN: 'India',
  IT: 'Italy',
  JP: 'Japan',
  KR: 'South Korea',
  MX: 'Mexico',
  NL: 'Netherlands',
  NO: 'Norway',
  NZ: 'New Zealand',
  PL: 'Poland',
  PT: 'Portugal',
  RU: 'Russia',
  SA: 'Saudi Arabia',
  SE: 'Sweden',
  SG: 'Singapore',
  TR: 'Türkiye',
  TW: 'Taiwan',
  US: 'United States',
  ZA: 'South Africa',
}

const languageName = (tag: string) => {
  try {
    const name = new Intl.DisplayNames(['en'], {type: 'language'}).of(tag)
    if (name && name !== tag) {
      return name
    }
  } catch {
    // Hermes: the table below.
  }
  const parts = tag.split('-')
  const language = LANGUAGES[parts[0] ?? ''] ?? parts[0] ?? tag
  const region = parts.map(part => REGIONS[part]).find(Boolean)
  return region ? `${language} (${region})` : language
}

const Capabilities = ({availability}: {availability: SpeechAvailability | null}) => {
  if (!availability) {
    return null
  }
  const rows: [string, boolean][] = [
    ['Speech recognition', availability.available],
    ['On the device', availability.onDevice],
    ['Files', availability.fileTranscription],
    ['Word timing', availability.wordTiming],
    ...(Platform.OS === 'ios'
      ? ([
          ['SpeechTranscriber', availability.transcriber],
          ['DictationTranscriber', availability.dictation],
        ] as [string, boolean][])
      : ([['Language detection', availability.languageDetection]] as [string, boolean][])),
  ]

  return (
    <Island>
      <VStack bg="surface.primary" borderRadius="large" p="s16" spacing="s12" wide>
        <HStack align="center" wide>
          <Text variant="headline">Engine</Text>
          <Spacer />
          <Badge label={availability.engine} tone="accent" />
        </HStack>
        {rows.map(([label, value]) => (
          <HStack align="center" key={label} wide>
            <Text color="content.secondary">{label}</Text>
            <Spacer />
            <Badge label={value ? 'Yes' : 'No'} tone={value ? 'success' : 'neutral'} />
          </HStack>
        ))}
      </VStack>
    </Island>
  )
}

type Row = {locale: string; status: LocaleStatus}

/**
 * What the device can transcribe, and in which languages: installed models first, then the ones that can be
 * downloaded. Tap a language to install it.
 */
export const LanguagesScreen = () => {
  const [mode, setMode] = useState(0)
  const [availability, setAvailability] = useState<SpeechAvailability | null>(null)
  const [rows, setRows] = useState<Row[]>([])
  const [reserved, setReserved] = useState<string[]>([])
  const [installing, setInstalling] = useState<Record<string, number>>({})
  const [failure, setFailure] = useState<string | null>(null)

  const load = useCallback(async () => {
    const options = {mode: MODES[mode]}
    const [available, supported, installed, reservedLocales] = await Promise.all([
      Speech.getAvailabilityAsync(options),
      Speech.getSupportedLocalesAsync(options),
      Speech.getInstalledLocalesAsync(options),
      Speech.getReservedLocalesAsync(),
    ])
    const installedSet = new Set(installed)
    const all = [...new Set([...installed, ...supported])]

    setAvailability(available)
    setReserved(reservedLocales)
    setRows(
      all
        .map<Row>(locale => ({locale, status: installedSet.has(locale) ? 'installed' : 'supported'}))
        .sort((a, b) =>
          a.status === b.status
            ? languageName(a.locale).localeCompare(languageName(b.locale))
            : a.status === 'installed'
              ? -1
              : 1
        )
    )
  }, [mode])

  useEffect(() => {
    load().catch(error => setFailure(error.message))
  }, [load])

  const install = async (locale: string) => {
    setFailure(null)
    setInstalling(current => ({...current, [locale]: 0}))
    try {
      await Speech.installLocaleAsync(locale, {
        mode: MODES[mode],
        onProgress: fraction => setInstalling(current => ({...current, [locale]: fraction})),
      })
      await load()
    } catch (error) {
      setFailure((error as Error).message)
    } finally {
      setInstalling(({[locale]: _, ...rest}) => rest)
    }
  }

  return (
    <RnFlatList
      ListHeaderComponent={
        <Box gap="s24" pb="s16">
          <Capabilities availability={availability} />
          <SegmentedControl onChange={setMode} selectedIndex={mode} values={['Transcription', 'Dictation']} />
          {Platform.OS === 'ios' && Speech.maximumReservedLocales > 0 ? (
            <Caption>{`Reserved ${reserved.length} of ${Speech.maximumReservedLocales}: ${reserved.join(', ') || 'none'}`}</Caption>
          ) : null}
          {failure ? (
            <RnText color="content.destructive" variant="footnote">
              {failure}
            </RnText>
          ) : null}
        </Box>
      }
      bg="surface.base"
      content={{gap: 's8', pb: 's96', pt: 's8', px: 's20'}}
      contentInsetAdjustmentBehavior="automatic"
      data={rows}
      flex={1}
      keyExtractor={row => row.locale}
      renderItem={({item}) => {
        const progress = installing[item.locale]
        return (
          <Pressable
            accessibilityHint={item.status === 'installed' ? undefined : 'Downloads the language model'}
            accessibilityLabel={languageName(item.locale)}
            align="center"
            bg="surface.primary"
            borderRadius="medium"
            disabled={item.status === 'installed' || progress !== undefined}
            gap="s12"
            onPress={() => install(item.locale)}
            px="s16"
            py="s12"
            row
          >
            <Box fill gap="s2">
              <RnText variant="body">{languageName(item.locale)}</RnText>
              <RnText color="content.tertiary" variant="caption">
                {item.locale}
              </RnText>
            </Box>
            <RnText
              color={item.status === 'installed' ? 'content.success' : 'content.secondary'}
              variant="footnoteMedium"
            >
              {progress !== undefined
                ? `${Math.round(progress * 100)} %`
                : item.status === 'installed'
                  ? 'Installed'
                  : 'Download'}
            </RnText>
          </Pressable>
        )
      }}
      testID="languages"
    />
  )
}
