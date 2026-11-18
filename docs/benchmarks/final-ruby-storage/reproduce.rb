# frozen_string_literal: true

require "json"
require "zlib"
require "digest"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

# Verifies archived observations and reruns their contracts without repeating timing.
module StorageEvidence
  CONTRACTS = %w[fixture_test.rb compact_test.rb acceptance_test.rb].freeze

  def self.read(directory, name)
    JSON.parse(Zlib::GzipReader.open(File.join(directory, name), &:read))
  end

  def self.checksums!(directory, provenance)
    provenance.fetch("artifacts").each do |name, expected|
      observed = Digest::SHA256.file(File.join(directory, name)).hexdigest
      raise "archive checksum mismatch: #{name}" unless observed == expected
    end
  end

  def self.extract!(sources, directory)
    sources.each do |name, source|
      raise "unsafe archive path" if name.start_with?("/") || name.split("/").include?("..")

      path = File.join(directory, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end
  end

  def self.run!(directory, root, script, *, expected: 0)
    output, errors, status = Open3.capture3({ "XITDB_PROBE_ROOT" => root }, RbConfig.ruby,
                                            File.join(directory, script), *, chdir: root)
    raise "#{script} failed:\n#{output}#{errors}" unless status.exitstatus == expected

    puts output
  end

  def self.checkout!(provenance, root)
    provenance.fetch("production_contract_sources").each do |name, expected|
      observed = Digest::SHA256.file(File.join(root, name)).hexdigest
      raise "checkout source mismatch: #{name}" unless observed == expected
    end
  end

  def self.measurement!(run, sources, stage, provenance)
    expected_mode = stage == "production" ? "production" : "prototype"
    raise "wrong measurement mode" unless run.fetch("mode") == expected_mode

    if stage == "production"
      library = provenance.fetch("production_contract_sources").select { |name, _| name.start_with?("lib/") }
      raise "production measurement source mismatch" unless library == run.fetch("libraries").fetch("compact")
    end
    observed = sources.transform_values { |source| Digest::SHA256.hexdigest(source) }
    raise "measured source mismatch" unless observed == run.fetch("harness")
    raise "incomplete observations" unless run["finished"] && run.fetch("results").size == 1344
  end

  def self.same_json!(path, expected, label)
    raise "#{label} differs" unless JSON.parse(File.read(path)) == expected
  end

  def self.confirmed_summary!(temporary, directory, root, input, summary)
    primary_acceptance = File.join(temporary, "primary-acceptance.json")
    run!(temporary, root, "acceptance.rb", summary, primary_acceptance, expected: 1)
    same_json!(summary, read(directory, "production-primary-summary.json.gz"), "primary summary")
    same_json!(primary_acceptance, read(directory, "production-primary-acceptance.json.gz"), "primary acceptance")
    confirmation = File.join(temporary, "confirmation.json")
    File.write(confirmation, JSON.generate(read(directory, "production-confirmation-run.json.gz")))
    pooled = File.join(temporary, "pooled-summary.json")
    run!(directory, root, "merge_confirmation.rb", input, summary, primary_acceptance, confirmation, pooled)
    pooled
  end

  def self.replay!(temporary, directory, root, stage, run)
    input = File.join(temporary, "run.json")
    summary = File.join(temporary, "summary.json")
    acceptance = File.join(temporary, "acceptance.json")
    File.write(input, JSON.generate(run))
    CONTRACTS.each { |script| run!(temporary, root, script) }
    run!(temporary, root, "summarize.rb", input, summary)
    summary = confirmed_summary!(temporary, directory, root, input, summary) if stage == "production"
    run!(temporary, root, "acceptance.rb", summary, acceptance)
    same_json!(summary, read(directory, "#{stage}-summary.json.gz"), "regenerated summary")
    same_json!(acceptance, read(directory, "#{stage}-acceptance.json.gz"), "regenerated acceptance")
  end

  def self.replay_stage!(directory, root, stage, provenance)
    checksums!(directory, JSON.parse(File.read(File.join(directory, "#{stage}-provenance.json"))))
    run = read(directory, "#{stage}-run.json.gz")
    sources = read(directory, "#{stage}-harness.json.gz")
    measurement!(run, sources, stage, provenance)
    Dir.mktmpdir("xitdb-storage-reproduce") do |temporary|
      extract!(sources, temporary)
      replay!(temporary, directory, root, stage, run)
    end
  end

  def self.fixture!(directory)
    fixture = JSON.parse(File.read(File.join(directory, "fixture-provenance.json")))
    observed = Digest::SHA256.file(File.join(directory, fixture.fetch("artifact"))).hexdigest
    raise "fixture checksum mismatch" unless observed == fixture.fetch("sha256")
  end

  def self.verify!(directory, root)
    provenance = JSON.parse(File.read(File.join(directory, "production-provenance.json")))
    checksums!(directory, provenance)
    checkout!(provenance, root)
    %w[selection production].each { |stage| replay_stage!(directory, root, stage, provenance) }
    run!(directory, root, "analysis_test.rb")
    fixture!(directory)
    puts "Archives reproduce the original failure and all confirmation observations; 444 final decisions pass"
  end
end

StorageEvidence.verify!(File.expand_path(__dir__), File.expand_path("../../..", __dir__)) if $PROGRAM_NAME == __FILE__
