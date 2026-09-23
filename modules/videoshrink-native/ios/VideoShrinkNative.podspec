Pod::Spec.new do |s|
  s.name           = 'VideoShrinkNative'
  s.version        = '0.1.0'
  s.summary        = 'VideoShrink Phase 0 native Photos and HEVC pipeline'
  s.description    = 'Hosts the existing SwiftUI prototype inside an Expo development build.'
  s.author         = 'VideoShrink'
  s.license        = { :type => 'MIT', :file => '../LICENSE' }
  s.homepage       = 'https://docs.expo.dev/modules/'
  s.platforms      = {
    :ios => '18.0'
  }
  s.source         = { git: '' }
  s.static_framework = true
  s.swift_version = '5.9'
  s.frameworks = 'SwiftUI', 'Photos', 'PhotosUI', 'AVFoundation', 'AVKit', 'CoreVideo'

  s.dependency 'ExpoModulesCore'

  # Swift/Objective-C compatibility
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_STRICT_CONCURRENCY' => 'targeted',
    'SWIFT_DEFAULT_ACTOR_ISOLATION' => 'nonisolated',
  }

  s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"
  s.resource_bundles = {
    'VideoShrinkNativePrivacy' => ['VideoShrinkCore/Resources/PrivacyInfo.xcprivacy']
  }
end
