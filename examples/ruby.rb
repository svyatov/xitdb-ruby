# frozen_string_literal: true

require "xitdb/ruby"
require "json"
require "tmpdir"
require "bigdecimal"
require "date"
require "set"

Money = Struct.new(:cents)
codec = XitDB::Ruby::Codec.new(id: "example/money/v1", type: Money,
  dump: ->(money) { money.cents.to_s }, load: ->(bytes) { Money.new(Integer(bytes)) })

Dir.mktmpdir("xitdb-ruby-") do |directory|
  XitDB::Ruby.memory(codecs: [codec]) do |db|
    instant = Time.at(Rational(1, 10**12)).utc
    db.transaction do |root|
      root[:enabled] = true
      root[:values] = [2**200, Rational(2, 3), BigDecimal("1.25"), Date.new(2026, 11, 4),
                       DateTime.new(2026, 11, 4), instant, "é".encode("UTF-16LE"), Money.new(125)]
      root[:keys] = {name: "symbol", "name" => "string", 1 => "integer", 1.0 => "float"}
      root[:members] = Set[:second, :first]
      root[:times] = XitDB.sorted_map(key: :time)
      root[:times][instant] = "created"
    end
    snapshot = db.snapshot
    raise "exact instant lost" unless snapshot[:values][5].to_r == instant.to_r
    raise "codec differs" unless snapshot[:values][7].cents == 125
    raise "key identity lost" unless snapshot[:keys].size == 4
    raise "set order lost" unless snapshot[:members].to_a == [:second, :first]
    raise "time lookup differs" unless snapshot[:times].from(instant).first.last == "created"

    XitDB::Ruby.memory(codecs: [codec]) do |copy|
      copy.transaction { |root| root.context.copy_from(snapshot[:values], at: [:copied]) }
      raise "cross-file copy differs" unless copy.snapshot[:copied][0] == 2**200
    end
    # Convert a representable subset with an explicit key/value transform.
    XitDB::Ruby.memory do |source|
      source.transaction { |root| root[:enabled] = true }
      portable = source.convert(to: File.join(directory, "portable.xit"), profile: :portable, history: :latest,
        transform: ->(value:, role:, path:) { role == :key ? value.to_s : (value == true ? 1 : value) })
      begin
        raise "conversion differs" unless portable.snapshot["enabled"] == 1
      ensure
        portable.close
      end
    end
    puts JSON.generate(enabled: snapshot[:enabled])
  end
end
