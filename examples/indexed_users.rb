# frozen_string_literal: true

# Keep user records and a nonunique name index in the same transaction.
require "xitdb"
require "json"
require "tmpdir"

# Hex digits preserve name byte order. The separator sorts before every hex
# digit, so shorter names sort first. The remaining raw ID bytes break ties.
def name_prefix(name)
  "#{name.unpack1("H*")}!"
end

def name_key(name, id)
  name_prefix(name) + id.b
end

def rename_user(root, id, name)
  user = root["users"].fetch(id)
  root["by_name"].delete(name_key(user.fetch("name"), id))
  user["name"] = name
  root["by_name"][name_key(name, id)] = id
end

def rebuild_index(root)
  root["by_name"] = XitDB.sorted_map
  root["users"].each do |id, user|
    root["by_name"][name_key(user.fetch("name"), id)] = id
  end
end

Dir.mktmpdir("xitdb-users-") do |directory|
  path = File.join(directory, "users.xit")
  XitDB.open(path) do |db|
    db.transaction do |root|
      root["users"] = { "1" => { "name" => "Ada" }, "2" => { "name" => "Grace" }, "3" => { "name" => "Ada" } }
      rebuild_index(root)
    end
  end

  XitDB.open(path) do |db|
    before = db.snapshot
    index = before["by_name"]
    prefix = name_prefix("Ada")
    ada_ids = index.from(prefix).take_while { |key, _id| key.start_with?(prefix) }.map(&:last)
    raise "rank differs" unless index.rank(name_key("Grace", "2")) == 2

    first_page = index.page(offset: 0, limit: 2).map { |_key, id| id }
    db.transaction do |root|
      rename_user(root, "3", "Grace")
      user = root["users"].fetch("2")
      root["by_name"].delete(name_key(user.fetch("name"), "2"))
      root["users"].delete("2")
    end
    # Read the next page from the same snapshot, even after the edits.
    paged_ids = first_page + index.page(offset: 2, limit: 2).map { |_key, id| id }

    catch(:cancel) do
      db.transaction do |root|
        rename_user(root, "1", "Eve")
        throw :cancel
      end
    end

    snapshot = db.snapshot
    users = snapshot["by_name"].map do |key, id|
      name = snapshot["users"].fetch(id).fetch("name")
      raise "stale index entry" unless key == name_key(name, id)

      [id, name]
    end
    raise "missing index entry" unless users.size == snapshot["users"].size

    puts JSON.generate(ada_ids: ada_ids, paged_ids: paged_ids, users_after_edits: users, names: users.map(&:last))
  end
end
