# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "tmpdir"

def command(*arguments)
  output, error, status = Open3.capture3(*arguments)
  raise "#{arguments.first} failed: #{error}" unless status.success?

  output
end

$stdout.sync = true
Dir.mktmpdir("xitdb-diagnostic-") do |directory|
  puts command("uname", "-a")
  puts command("df", "-PTk", directory)
  name = "xitdb-diagnostic-#{SecureRandom.hex(8)}"
  source = "require './test/stress/workload'; BoundedWorkload.hard_budget(268_435_456); " \
           "XitDB.open('/work/source.xit') { |db| " \
           "BoundedWorkload.fixture(db, bytes: 805_306_368, rows: 8192) }"
  begin
    id = command("docker", "run", "-d", "--pull=never", "--network=none", "--name", name,
                 "--memory", "256m", "--memory-swap", "256m", "--read-only",
                 "--mount", "type=bind,src=#{File.expand_path('..', __dir__)},dst=/repo,readonly",
                 "--mount", "type=bind,src=#{directory},dst=/work", "--workdir", "/repo",
                 "--env", "TMPDIR=/work", "ruby:4.0.9-slim", "ruby", "-e", source).strip
    state = JSON.parse(command("docker", "inspect", "--format", "{{json .State}}", id))
    entry = File.readlines("/proc/#{state.fetch('Pid')}/cgroup").find { |line| line.start_with?("0::") }
    raise "missing cgroup v2 entry" unless entry

    group = File.join("/sys/fs/cgroup", entry.split(":", 3).last.strip.delete_prefix("/"))
    loop do
      if File.file?(File.join(group, "memory.stat"))
        stats = File.read(File.join(group, "memory.stat")).lines.to_h(&:split)
        puts JSON.generate(memory: stats.slice("anon", "file", "shmem", "file_dirty", "file_writeback"),
                           current: File.read(File.join(group, "memory.current")).to_i,
                           events: File.read(File.join(group, "memory.events")).lines.to_h(&:split),
                           files: Dir.children(directory).to_h { |file| [file, File.size(File.join(directory, file))] })
      end
      state = JSON.parse(command("docker", "inspect", "--format", "{{json .State}}", id))
      break unless state.fetch("Running")

      sleep 1
    end
    puts JSON.generate(state: state)
    output, error, = Open3.capture3("docker", "logs", id)
    puts output
    warn error unless error.empty?
    abort "fixture failed" unless state.fetch("ExitCode").zero?
  ensure
    system("docker", "rm", "--force", name, out: File::NULL, err: File::NULL)
  end
end
