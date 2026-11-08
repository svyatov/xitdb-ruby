# frozen_string_literal: true

# Builds a disposable runtime before starting the memory-limited container.
# Only sources are copied, so host-native binaries cannot enter the runtime.
require "fileutils"
require "rbconfig"

raise ArgumentError, "usage: ruby script/stress_build.rb DESTINATION" unless ARGV.size == 1

destination = File.expand_path(ARGV.fetch(0))
raise ArgumentError, "destination already exists" if File.exist?(destination)

root = File.expand_path("..", __dir__)
Dir.chdir(root) do
  Dir["lib/**/*.rb", "test/stress/*.rb"].each do |source|
    target = File.join(destination, source)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(source, target)
  end
end
build = File.join(destination, "build")
FileUtils.mkdir_p(build)
Dir.chdir(build) do
  unless system(RbConfig.ruby, File.join(root, "ext/xitdb/page_codec/extconf.rb"))
    abort "native codec configuration failed"
  end
  abort "native codec compilation failed" unless system(RbConfig::CONFIG.fetch("MAKE", "make"))

  FileUtils.cp("page_codec.#{RbConfig::CONFIG.fetch("DLEXT")}", File.join(destination, "lib/xitdb"))
end
