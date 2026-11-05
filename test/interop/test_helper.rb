# frozen_string_literal: true

require_relative "../../script/interop"

module ReferenceHelpers
  def with_reference(reference)
    Interop.with_reference(reference) do |invoke, dir|
      @invoke = invoke
      @directory = dir
      yield
    ensure
      @invoke = @directory = nil
    end
  end

  def expected_values(_reference)
    Interop.expected_tree
  end

  def read_reference_fixture(reference, name)
    directory = File.join(Interop::ROOT, "test/fixtures/interop", reference)
    path = File.join(directory, "#{name}.xit")
    provenance = JSON.parse(File.read(File.join(directory, "provenance.json")))
    pin = Interop::MANIFEST.fetch("references").fetch(reference)

    assert_equal pin.fetch("revision"), provenance.fetch("revision")
    assert_equal pin.fetch("source_sha256"), provenance.fetch("source_sha256")
    assert_equal Digest::SHA256.file(path).hexdigest, provenance.fetch("fixture_sha256")
    assert_equal Digest::SHA256.file(File.join(Interop::ROOT, "script/interop.rb")).hexdigest,
                 provenance["generator_sha256"]
    adapter = { "go" => "main.go", "typescript" => "main.ts", "java" => "Main.java",
                "zig" => "main.zig" }.fetch(reference)

    assert_equal Digest::SHA256.file(File.join(Interop::ROOT, "test/interop", reference, adapter)).hexdigest,
                 provenance.fetch("adapter_sha256")
    assert_equal Digest::SHA256.file(File.join(Interop::ROOT, "test/interop/manifest.json")).hexdigest,
                 provenance.fetch("manifest_sha256")
    copy = File.join(@directory, "fixture.xit")
    File.binwrite(copy, File.binread(path))
    Interop.assert_reference_result(reference, @invoke.call("read", name, copy))
    Interop.read_tree(path)
  end

  def assert_reference_reads_ruby_file(reference, name)
    path = File.join(@directory, "ruby.xit")
    Interop.write_tree(path)
    result = @invoke.call("read", name, path)

    assert_equal Interop.expected_tree(linked_hole: true), result.fetch("tree")
    Interop.assert_reference_result(reference, result, linked_hole: true)
  end

  def assert_reference_compacts_and_replicates_ruby_file(reference, name = "all-kinds")
    Interop.check_maintenance(@invoke, File.join(@directory, "ruby.xit"), Interop.expected_tree(linked_hole: true))
    path = File.join(@directory, "reference.xit")
    Interop.assert_reference_result(reference, @invoke.call("write", name, path))

    assert_equal expected_values(reference), Interop.read_tree(path)
    Interop.check_maintenance(@invoke, path, expected_values(reference))
    Interop.check_opaque(@invoke, @directory)
    Interop.check_sha384(reference, @invoke, @directory)
  end
end
