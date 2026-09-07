require 'xcodeproj'

project_path = File.join(__dir__, 'Runner.xcodeproj')
project = Xcodeproj::Project.open(project_path)

puts 'Configuring Gopeed Live Activity extension...'

# ============================================================
# Helpers
# ============================================================

def find_group(parent_group, value)
  parent_group.groups.find do |group|
    group.name == value ||
      group.path == value ||
      (group.respond_to?(:display_name) && group.display_name == value)
  end
end

def find_or_add_file(group, filename)
  existing = group.files.find do |file|
    file.path == filename || file.name == filename
  end

  return existing if existing

  group.new_file(filename)
end

# ============================================================
# Validate files before touching the Xcode project
# ============================================================

required_files = [
  File.join(__dir__, 'Runner', 'GopeedDownloadAttributes.swift'),
  File.join(__dir__, 'Runner', 'GopeedLiveActivityManager.swift'),
  File.join(__dir__, 'GopeedLiveActivity', 'GopeedLiveActivityWidget.swift'),
  File.join(__dir__, 'GopeedLiveActivity', 'Info.plist')
]

missing_files = required_files.reject { |path| File.file?(path) }

unless missing_files.empty?
  abort <<~ERROR
    ERROR: Required Live Activity files are missing:
    #{missing_files.map { |path| "  - #{path}" }.join("\n")}
  ERROR
end

# ============================================================
# Locate Runner target and Runner group
# ============================================================

runner = project.targets.find { |target| target.name == 'Runner' }
raise 'ERROR: Runner target not found.' unless runner

# In Gopeed's project.pbxproj the Runner PBXGroup has:
#
#     path = Runner;
#
# but no explicit:
#
#     name = Runner;
#
# Therefore group.name can be nil even though Xcode displays "Runner".
runner_group = find_group(project.main_group, 'Runner')

unless runner_group
  available_groups = project.main_group.groups.map do |group|
    "name=#{group.name.inspect}, path=#{group.path.inspect}"
  end

  abort <<~ERROR
    ERROR: Runner group not found.

    Top-level Xcode groups:
    #{available_groups.map { |value| "  - #{value}" }.join("\n")}
  ERROR
end

puts "Found Runner group: name=#{runner_group.name.inspect}, path=#{runner_group.path.inspect}"

# ============================================================
# Add Live Activity source files to Runner
# ============================================================

attributes_ref = find_or_add_file(
  runner_group,
  'GopeedDownloadAttributes.swift'
)

manager_ref = find_or_add_file(
  runner_group,
  'GopeedLiveActivityManager.swift'
)

runner_sources = runner.source_build_phase.files_references.compact

unless runner_sources.include?(attributes_ref)
  runner.source_build_phase.add_file_reference(attributes_ref, true)
  puts 'Added GopeedDownloadAttributes.swift to Runner'
end

unless runner_sources.include?(manager_ref)
  runner.source_build_phase.add_file_reference(manager_ref, true)
  puts 'Added GopeedLiveActivityManager.swift to Runner'
end

# ============================================================
# Locate/create GopeedLiveActivity Xcode group
# ============================================================

live_group = find_group(project.main_group, 'GopeedLiveActivity')

unless live_group
  live_group = project.main_group.new_group(
    'GopeedLiveActivity',
    'GopeedLiveActivity'
  )

  puts 'Created GopeedLiveActivity project group'
else
  puts "Found GopeedLiveActivity group: name=#{live_group.name.inspect}, path=#{live_group.path.inspect}"
end

widget_ref = find_or_add_file(
  live_group,
  'GopeedLiveActivityWidget.swift'
)

find_or_add_file(
  live_group,
  'Info.plist'
)

# ============================================================
# Create/find Live Activity extension target
# ============================================================

extension_target = project.targets.find do |target|
  target.name == 'GopeedLiveActivityExtension'
end

unless extension_target
  extension_target = project.new_target(
    :app_extension,
    'GopeedLiveActivityExtension',
    :ios,
    '16.2',
    nil,
    :swift
  )

  puts 'Created GopeedLiveActivityExtension target'
else
  puts 'Found existing GopeedLiveActivityExtension target'
end

# Xcodeproj normally copies project configurations into new targets.
# Keep this fallback for projects where Profile is not added automatically.
unless extension_target.build_configurations.any? { |config| config.name == 'Profile' }
  extension_target.add_build_configuration('Profile', :release)
  puts 'Added Profile configuration to Live Activity extension'
end

# ============================================================
# Extension source files
# ============================================================

extension_sources =
  extension_target.source_build_phase.files_references.compact

unless extension_sources.include?(widget_ref)
  extension_target.source_build_phase.add_file_reference(
    widget_ref,
    true
  )

  puts 'Added GopeedLiveActivityWidget.swift to extension'
end

# Use the SAME attributes source file in Runner and the extension.
unless extension_sources.include?(attributes_ref)
  extension_target.source_build_phase.add_file_reference(
    attributes_ref,
    true
  )

  puts 'Added shared GopeedDownloadAttributes.swift to extension'
end

# ============================================================
# Extension build settings
# ============================================================

extension_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] =
    'com.gopeed.gopeed.GopeedLiveActivityExtension'

  config.build_settings['PRODUCT_NAME'] =
    '$(TARGET_NAME)'

  config.build_settings['INFOPLIST_FILE'] =
    'GopeedLiveActivity/Info.plist'

  config.build_settings['GENERATE_INFOPLIST_FILE'] =
    'NO'

  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] =
    '16.2'

  config.build_settings['SWIFT_VERSION'] =
    '5.0'

  config.build_settings['SKIP_INSTALL'] =
    'YES'

  config.build_settings['APPLICATION_EXTENSION_API_ONLY'] =
    'YES'

  config.build_settings['TARGETED_DEVICE_FAMILY'] =
    '1,2'

  config.build_settings['CODE_SIGN_STYLE'] =
    'Automatic'

  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)',
    '@executable_path/Frameworks',
    '@executable_path/../../Frameworks'
  ]
end

# ============================================================
# Runner -> extension target dependency
# ============================================================

dependency_exists = runner.dependencies.any? do |dependency|
  dependency.target == extension_target
end

unless dependency_exists
  runner.add_dependency(extension_target)
  puts 'Added Runner -> GopeedLiveActivityExtension dependency'
end

# ============================================================
# Reuse the existing extension embedding phase
#
# Gopeed already has:
#
#   Embed Foundation Extensions
#     ShareExtension.appex
# ============================================================

embed_phase = runner.copy_files_build_phases.find do |phase|
  phase.name == 'Embed Foundation Extensions'
end

unless embed_phase
  available_phases = runner.copy_files_build_phases.map do |phase|
    phase.name.inspect
  end

  abort <<~ERROR
    ERROR: Existing "Embed Foundation Extensions" phase not found.

    Runner copy-file phases:
    #{available_phases.map { |value| "  - #{value}" }.join("\n")}
  ERROR
end

already_embedded =
  embed_phase.files_references.include?(
    extension_target.product_reference
  )

unless already_embedded
  build_file = embed_phase.add_file_reference(
    extension_target.product_reference,
    true
  )

  build_file.settings = {
    'ATTRIBUTES' => [
      'RemoveHeadersOnCopy'
    ]
  }

  puts 'Embedded GopeedLiveActivityExtension.appex into Runner'
end

# ============================================================
# Save generated project.pbxproj
# ============================================================

project.save

# ============================================================
# Verification output
# ============================================================

puts
puts '=============================================='
puts ' Live Activity Xcode configuration complete'
puts '=============================================='
puts

puts 'Runner source files:'
runner.source_build_phase.files_references.each do |ref|
  puts "  - #{ref.path}"
end

puts
puts 'Live Activity extension source files:'
extension_target.source_build_phase.files_references.each do |ref|
  puts "  - #{ref.path}"
end

puts
puts 'Live Activity build configurations:'
extension_target.build_configurations.each do |config|
  puts "  - #{config.name}"
end

puts
puts 'Embedded extensions:'
embed_phase.files_references.each do |ref|
  puts "  - #{ref.path}"
end

puts
puts 'Expected important entries:'
puts '  Runner sources:'
puts '    GopeedDownloadAttributes.swift'
puts '    GopeedLiveActivityManager.swift'
puts
puts '  Extension sources:'
puts '    GopeedLiveActivityWidget.swift'
puts '    GopeedDownloadAttributes.swift'
puts
puts '  Embedded:'
puts '    ShareExtension.appex'
puts '    GopeedLiveActivityExtension.appex'
