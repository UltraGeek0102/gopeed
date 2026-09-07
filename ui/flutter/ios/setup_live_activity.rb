require 'xcodeproj'

project_path = File.join(__dir__, 'Runner.xcodeproj')
project = Xcodeproj::Project.open(project_path)

puts 'Configuring Gopeed Live Activity extension...'

# ============================================================
# Locate Runner
# ============================================================

runner = project.targets.find { |target| target.name == 'Runner' }

raise 'ERROR: Runner target not found.' unless runner

runner_group = project.main_group.groups.find do |group|
  group.name == 'Runner'
end

raise 'ERROR: Runner group not found.' unless runner_group


# ============================================================
# Helper
# ============================================================

def find_or_add_file(group, filename)
  existing = group.files.find do |file|
    file.path == filename || file.name == filename
  end

  return existing if existing

  group.new_file(filename)
end


# ============================================================
# Runner Live Activity source files
# ============================================================

attributes_ref = find_or_add_file(
  runner_group,
  'GopeedDownloadAttributes.swift'
)

manager_ref = find_or_add_file(
  runner_group,
  'GopeedLiveActivityManager.swift'
)

runner_sources =
  runner.source_build_phase.files_references.compact

unless runner_sources.include?(attributes_ref)
  runner.source_build_phase.add_file_reference(
    attributes_ref,
    true
  )

  puts 'Added GopeedDownloadAttributes.swift to Runner'
end

unless runner_sources.include?(manager_ref)
  runner.source_build_phase.add_file_reference(
    manager_ref,
    true
  )

  puts 'Added GopeedLiveActivityManager.swift to Runner'
end


# ============================================================
# GopeedLiveActivity Xcode group
# ============================================================

live_group = project.main_group.groups.find do |group|
  group.name == 'GopeedLiveActivity'
end

unless live_group
  live_group = project.main_group.new_group(
    'GopeedLiveActivity',
    'GopeedLiveActivity'
  )

  puts 'Created GopeedLiveActivity project group'
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
# Create Live Activity extension target
# ============================================================

extension_target = project.targets.find do |target|
  target.name == 'GopeedLiveActivityExtension'
end

unless extension_target
  extension_target = project.new_target(
    :app_extension,
    'GopeedLiveActivityExtension',
    :ios,
    '16.2'
  )

  puts 'Created GopeedLiveActivityExtension target'
end


# ============================================================
# Make sure Profile configuration exists
# ============================================================

unless extension_target.build_configurations.any? { |c| c.name == 'Profile' }
  extension_target.add_build_configuration(
    'Profile',
    :release
  )

  puts 'Added Profile configuration to Live Activity extension'
end


# ============================================================
# Extension source files
# ============================================================

extension_sources =
  extension_target
    .source_build_phase
    .files_references
    .compact

unless extension_sources.include?(widget_ref)
  extension_target
    .source_build_phase
    .add_file_reference(
      widget_ref,
      true
    )

  puts 'Added GopeedLiveActivityWidget.swift to extension'
end

# Important:
# The SAME GopeedDownloadAttributes.swift file is compiled into
# Runner and the extension. Do not make a duplicate copy.

unless extension_sources.include?(attributes_ref)
  extension_target
    .source_build_phase
    .add_file_reference(
      attributes_ref,
      true
    )

  puts 'Added shared GopeedDownloadAttributes.swift to extension'
end


# ============================================================
# Extension build settings
# ============================================================

extension_target.build_configurations.each do |config|

  config.build_settings[
    'PRODUCT_BUNDLE_IDENTIFIER'
  ] = 'com.gopeed.gopeed.GopeedLiveActivityExtension'

  config.build_settings[
    'PRODUCT_NAME'
  ] = '$(TARGET_NAME)'

  config.build_settings[
    'INFOPLIST_FILE'
  ] = 'GopeedLiveActivity/Info.plist'

  config.build_settings[
    'GENERATE_INFOPLIST_FILE'
  ] = 'NO'

  config.build_settings[
    'IPHONEOS_DEPLOYMENT_TARGET'
  ] = '16.2'

  config.build_settings[
    'SWIFT_VERSION'
  ] = '5.0'

  config.build_settings[
    'SKIP_INSTALL'
  ] = 'YES'

  config.build_settings[
    'APPLICATION_EXTENSION_API_ONLY'
  ] = 'YES'

  config.build_settings[
    'TARGETED_DEVICE_FAMILY'
  ] = '1,2'

  config.build_settings[
    'CODE_SIGN_STYLE'
  ] = 'Automatic'

  config.build_settings[
    'LD_RUNPATH_SEARCH_PATHS'
  ] = [
    '$(inherited)',
    '@executable_path/Frameworks',
    '@executable_path/../../Frameworks'
  ]
end


# ============================================================
# Runner depends on Live Activity extension
# ============================================================

dependency_exists = runner.dependencies.any? do |dependency|
  dependency.target == extension_target
end

unless dependency_exists
  runner.add_dependency(extension_target)

  puts 'Added Runner -> GopeedLiveActivityExtension dependency'
end


# ============================================================
# Embed extension in Runner.app/PlugIns
#
# Your project ALREADY has:
#
#   Embed Foundation Extensions
#       ShareExtension.appex
#
# We reuse that same phase.
# ============================================================

embed_phase = runner.copy_files_build_phases.find do |phase|
  phase.name == 'Embed Foundation Extensions'
end

unless embed_phase
  raise <<~ERROR
    ERROR: Existing "Embed Foundation Extensions" phase not found.

    This project is expected to already contain the phase used for
    ShareExtension.appex. Aborting instead of creating a potentially
    conflicting phase.
  ERROR
end


# ============================================================
# Add Live Activity .appex to existing embed phase
# ============================================================

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
# Save project
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

extension_target
  .source_build_phase
  .files_references
  .each do |ref|

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
puts
