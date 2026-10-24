/**
 * Checks what npm would receive, the way a consumer meets it. Packs every published package (each `prepack` builds it
 * through turbo's cache), asserts what must and must not ship in each tarball, then installs it into a throwaway app
 * and type-checks real usage with a consumer's TypeScript: no `source` condition, no workspace links, only what the
 * tarball declares. The config plugin is loaded from the tarball too, the way prebuild loads it.
 *
 * The negative cases matter as much as the positive ones: if a declaration failed to resolve, its imports would
 * quietly become `any` and everything would compile, so each `@ts-expect-error` is there to prove the types are real.
 */
import {execFileSync} from 'node:child_process'
import {existsSync} from 'node:fs'
import {mkdir, readdir, readFile, rm, writeFile} from 'node:fs/promises'
import {createRequire} from 'node:module'
import path from 'node:path'

const ROOT = path.resolve(import.meta.dirname, '..')
const WORK = path.join(ROOT, '.pack-check')

const run = (command, args, cwd = ROOT) => execFileSync(command, args, {cwd, encoding: 'utf8'})

const fail = message => {
  console.error(`pack-check: ${message}`)
  process.exit(1)
}

const REQUIRED = {
  '@hzblj/expo-speech': [
    'package.json',
    'README.md',
    'LICENSE',
    'app.plugin.js',
    'build/index.js',
    'build/index.d.ts',
    'build/types.d.ts',
    'plugin/build/index.js',
    'plugin/build/index.d.ts',
    'expo-module.config.json',
    'ios/ExpoSpeech.podspec',
    'ios/ExpoSpeechModule.swift',
    'ios/SpeechTranscriberObject.swift',
    'ios/TranscriptionObject.swift',
    'ios/Core/AnalyzerEngine.swift',
    'ios/Core/RecognizerEngine.swift',
    'ios/Core/TranscriptAssembler.swift',
    'android/build.gradle',
    'android/src/main/AndroidManifest.xml',
    'android/src/main/java/com/hzblj/expospeech/ExpoSpeechModule.kt',
    'android/src/main/java/com/hzblj/expospeech/AndroidEngine.kt',
  ],
}

// The tests of all four and the build output of the native projects stay home. The TypeScript source ships: `exports`
// names it under the `source` condition.
const FORBIDDEN = [
  /^test\//,
  /^plugin\/(src|test)\//,
  /^ios\/Tests\//,
  /^android\/src\/test\//,
  /\/build\/intermediates\//,
  /\.DS_Store$/,
]

const packages = []

for (const directory of await readdir(path.join(ROOT, 'packages'))) {
  const manifestPath = path.join(ROOT, 'packages', directory, 'package.json')

  if (!existsSync(manifestPath)) {
    continue
  }

  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))

  if (!manifest.private) {
    packages.push({directory, name: manifest.name})
  }
}

await rm(WORK, {force: true, recursive: true})
await mkdir(path.join(WORK, 'tarballs'), {recursive: true})

let fileCount = 0

for (const {directory, name} of packages) {
  const tarball = path.join(WORK, 'tarballs', `${directory}.tgz`)

  run('yarn', ['pack', '--out', tarball], path.join(ROOT, 'packages', directory))

  const files = run('tar', ['-tzf', tarball])
    .split('\n')
    .filter(Boolean)
    .map(file => file.replace(/^package\//, ''))

  const missing = (REQUIRED[name] ?? ['package.json', 'README.md']).filter(file => !files.includes(file))
  const leaked = files.filter(file => FORBIDDEN.some(pattern => pattern.test(file)))

  if (missing.length > 0) {
    fail(`${name} is missing:\n  ${missing.join('\n  ')}`)
  }

  if (leaked.length > 0) {
    fail(`${name} must not ship:\n  ${leaked.join('\n  ')}`)
  }

  const packed = JSON.parse(run('tar', ['-xzOf', tarball, 'package/package.json']))

  if (JSON.stringify(packed.dependencies ?? {}).includes('workspace:')) {
    fail(`${name} still declares a workspace: range: it would not install outside this repo`)
  }

  const installed = path.join(WORK, 'node_modules', name)

  await mkdir(installed, {recursive: true})
  run('tar', ['-xzf', tarball, '-C', installed, '--strip-components', '1'])
  fileCount += files.length
}

// The config plugin, as prebuild requires it: `app.plugin.js` from the tarball, run over a minimal config.
const plugin = createRequire(path.join(WORK, 'package.json'))('@hzblj/expo-speech/app.plugin.js')
const withSpeech = plugin.default ?? plugin

if (typeof withSpeech !== 'function') {
  fail('app.plugin.js does not export a config plugin')
}

withSpeech({name: 'Consumer', slug: 'consumer'}, {microphonePermission: 'Talk to the car.'})

const consumer = `import {
  type PlaybackSource,
  Speech,
  SpeechTranscriber,
  type Transcript,
  TranscriptText,
  toSRT,
  toWebVTT,
  type Transcription,
  useSpeechTranscriber,
  useTranscribe,
  useTranscriptPlayback,
  useTranscription,
  wordIndexAt,
} from '@hzblj/expo-speech'
import type {SpeechPluginOptions} from '@hzblj/expo-speech/plugin'

export const transcriber = new SpeechTranscriber({contextualStrings: ['Verstappen'], locale: 'en-GB'})

export const once = async (): Promise<Transcript> => {
  const transcription: Transcription = transcriber.transcribe('https://example.com/radio.mp3', {cacheKey: 'radio', priority: 'high'})
  transcription.addListener('update', ({segments, volatile}) => segments.length + (volatile ? 1 : 0))
  const transcript = await transcription.wait()
  const subtitles: string = toWebVTT(transcript) + toSRT(transcript, {maxCharacters: 42})
  return {...transcript, text: subtitles}
}

export const available = async () => {
  const permission = await Speech.requestPermissionsAsync({microphone: true})
  const locales: string[] = await Speech.getInstalledLocalesAsync({mode: 'dictation'})
  await Speech.installLocaleAsync('cs-CZ', {onProgress: fraction => fraction * 100})
  return permission.granted && locales.length > 0
}

export const Caption = ({player}: {player: PlaybackSource}) => {
  const live = useSpeechTranscriber({android: {languageDetection: true}, ios: {engine: 'analyzer'}, mode: 'dictation'})
  const {transcript} = useTranscribe(live, 'file:///radio.m4a', {cacheKey: 'radio'})
  const {wordIndex} = useTranscriptPlayback(transcript, player)
  const snapshot = useTranscription(null)
  return <TranscriptText transcript={snapshot.state ? snapshot.transcript : transcript} wordIndex={Math.max(wordIndex, wordIndexAt(transcript, 1))} />
}

export const options: SpeechPluginOptions = {microphonePermission: false, speechRecognitionPermission: 'Turn radio into text.'}

// @ts-expect-error: the mode is transcription or dictation
export const wrongMode = new SpeechTranscriber({mode: 'search'})

// @ts-expect-error: a transcription is waited for, not awaited itself
export const notAPromise: Transcript = transcriber.transcribe('file:///radio.m4a').text

// @ts-expect-error: an iOS option is under ios
export const misplaced = new SpeechTranscriber({fastResults: true})
`

await writeFile(path.join(WORK, 'consumer.tsx'), consumer)
await writeFile(
  path.join(WORK, 'tsconfig.json'),
  JSON.stringify(
    {
      compilerOptions: {noEmit: true, skipLibCheck: true, strict: true},
      extends: 'expo/tsconfig.base',
      include: ['consumer.tsx'],
    },
    null,
    2
  )
)

try {
  run('yarn', ['run', '-T', 'tsc', '-p', WORK])
} catch (error) {
  fail(`a consumer's type check failed:\n${error.stdout}`)
}

await rm(WORK, {force: true, recursive: true})

console.log(`pack-check: ${packages.length} package, ${fileCount} files, the plugin runs and a consumer type-checks`)
