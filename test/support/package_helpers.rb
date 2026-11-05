# frozen_string_literal: true

require "bundler"
require "json"
require "open3"
require "tmpdir"
require "rubygems/package"

module PackageHelpers
  ROOT = File.expand_path("../..", __dir__)

  def with_built_package
    Dir.mktmpdir("xitdb-package-") do |directory|
      artifact = File.join(directory, "xitdb.gem")
      gem_command = File.join(File.dirname(Gem.ruby), "gem")
      bundle_command = Gem.bin_path("bundler", "bundle")
      package_command({}, Gem.ruby, gem_command, "build", "xitdb.gemspec", "--output", artifact, chdir: ROOT)
      spec = Gem::Package.new(artifact).spec
      home = File.join(directory, "gems")
      environment = { "GEM_HOME" => home, "GEM_PATH" => [home, Gem.default_dir].join(File::PATH_SEPARATOR),
                      "RUBYLIB" => nil, "RUBYOPT" => nil, "BUNDLE_IGNORE_CONFIG" => "1",
                      "BUNDLE_GEMFILE" => File.join(directory, "Gemfile") }
      package_command(environment, Gem.ruby, gem_command, "install", "--local", "--ignore-dependencies",
                      "--no-document", "--install-dir", home, artifact, chdir: directory)
      File.write(File.join(directory, "Gemfile"),
                 "source \"https://rubygems.org\"\ngem \"xitdb\", \"#{spec.version}\"\n")
      package_command(environment, Gem.ruby, bundle_command, "lock", "--local", chdir: directory)
      @package = [directory, environment, spec, File.join(home, "gems", "xitdb-#{spec.version}"), bundle_command]
      yield spec
    ensure
      @package = nil
    end
  end

  def packaged_example(name)
    directory, environment, = @package
    path = File.join(@package[3], "examples", "#{name}.rb")
    raise "missing packaged example: #{name}" unless File.file?(path)

    JSON.parse(package_command(environment, Gem.ruby, @package[4], "exec", Gem.ruby, path, chdir: directory))
  end

  def package_command(environment, *command, **options)
    output, status = Bundler.with_unbundled_env { Open3.capture2e(environment, *command, **options) }
    raise "#{command.join(" ")} failed (#{status.exitstatus}):\n#{output}" unless status.success?

    output
  end
end
