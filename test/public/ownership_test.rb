# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class PublicOwnershipTest < Minitest::Test
  def setup
    @db = XitDB.memory
  end

  def teardown
    @db.close unless @db.closed?
  end

  def test_assignment_captures_values_without_aliases
    @db.transaction do |root|
      root["a"] = [1]
      root["b"] = root["a"]
      root["b"] << 2

      assert_equal [1], root["a"].to_ruby
      root["a"] << 3

      assert_equal [1, 2], root["b"].to_ruby

      source = [+"leaf"]
      root["shared"] = [source, source]
      source.first.replace("changed")
      source << 4
      value = root["shared"].to_ruby
      value[0][0] << " edited"
      value[0] << 5

      assert_equal ["leaf"], value[1]
      assert_equal [["leaf"], ["leaf"]], root["shared"].to_ruby
      assert_predicate root["shared"][0][0], :frozen?
    end
  end

  def test_rejects_private_singleton_keys_and_values_without_copy_hooks
    input = +"text"
    class << input
      private

      def hidden = :singleton_behavior
      def singleton_methods(*) = raise("must not call singleton_methods")
      def singleton_class = raise("must not call singleton_class")
      def class = raise("must not call class")
      def is_a?(*) = raise("must not call is_a?")
      def dup = raise("must not call dup")
      def freeze = raise("must not call freeze")
      def initialize_dup(*) = raise("must not call initialize_dup")
    end
    @db.transaction do |root|
      root["kept"] = 1
      bound = root.context.read_bound
      key_error = assert_raises(XitDB::UnsupportedValueError) { root[input] = 2 }
      assert_equal ["text"], key_error.path
      assert_predicate key_error.path, :frozen?
      assert_predicate key_error.path.first, :frozen?
      assert_instance_of XitDB::UnsupportedValueError, key_error.cause
      value_error = assert_raises(XitDB::UnsupportedValueError) { root["value"] = input }
      assert_equal ["value"], value_error.path
      assert_equal bound, root.context.read_bound
      assert_equal({ "kept" => 1 }, root.to_ruby)
    end
    refute Object.instance_method(:frozen?).bind_call(input)
    assert_equal "text", input
  end

  def test_rejects_basic_object_keys_and_values_with_immutable_error_paths
    @db.transaction do |root|
      root["kept"] = 1
      bound = root.context.read_bound
      key_error = assert_raises(XitDB::UnsupportedValueError) { root[BasicObject.new] = 2 }
      assert_equal ["#<unsupported BasicObject>"], key_error.path
      assert_predicate key_error.path, :frozen?
      assert_predicate key_error.path.first, :frozen?
      assert_instance_of XitDB::UnsupportedValueError, key_error.cause
      value_error = assert_raises(XitDB::UnsupportedValueError) { root["value"] = BasicObject.new }
      assert_equal ["value"], value_error.path
      assert_equal bound, root.context.read_bound
      assert_equal({ "kept" => 1 }, root.to_ruby)
    end
  end

  def test_rejects_extensions_without_calling_their_identity_hooks
    %i[true false mutate raise].each do |behavior|
      input = +"text"
      calls = []
      extension = Module.new do
        private

        def hidden = :singleton_behavior
      end
      extension.define_singleton_method(:equal?) do |*|
        calls << behavior
        input.replace("changed") if behavior == :mutate
        raise "identity hook ran" if behavior == :raise

        behavior != false
      end
      input.extend(extension)
      @db.transaction do |root|
        assert_raises(XitDB::UnsupportedValueError, behavior.to_s) { root[input] = input }
        assert_raises(XitDB::UnsupportedValueError, behavior.to_s) { root["value"] = input }
        assert_empty calls
        assert_equal "text", input
        assert_empty root.to_ruby
      end
    end
    @db.transaction { |root| root["frozen"] = [nil, 1, 1.0, "text"] }

    assert_equal [nil, 1, 1.0, "text"], @db.snapshot["frozen"].to_ruby
  end

  def test_rejects_removed_string_methods_before_key_or_value_consumption
    %i[bytesize upcase display puts initialize_copy is_a?].each do |method|
      input = +"text"
      input.singleton_class.undef_method(method)
      @db.transaction do |root|
        root["kept"] = 1
        bound = root.context.read_bound
        key_error = assert_raises(XitDB::UnsupportedValueError, method.to_s) { root[input] = 1 }
        assert_equal ["text"], key_error.path
        value_error = assert_raises(XitDB::UnsupportedValueError, method.to_s) { root["value"] = input }
        assert_equal ["value"], value_error.path
        assert_equal bound, root.context.read_bound
        assert_equal({ "kept" => 1 }, root.to_ruby)
      end
    end
  end

  def test_rejects_removed_container_methods_before_consumption
    [[[1], :each], [[1], :reverse], [{ "key" => 1 }, :each_pair], [Set[1], :each]].each do |input, method|
      input.singleton_class.undef_method(method)
      @db.transaction do |root|
        root["kept"] = 1
        bound = root.context.read_bound
        error = assert_raises(XitDB::UnsupportedValueError, method.to_s) { root["value"] = input }
        assert_equal ["value"], error.path
        assert_equal bound, root.context.read_bound
        assert_equal({ "kept" => 1 }, root.to_ruby)
      end
    end
  end

  def test_fresh_root_remains_usable_after_rejecting_removed_methods
    input = [1]
    input.singleton_class.undef_method(:reverse)
    @db.transaction do |root|
      assert_raises(XitDB::UnsupportedValueError) { root["rejected"] = input }
      assert_empty root.to_ruby
      root["valid"] = [1]

      assert_equal({ "valid" => [1] }, root.to_ruby)
    end
    assert_equal({ "valid" => [1] }, @db.snapshot.to_ruby)
  end

  def test_rescued_assignment_is_atomic
    @db.transaction do |root|
      root["items"] = [[1], [2]]
      items = root["items"]
      child = items[0]
      iterator = items.each

      assert_equal [1], iterator.next.to_ruby
      bound = items.context.read_bound
      error = assert_raises(XitDB::UnsupportedValueError) { items[0] = ["allocated" * 30, Object.new] }
      assert_equal ["items", 0, 1], error.path
      assert_equal bound, items.context.read_bound
      assert_equal [[1], [2]], items.to_ruby
      assert_equal [2], iterator.next.to_ruby
      child << 3

      assert_equal [[1, 3], [2]], items.to_ruby
    end
  end

  def test_separate_handles_to_the_same_file_capture_views_slices_and_concat
    Dir.mktmpdir do |directory|
      path = File.join(directory, "source.xit")
      alias_path = File.join(directory, "alias.xit")
      XitDB.open(path) do |source|
        source.transaction do |root|
          root["items"] = XitDB.linked_array
          root["items"].push([1], [2], [3])
        end
        File.link(path, alias_path)
        captured = source.snapshot["items"]
        source.transaction { |root| root["later"] = 1 }
        XitDB.open(alias_path) do |destination|
          destination.transaction do |root|
            root["copy"] = captured
            root["slice"] = captured[1, 1]
            root["copy"].concat(captured[2, 1])
            root["copy"][0] << 4
            root["items"][1] << 5

            assert_equal [[1], [2], [3]], captured.to_ruby
            assert_equal [[2]], root["slice"].to_ruby
          end
          assert_equal [[1, 4], [2], [3], [3]], destination.snapshot["copy"].to_ruby
          assert_equal [[1], [2, 5], [3]], destination.snapshot["items"].to_ruby
        end
      end
    end
  end

  def test_copied_files_with_identical_headers_reject_direct_references
    Dir.mktmpdir do |directory|
      path = File.join(directory, "source.xit")
      copy_path = File.join(directory, "copy.xit")
      XitDB.open(path) do |source|
        source.transaction { |root| root["items"] = [[1], [2]] }
        File.binwrite(copy_path, File.binread(path))
        XitDB.open(copy_path) do |destination|
          assert_equal source.core.header.to_bytes, destination.core.header.to_bytes
          destination.transaction do |root|
            bound = root.context.read_bound
            assert_raises(XitDB::ForeignValueError) { root["copy"] = source.snapshot["items"] }
            assert_raises(XitDB::ForeignValueError) { root["items"].concat(source.snapshot["items"]) }
            assert_equal bound, root.context.read_bound
            assert_equal({ "items" => [[1], [2]] }, root.to_ruby)
          end
          assert_equal 1, destination.history.size
        end
      end
    end
  end

  def test_same_inode_restore_rejects_a_stale_source_capture
    Dir.mktmpdir do |directory|
      path = File.join(directory, "source.xit")
      XitDB.open(path) do |source|
        source.transaction { |root| root["items"] = [[1]] }
        original = File.binread(path)
        captured = source.transaction { |root| root["items"] = [[2]] }["items"]
        File.binwrite(path, original)
        XitDB.open(path) do |destination|
          destination.transaction { |root| root["items"] = [[3]] }

          assert_equal source.core.header.to_bytes, destination.core.header.to_bytes
          assert_equal captured.context.read_bound, destination.snapshot.context.read_bound
          destination.transaction do |root|
            assert_raises(XitDB::ForeignValueError) { root["copy"] = captured }
            assert_equal({ "items" => [[3]] }, root.to_ruby)
          end
        end
        source.transaction do |root|
          assert_raises(XitDB::ForeignValueError) { root["copy"] = captured }
          assert_raises(XitDB::ForeignValueError) { root["slice"] = captured[0, 1] }
          assert_equal({ "items" => [[3]] }, root.to_ruby)
        end
      end
    end
  end

  def test_expired_source_views_cannot_enter_a_later_transaction
    expired = nil
    @db.transaction do |root|
      root["items"] = [[1]]
      expired = root["items"]
    end
    @db.transaction do |root|
      bound = root.context.read_bound
      assert_raises(XitDB::ExpiredViewError) { root["copy"] = expired }
      assert_equal bound, root.context.read_bound
      assert_equal({ "items" => [[1]] }, root.to_ruby)
    end
    assert_equal 1, @db.history.size
  end

  def test_logical_equality_and_inspection_do_not_expose_storage_identity
    key = "location" * 1000
    snapshot = @db.transaction do |root|
      root[key] = [["leaf"], ["leaf"]]
      root["shared"] = [root[key][0], root[key][0]]
    end
    view = snapshot[key]

    assert_equal view, snapshot["shared"]
    assert_equal view, [["leaf"], ["leaf"]] # rubocop:disable Minitest/LiteralAsActualArgument -- Exercise the view's equality implementation.
    refute_equal view, [["other"]]
    ruby = snapshot["shared"].to_ruby
    ruby[0][0] << " changed"

    assert_equal [["leaf changed"], ["leaf"]], ruby
    reads = 0
    trace = TracePoint.new(:call) do |event|
      reads += 1 if event.defined_class == XitDB::Core::Database && event.method_id == :read_at
    end
    description = trace.enable { view.inspect }

    assert_operator description.bytesize, :<, 300
    assert_equal 0, reads
  end
end
