#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint microphone_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'microphone_flutter'
  s.version          = '0.0.1'
  s.summary          = 'Microphone recording for Flutter.'
  s.description      = <<-DESC
Microphone capture for Flutter: builds the native microphone Rust library and
exposes it to Dart over FFI.
                       DESC
  s.homepage         = 'https://github.com/ManyMath/microphone'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'ManyMath' => 'https://github.com/ManyMath' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  # Build the shared `microphone` Rust crate (static lib) via cargokit and
  # force-link it into the plugin framework.
  s.script_phase = {
    :name => 'Build microphone',
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../rust microphone',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    :output_files => ['${BUILT_PRODUCTS_DIR}/libmicrophone.a'],
  }

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/libmicrophone.a',
  }
  s.swift_version = '5.0'
end
