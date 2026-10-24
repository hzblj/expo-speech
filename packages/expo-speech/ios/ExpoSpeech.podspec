require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExpoSpeech'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.author         = package['author']
  s.homepage       = package['homepage']
  s.license        = package['license']
  # Expo SDK 57's minimum. SpeechAnalyzer is used from iOS 26, SFSpeechRecognizer before it.
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.9'
  s.source         = { :git => 'https://github.com/hzblj/expo-speech.git', :tag => "@hzblj/expo-speech@#{s.version}" }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.frameworks = 'Speech', 'AVFoundation', 'CoreMedia'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }

  # `Tests` is a SwiftPM package over `Core`, run on the Mac; the pod never compiles it.
  s.source_files = '*.swift', 'Core/**/*.swift'
end
