import {createRunOncePlugin} from 'expo/config-plugins'

import {withSpeech} from './withSpeech'

export {
  addAndroidPermissions,
  addIosPermissions,
  DEFAULT_MICROPHONE_PERMISSION,
  DEFAULT_SPEECH_RECOGNITION_PERMISSION,
  RECORD_AUDIO,
  type SpeechPluginOptions,
  withSpeech,
} from './withSpeech'

const pkg: {name: string; version: string} = require('../../package.json')

export default createRunOncePlugin(withSpeech, pkg.name, pkg.version)
