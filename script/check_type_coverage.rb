# frozen_string_literal: true

require "csv"
require "open3"

output, status = Open3.capture2(Gem.ruby, Gem.bin_path("steep", "steep"), "stats", "--format=csv", "-j", "2")
abort "Steep statistics failed" unless status.success?

rows = CSV.parse(output, headers: true)
expected = Dir.glob("lib/**/*.rb", sort: false).sort
actual = rows.map { |row| row.fetch("File") }.sort
abort "Steep must check every library file exactly once" unless actual == expected

failures = rows.reject do |row|
  row.fetch("Status") == "success" && Integer(row.fetch("Untyped calls")).zero? &&
    Integer(row.fetch("Typed calls")) == Integer(row.fetch("All calls"))
end
failures.each do |row|
  warn "#{row.fetch("File")}: #{row.fetch("Untyped calls")} untyped calls (#{row.fetch("Status")})"
end
abort "Type coverage must be 100% in every library file" unless failures.empty?

puts "100% typed calls across #{rows.size} library files"
