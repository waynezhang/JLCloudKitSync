Pod::Spec.new do |s|
  s.name         = "JLCloudKitSync"
  s.version      = "0.0.2"
  s.summary      = "Sync CoreData with CloudKit"

  s.description  = <<-DESC
                   A dirty implementation to sync core data with CloudKit. Still under heavy development.
                   DESC

  s.homepage     = "http://github.com/waynezhang/JLCloudkitSync"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = { "waynezhang" => "linghua.zhang@me.com" }
  s.platform     = :ios, "8.0"
  s.source       = { :git => "https://github.com/waynezhang/JLCloudkitSync.git", :tag => s.version }
  s.source_files  = "JLCloudkitSync/*.swift"

  s.requires_arc = true
end
