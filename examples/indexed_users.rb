# frozen_string_literal: true

# Shows a user map with a sorted name index, rank lookup, and pagination.
# Prints the selected names as JSON.

require "xitdb"
require "json"

XitDB.memory do |db|
  db.transaction do |root|
    root["users"] = {}
    root["by_name"] = XitDB.sorted_map
    [%w[1 Ada], %w[2 Grace]].each do |id, name|
      root["users"][id] = { "name" => name }
      root["by_name"][name] = id
    end
  end
  snapshot = db.snapshot
  names = snapshot["by_name"].page(offset: 0, limit: 2).map do |_name, id|
    snapshot["users"][id]["name"]
  end
  raise "rank differs" unless snapshot["by_name"].rank("Grace") == 1
  raise "range differs" unless snapshot["by_name"].from("Grace").first == %w[Grace 2]

  puts JSON.generate(names: names)
end
