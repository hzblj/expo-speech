import assert from 'node:assert/strict'
import {test} from 'node:test'
import type {AndroidConfig} from 'expo/config-plugins'

import {
  addAndroidPermissions,
  addIosPermissions,
  DEFAULT_MICROPHONE_PERMISSION,
  DEFAULT_SPEECH_RECOGNITION_PERMISSION,
  RECORD_AUDIO,
} from '../src/withSpeech'

const manifest = (): AndroidConfig.Manifest.AndroidManifest => ({
  manifest: {$: {'xmlns:android': 'http://schemas.android.com/apk/res/android'}, application: [], queries: []},
})

const permissionsOf = (value: AndroidConfig.Manifest.AndroidManifest) =>
  (value.manifest['uses-permission'] ?? []).map(item => item.$['android:name'])

test('both usage descriptions by default', () => {
  assert.deepEqual(addIosPermissions({}, {}), {
    NSMicrophoneUsageDescription: DEFAULT_MICROPHONE_PERMISSION,
    NSSpeechRecognitionUsageDescription: DEFAULT_SPEECH_RECOGNITION_PERMISSION,
  })
})

test('the app keeps its own texts unless the plugin is given others', () => {
  const own = {NSMicrophoneUsageDescription: 'Talk to the car.'}

  assert.equal(addIosPermissions(own, {}).NSMicrophoneUsageDescription, 'Talk to the car.')
  assert.equal(
    addIosPermissions(own, {microphonePermission: 'Radio check.'}).NSMicrophoneUsageDescription,
    'Radio check.'
  )
})

test('false leaves a permission out on both platforms', () => {
  const plist = addIosPermissions({}, {microphonePermission: false, speechRecognitionPermission: false})

  assert.deepEqual(plist, {})
  assert.deepEqual(permissionsOf(addAndroidPermissions(manifest(), {microphonePermission: false})), [])
})

test('RECORD_AUDIO on Android, once', () => {
  const value = addAndroidPermissions(addAndroidPermissions(manifest(), {}), {})

  assert.deepEqual(permissionsOf(value), [RECORD_AUDIO])
})
