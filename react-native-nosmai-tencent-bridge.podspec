require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
Pod::Spec.new do |s|
  s.name = 'react-native-nosmai-tencent-bridge'
  s.version = package['version']
  s.summary = package['description']
  s.homepage = 'https://github.com/HashirYamin-dev/nosmai_tencent_react_native_bridge'
  s.license = { :type => 'MIT' }
  s.authors = 'Nosmai Tencent Bridge contributors'
  s.source = { :path => '.' }
  s.source_files = 'ios/**/*.{h,m,mm}'
  s.platform = :ios, '15.0'
  s.requires_arc = true
  s.dependency 'React-Core'
  s.dependency 'NosmaiCameraSDK', '3.0.7'
  s.dependency 'TXLiteAVSDK_Professional', '13.4.21067'
  s.frameworks = 'CoreVideo', 'AVFoundation', 'UIKit'
end
