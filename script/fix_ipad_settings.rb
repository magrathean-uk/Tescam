#!/usr/bin/env ruby
# Adds SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor to the iPad target.

require 'xcodeproj'

project_path = File.join(__dir__, '..', 'Tescam.xcodeproj')
project = Xcodeproj::Project.open(project_path)

ipad_target = project.targets.find { |t| t.name == 'Tescam iPad' }
abort("Cannot find Tescam iPad target") unless ipad_target

ipad_target.build_configurations.each do |config|
  config.build_settings['SWIFT_DEFAULT_ACTOR_ISOLATION'] = 'MainActor'
end

project.save
puts "Done. Set SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor for iPad target."
