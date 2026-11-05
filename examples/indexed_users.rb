# frozen_string_literal: true

require "xitdb"
require "json"

XitDB.memory do |db|
  db.transaction do |root|
    root["users"] = {}
    root["by_name"] = XitDB.sorted_map
    [["1", "Ada"], ["2", "Grace"]].each do |id, name|
      root["users"][id] = {"name" => name}
      root["by_name"][name] = id
    end
  end
  snapshot = db.snapshot
  names = snapshot["by_name"].page(offset: 0, limit: 2).map do |_name, id|
    snapshot["users"][id]["name"]
  end
  raise "rank differs" unless snapshot["by_name"].rank("Grace") == 1
  raise "range differs" unless snapshot["by_name"].from("Grace").first == ["Grace", "2"]
  puts JSON.generate(names: names)
end
