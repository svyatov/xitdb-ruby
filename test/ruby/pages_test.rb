# frozen_string_literal: true

require "test_helper"
require "xitdb/ruby"
require "tmpdir"

# Public behavior of bounded typed pages, including generic storage transitions.
class RubyPagesTest < Minitest::Test
  Payload = Struct.new(:text)

  def test_flat_rows_use_pages_across_page_boundaries
    [32, 1024, 1025, 2050].each do |count|
      XitDB::Ruby.memory do |database|
        rows = fixture(count)
        database.transaction { |root| root["rows"] = rows }
        array = database.snapshot["rows"]

        assert_equal "rb04", database.core.header.hash_id
        assert_equal 7, metadata(array)
        assert_equal count, array.size
        assert_equal rows, array.to_ruby
        [0, count / 2, count - 1].each do |index|
          assert_equal rows[index], array[index].to_ruby
          assert_equal rows[index]["name"], array[index]["name"]
        end
        assert_equal rows.last, array[-1].to_ruby
        assert_equal rows.drop(count - 2), array[count - 2, 2].map(&:to_ruby)
        assert_nil array[count]
      end
    end
  end

  def test_rewrites_one_page_without_changing_snapshots
    Dir.mktmpdir("xitdb-pages-") do |directory|
      path = File.join(directory, "data")
      rows = fixture(2050)
      XitDB::Ruby.open(path) do |database|
        database.transaction { |root| root["rows"] = rows }
        snapshot = database.snapshot
        old_row = snapshot["rows"][1024]
        before = File.size(path)
        database.transaction { |root| root["rows"][1024]["name"] = "changed" }

        assert_operator File.size(path) - before, :<, 75_000
        assert_equal rows[1024], old_row.to_ruby
        assert_equal rows, snapshot["rows"].to_ruby
        assert_equal "changed", database.snapshot["rows"][1024]["name"]
        assert_equal 7, metadata(database.snapshot["rows"])
        rows[1024]["name"] = "changed"
        database.transaction do |root|
          root["copy"] = root["rows"][1025]
          root["rows"][0]["extra"] = :symbol
        end
        rows[0]["extra"] = :symbol
        compact = database.compact(to: File.join(directory, "compact"))
        begin
          assert_equal rows, compact.snapshot["rows"].to_ruby
          assert_equal rows[1025], compact.snapshot["copy"].to_ruby
        ensure
          compact.close
        end
      end

      XitDB::Ruby.open(path, readonly: true) do |database|
        assert_equal rows, database.snapshot["rows"].to_ruby
      end
    end
  end

  def test_mixed_pages_preserve_nested_values_and_order
    XitDB::Ruby.memory do |database|
      rows = fixture(2050)
      database.transaction { |root| root["rows"] = rows }
      database.transaction do |root|
        root["rows"][1024]["nested"] = { a: [1, 2] }
        rows[1024]["nested"] = { a: [1, 2] }
        root["rows"][0] = [nil, :symbol]
        rows[0] = [nil, :symbol]
        root["rows"][2049]["active"] = false
        rows[2049]["active"] = false

        assert_equal rows, root["rows"].to_ruby
        assert_equal rows[1024].keys, root["rows"][1024].to_ruby.keys
        root["rows"][1024].delete("name")
        rows[1024].delete("name")
        root["rows"][1025].clear
        rows[1025] = {}

        assert_equal rows, root["rows"].to_ruby
      end
      assert_equal rows, database.snapshot["rows"].to_ruby
    end
  end

  def test_numeric_update_avoids_storing_an_intermediate_map
    XitDB::Ruby.memory do |database|
      rows = fixture(32)
      database.transaction { |root| root["rows"] = rows }
      old = database.snapshot
      before = database.core.root_cursor.bound
      database.transaction { |root| root["rows"][16]["id"] = 123 }
      expected = rows.map(&:dup)
      expected[16]["id"] = 123
      page_size = XitDB::Ruby::PageCodec.encode_page(expected).bytesize

      assert_operator database.core.root_cursor.bound - before, :<=, page_size + 450
      assert_equal expected, database.snapshot["rows"].to_ruby
      assert_equal rows, old["rows"].to_ruby
    end
  end

  def test_numeric_page_update_has_bounded_allocation_cost
    XitDB::Ruby.memory do |database|
      database.transaction { |root| root["rows"] = fixture(1000) }
      snapshot = database.snapshot
      GC.start
      before = GC.stat(:total_allocated_objects)
      database.transaction { |root| root["rows"][500]["id"] = 123 }
      allocated = GC.stat(:total_allocated_objects) - before

      assert_operator allocated, :<, 100_000
      assert_equal 123, database.snapshot["rows"][500]["id"]
      assert_equal 500, snapshot["rows"][500]["id"]
    end
  end

  def test_chained_numeric_edits_promote_and_rollback_without_losing_values
    Dir.mktmpdir("xitdb-row-edits-") do |directory|
      path = File.join(directory, "data")
      rows = fixture(32)
      expected = nil
      XitDB::Ruby.open(path) do |database|
        database.transaction { |root| root["rows"] = rows }
        database.transaction do |root|
          root["copy"] = root["rows"][0]
          root["copy"]["id"] = 9
          root["rows"][1].merge!({ "id" => 2**63, "score" => -0.0, "name" => "changed", "extra" => nil })
          root["rows"][2].merge!({ "id" => nil, "score" => 3.5 })

          assert_equal 9, root["copy"]["id"]
          assert_equal rows[0], root["rows"][0].to_ruby
          assert_equal rows[1].merge("id" => 2**63, "score" => -0.0, "name" => "changed", "extra" => nil),
                       root["rows"][1].to_ruby
          assert_equal rows[2].merge("id" => nil, "score" => 3.5), root["rows"][2].to_ruby
        end
        snapshot = database.snapshot
        expected = snapshot.to_ruby
        assert_raises(RuntimeError) do
          database.transaction do |root|
            root["rows"][3]["score"] = 123
            root["copy"]["score"] = 321
            raise "rollback"
          end
        end
        assert_equal expected, database.snapshot.to_ruby
        assert_equal expected, snapshot.to_ruby
        compact = database.compact(to: File.join(directory, "compact"))
        begin
          assert_equal expected, compact.snapshot.to_ruby
        ensure
          compact.close
        end
      end

      XitDB::Ruby.open(path) { |database| assert_equal expected, database.snapshot.to_ruby }
    end
  end

  def test_numeric_update_of_a_persisted_row_reference_root
    XitDB::Ruby.memory do |database|
      rows = fixture(32)
      database.transaction { |root| root["rows"] = rows }
      reference = database.snapshot["rows"][0].slot
      database.core.transaction do |cursor|
        context = XitDB::Context.new(database: database, root: XitDB::Core::Slot.new, bound: cursor.bound,
                                     transaction: cursor.transaction)
        stored = XitDB::Ruby::Pages.persist(reference, context)
        XitDB::Core::ArrayList.new(cursor).append(stored)
      end
      snapshot = database.snapshot

      assert_equal rows[0], snapshot.to_ruby
      database.transaction { |root| root["id"] = 123 }

      assert_equal rows[0].merge("id" => 123), database.snapshot.to_ruby
      assert_equal rows[0], snapshot.to_ruby
    end
  end

  def test_shape_changes_slices_concat_and_captured_row_assignment
    XitDB::Ruby.memory do |database|
      rows = fixture(33)
      database.transaction { |root| root["rows"] = rows }
      old = database.snapshot["rows"]
      database.transaction do |root|
        root["copy"] = old[31]
        root["slice"] = old[30, 3]
        root["slice"].concat(old[0, 2])
        root["rows"].push({ "new" => 1 })
        root["rows"].insert(2, :inserted)
        root["rows"].delete_at(0)
        expected = rows.dup
        expected.push({ "new" => 1 })
        expected.insert(2, :inserted)
        expected.delete_at(0)

        assert_equal expected, root["rows"].to_ruby
        assert_equal rows[31], root["copy"].to_ruby
        assert_equal rows[30, 3] + rows[0, 2], root["slice"].to_ruby
        root["rows"].pop(root["rows"].size)

        assert_empty root["rows"]
        root["rows"].push(1)
        root["rows"].clear

        assert_empty root["rows"]
      end
      assert_equal rows, old.to_ruby
    end
  end

  def test_transaction_references_follow_changes_then_expire
    XitDB::Ruby.memory do |database|
      rows = fixture(32)
      database.transaction { |root| root["rows"] = rows }
      old = database.snapshot["rows"][1]
      live = nil
      assert_raises(RuntimeError) do
        database.transaction do |root|
          live = root["rows"][1]
          root["rows"][1]["id"] = -1

          assert_equal(-1, live["id"])
          assert_equal 1, old["id"]
          raise "rollback"
        end
      end
      assert_raises(XitDB::ExpiredViewError) { live.to_ruby }
      assert_equal rows, database.snapshot["rows"].to_ruby
      database.transaction do |root|
        live = root["rows"][1]
        root["rows"][1]["id"] = -2

        assert_equal(-2, live["id"])
        root["rows"].insert(0, {})
        assert_raises(XitDB::ExpiredViewError) { live.to_ruby }
      end
      assert_equal rows[1], old.to_ruby
      database.close
      assert_raises(XitDB::ClosedError) { old.to_ruby }
    end
  end

  def test_row_reference_identity_and_empty_merge_preserve_history
    XitDB::Ruby.memory do |database|
      rows = fixture(32)
      database.transaction { |root| root["rows"] = rows }
      snapshot = database.snapshot
      first = snapshot["rows"][0]

      assert_equal first.slot, snapshot["rows"][0].slot
      refute_equal first.slot, snapshot["rows"][1].slot
      refute_equal first.slot, snapshot["rows"].slot
      before = database.core.root_cursor.bound
      revisions = database.history.size
      database.transaction { |root| root["rows"][0].merge!({}) }

      assert_equal before, database.core.root_cursor.bound
      assert_equal revisions, database.history.size
      assert_equal rows, database.snapshot["rows"].to_ruby
      assert_equal rows.first, first.to_ruby
    end
  end

  def test_fallback_and_failure_after_an_encoded_page_leave_no_partial_value
    XitDB::Ruby.memory do |database|
      rows = fixture(1025)
      rows.last["name"] = "x" * 70_000
      database.transaction do |root|
        root["rows"] = rows

        assert_equal rows, root["rows"].to_ruby
        refute_equal 7, metadata(root["rows"])
        invalid = fixture(1025)
        invalid.last["name"] = Object.new
        before = root.context.transaction.length
        assert_raises(XitDB::UnsupportedValueError) { root["rows"] = invalid }
        assert_equal before, root.context.transaction.length
        assert_equal rows, root["rows"].to_ruby
        root["rows"] = fixture(32)

        assert_equal 7, metadata(root["rows"])
      end
    end
  end

  def test_copy_and_conversion_read_page_scalars
    XitDB::Ruby.memory do |source|
      rows = fixture(32)
      rows.each { |row| row["active"] = nil }
      source.transaction { |root| root["rows"] = rows }
      [XitDB, XitDB::Ruby].each do |factory|
        factory.memory do |destination|
          destination.transaction do |root|
            root.context.copy_from(source.snapshot["rows"], at: ["copy"])
          end

          assert_equal rows, destination.snapshot["copy"].to_ruby
        end
      end
    end
  end

  def test_streamed_byte_replacement_promotes_without_changing_other_rows
    XitDB::Ruby.memory do |database|
      rows = fixture(32)
      database.transaction { |root| root["rows"] = rows }
      old = database.snapshot["rows"]
      database.transaction do |root|
        row = root["rows"][0]
        row.write_bytes("name") { |writer| writer.write("raw bytes") }

        assert_equal "raw bytes", row.open_bytes("name", &:read)
        row.open_bytes("name") do
          assert_raises(XitDB::ConcurrentModificationError) { row["name"] = "blocked" }
        end
        assert_equal rows[1], root["rows"][1].to_ruby
      end
      assert_equal rows, old.to_ruby
      assert_equal "raw bytes", database.snapshot["rows"][0].open_bytes("name", &:read)
    end
  end

  def test_empty_rows_and_deep_fallback_keep_iterative_traversal
    XitDB::Ruby.memory do |database|
      empty_rows = Array.new(32) { {} }
      nested = fixture(32)
      1200.times { nested = [nested] }
      database.transaction do |root|
        root["empty"] = empty_rows
        root["deep"] = nested

        assert_equal 7, metadata(root["empty"])
        assert_equal empty_rows, root["empty"].to_ruby
        root["copy"] = root["empty"][0]

        assert_equal({}, root["copy"].to_ruby)
        output = root["deep"].to_ruby
        1200.times { output = output.fetch(0) }

        assert_equal fixture(32), output
      end
    end
  end

  def test_rejects_malformed_page_array_descriptors
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        context = root.context
        page = database.core.bytes(XitDB::Ruby::PageCodec.encode_page(fixture(32)))
        list = XitDB::Core::ArrayList.new(context.cursor(XitDB::Core::Slot.new), fields: [page]).cursor.slot
        variants = [[], [XitDB::Core::Slot.uint(32)], [XitDB::Core::Slot.int(32), list],
                    [XitDB::Core::Slot.uint(0), list], [XitDB::Core::Slot.uint(1025), list],
                    [XitDB::Core::Slot.new(tag: :uint, value: 32, full: true), list]]
        variants.each do |fields|
          stored = XitDB::Core::Record.append(context.writable_transaction!, metadata: 7, fields: fields)
          install_slot(root, "bad", stored)

          assert_raises(XitDB::InvalidValueError) { root["bad"].to_ruby }
        end
      end
    end
  end

  def test_hash_callback_that_resizes_outer_array_cannot_publish_an_invalid_page
    rows = fixture(32)
    target = rows.first
    original = Hash.instance_method(:default)
    changed = false
    Hash.define_method(:default) do |*arguments|
      if equal?(target) && !changed
        changed = true
        rows.pop
      end
      original.bind_call(self, *arguments)
    end
    XitDB::Ruby.memory do |database|
      database.transaction { |root| root["rows"] = rows }

      assert changed
      assert_equal 31, rows.size
      assert_equal rows, database.snapshot["rows"].to_ruby
    end
  ensure
    Hash.define_method(:default, original) if original
  end

  def test_rejects_malformed_persisted_row_references
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        context = root.context
        page = database.core.bytes(XitDB::Ruby::PageCodec.encode_page(fixture(32)))
        uint = XitDB::Core::Slot.method(:uint)
        variants = [[page, uint.call(0)], [page, uint.call(32), uint.call(32)],
                    [page, uint.call(0), uint.call(31)], [page, uint.call(0), uint.call(1025)],
                    [page, XitDB::Core::Slot.int(0), uint.call(32)],
                    [page, uint.call(0), XitDB::Core::Slot.new(tag: :uint, value: 32, full: true)]]
        variants.each do |fields|
          stored = XitDB::Core::Record.append(context.writable_transaction!, metadata: 8, fields: fields)
          install_slot(root, "bad", stored)

          assert_raises(XitDB::InvalidValueError) { root["bad"].to_ruby }
        end
      end
    end
  end

  def test_rejects_tagged_oversized_mismatched_and_recursive_pages
    XitDB::Ruby.memory do |database|
      database.transaction do |root|
        context = root.context
        payload = XitDB::Ruby::PageCodec.encode_page(fixture(32))
        page = database.core.bytes(payload)
        nested = page_array_slot(context, page, 32)
        short = XitDB::Core::Record.append(context.writable_transaction!, metadata: 2,
                                                                          fields: [XitDB::Core::Slot.null])
        [database.core.bytes(payload, format_tag: "rb"), database.core.bytes("x" * 65_537),
         database.core.bytes("XP00"), nested, short].each do |invalid|
          install_slot(root, "bad", page_array_slot(context, invalid, 32))

          assert_raises(XitDB::InvalidValueError) { root["bad"].to_ruby }
          assert_raises(XitDB::InvalidValueError) { root["bad"][0].to_ruby }
        end
        install_slot(root, "bad", page_array_slot(context, page, 31))

        assert_raises(XitDB::InvalidValueError) { root["bad"].to_ruby }
        assert_raises(XitDB::InvalidValueError) { root["bad"][0].to_ruby }
        flagged = XitDB::Core::Slot.new(tag: :record, value: nested.value, full: true)
        install_slot(root, "bad", flagged)

        assert_raises(XitDB::InvalidValueError) { root["bad"].to_ruby }
      end
    end
  end

  def test_page_values_preserve_float_bits_encodings_and_independent_strings
    nan = ["7ff8000000000123"].pack("H*").unpack1("G")
    key = "\xFF".b.freeze
    rows = Array.new(32) { { key => "\xFF".dup.force_encoding(Encoding::UTF_8), "float" => nan } }
    XitDB::Ruby.memory do |database|
      database.transaction { |root| root["rows"] = rows }
      view = database.snapshot["rows"]
      output = view.to_ruby

      assert_equal 7, metadata(view)
      assert_equal Encoding::ASCII_8BIT, output.first.keys.first.encoding
      assert_equal Encoding::UTF_8, output.first[key].encoding
      refute_predicate output.first[key], :valid_encoding?
      assert_equal [nan].pack("G"), [output.first["float"]].pack("G")
      assert_equal [nan].pack("G"), [view[0]["float"]].pack("G")
      assert_predicate view[0][key], :frozen?
      refute_predicate output.first[key], :frozen?
      output.first[key].replace("changed")

      assert_equal "\xFF".b, view[0][key].b
      assert_equal "\xFF".b, output.last[key].b
      assert_equal Encoding::ASCII_8BIT, view[0].to_ruby.keys.first.encoding
    end
  end

  def test_page_update_preserves_application_payload_without_loading_it
    loads = 0
    loader = lambda do |bytes|
      loads += 1
      "decoded #{bytes}"
    end
    codec = XitDB::Ruby::Codec.new(id: "page/payload/v1", type: Payload, dump: lambda(&:text), load: loader)
    Dir.mktmpdir("xitdb-page-codec-") do |directory|
      path = File.join(directory, "data")
      XitDB::Ruby.open(path, codecs: [codec]) do |database|
        database.transaction { |root| root["rows"] = fixture(32) }
        database.transaction { |root| root["rows"][0]["name"] = Payload.new("payload") }

        assert_equal 0, loads
        assert_equal "decoded payload", database.snapshot["rows"][0]["name"]
        assert_equal 1, loads
      end
      XitDB::Ruby.open(path, readonly: true) do |database|
        value = database.snapshot["rows"][0]["name"]

        assert_instance_of XitDB::Ruby::EncodedValue, value
        assert_equal "page/payload/v1", value.codec_id
      end
    end
  end

  private

  def page_array_slot(context, page, count)
    list = XitDB::Core::ArrayList.new(context.cursor(XitDB::Core::Slot.new), fields: [page]).cursor.slot
    XitDB::Core::Record.append(context.writable_transaction!, metadata: 7,
                                                              fields: [XitDB::Core::Slot.uint(count), list])
  end

  def install_slot(root, key, stored)
    root.context.mutate([]) do |cursor|
      adapter = root.context.collection(cursor.slot, path: [])
      adapter.assign(key, stored)
      cursor.replace(adapter.slot)
    end
  end

  def fixture(count)
    Array.new(count) { |index| { "id" => index, "name" => "row-#{index}", "active" => true, "score" => index / 2.0 } }
  end

  def metadata(view)
    XitDB::Core::Record.read(view.context.database.core, view.slot, bound: view.context.read_bound).metadata
  end
end
