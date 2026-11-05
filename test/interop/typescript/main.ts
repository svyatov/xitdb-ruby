import * as fs from "node:fs";
import { pathToFileURL } from "node:url";

const x = await import(pathToFileURL(`${process.env.XITDB_REFERENCE}/src/index.ts`).href);
const request = JSON.parse(fs.readFileSync(0, "utf8"));
const algorithms: Record<string, [number, string]> = {sha1: [20, "SHA-1"], rb01: [32, "SHA-256"], s384: [48, "SHA-384"]};
const algorithm = algorithms[request.hash.id];
if (!algorithm || algorithm[0] !== request.hash.size) throw new Error("unsupported hash");
if (request.case !== "all-kinds") throw new Error("unsupported case");
const kinds = ["array_list", "linked_array_list", "hash_map", "hash_set", "counted_hash_map", "counted_hash_set", "sorted_map", "sorted_set"];
const tags = ["none", "index", "array_list", "linked_array_list", "hash_map", "kv_pair", "bytes", "short_bytes", "uint", "int", "float", "hash_set", "counted_hash_map", "counted_hash_set", "sorted_map", "sorted_set", "sorted_kv_pair"];
const hex = (value: Uint8Array) => Buffer.from(value).toString("hex");
const numbers: object[] = [];
const iteration: number[] = [];

function scalar(value: any) {
  if (value.hex !== undefined) return new x.Bytes(Buffer.from(value.hex, "hex"), value.format_tag === null ? null : Buffer.from(value.format_tag, "hex"));
  if (value.tag === "uint") return new x.Uint(BigInt(value.bits));
  if (value.tag === "int") return new x.Int(BigInt.asIntN(64, BigInt(value.bits)));
  return new x.Slot(BigInt(value.bits), tags.indexOf(value.tag), value.full);
}

function tree(cursor: any): any {
  const slot = cursor.slot();
  const tag = tags[slot.tag];
  if (!kinds.includes(tag)) {
    if (tag === "bytes" || tag === "short_bytes") {
      const bytes = cursor.readBytesObject();
      return {tag, full: slot.full, hex: hex(bytes.value), format_tag: bytes.formatTag === null ? null : hex(bytes.formatTag)};
    }
    const bits = BigInt.asUintN(64, slot.value).toString();
    if (tag === "int" || tag === "uint") {
      try {
        numbers.push({tag, bits, number: String(tag === "int" ? cursor.readInt() : cursor.readUint())});
      } catch (error) {
        numbers.push({tag, bits, error: (error as Error).constructor.name});
      }
    }
    return {tag, full: slot.full, bits};
  }
  const items = [];
  if (tag.endsWith("list")) {
    const list = tag === "array_list" ? new x.ReadArrayList(cursor) : new x.ReadLinkedArrayList(cursor);
    const iterator = cursor.iterator();
    let returned = 0;
    while (iterator.next() !== null) returned++;
    iteration.push(returned);
    for (let i = 0; i < list.count(); i++) {
      const child = list.getCursor(i);
      items.push(child === null ? {tag: "none", full: false, bits: "0"} : tree(child));
    }
    return {tag, items};
  }
  const iterator = cursor.iterator();
  let child;
  while ((child = iterator.next()) !== null) {
    if (tag === "sorted_set") items.push([hex(child.readBytes()), null]);
    else {
      const pair = child.readKeyValuePair();
      items.push([hex(pair.keyCursor.readBytes()), tag.endsWith("set") ? null : tree(pair.valueCursor)]);
    }
  }
  items.sort((a, b) => a[0].localeCompare(b[0]));
  return {tag, items};
}

function populate(db: any) {
  const history = new x.WriteArrayList(db.rootCursor());
  history.append(new x.Uint(7n));
  const first = db.committedSize();
  history.appendContext(null, (cursor: any) => {
    const list = new x.WriteArrayList(cursor);
    for (const value of request.scalars) list.append(scalar(value));
    for (const kind of kinds) {
      for (const count of [0, 17]) {
        const child = list.appendCursor();
        const classes: Record<string, any> = {
          array_list: x.WriteArrayList, linked_array_list: x.WriteLinkedArrayList,
          hash_map: x.WriteHashMap, hash_set: x.WriteHashSet,
          counted_hash_map: x.WriteCountedHashMap, counted_hash_set: x.WriteCountedHashSet,
          sorted_map: x.WriteSortedMap, sorted_set: x.WriteSortedSet,
        };
        const collection = new classes[kind](child);
        for (let i = 0; i < count; i++) {
          const key = `k${String(i).padStart(2, "0")}`;
          if (kind.endsWith("list")) {
            if (i === 0) {
              if (collection.appendCursor().slot().empty() !== (kind === "array_list")) throw new Error("unexpected append cursor occupancy");
            } else collection.append(i === 1 ? new x.Slot(0n, 0, false) : new x.Uint(i));
          }
          else if (kind.endsWith("set")) collection.put(key);
          else collection.put(key, new x.Uint(i));
        }
      }
    }
  });
  for (const [suffix, start, end] of [["base", 0, first], ["delta", first, db.committedSize()]] as const) {
    const chunks: Uint8Array[] = [];
    db.readCommitted(start, end, {write: (chunk: Uint8Array) => chunks.push(chunk.slice())});
    fs.writeFileSync(`${request.path}.${suffix}`, Buffer.concat(chunks));
  }
}

function reader(bytes: Uint8Array) {
  let offset = 0;
  return {readFully: (target: Uint8Array) => {
    if (offset + target.length > bytes.length) throw new Error("interrupted transport");
    target.set(bytes.subarray(offset, offset + target.length));
    offset += target.length;
  }};
}

using core = new x.CoreFile(request.path);
const db = new x.Database(core, new x.Hasher(algorithm[1], x.Hasher.stringToId(request.hash.id)), 1n);
let result;
switch (request.operation) {
  case "write":
    populate(db);
    result = {tree: tree(db.rootCursor()), numbers, iteration};
    break;
  case "read":
    result = {tree: tree(db.rootCursor()), numbers, iteration};
    break;
  case "compact": {
    using target = new x.CoreFile(`${request.path}.compact`);
    const compacted = db.compact(target);
    result = {size: String(compacted.committedSize())};
    break;
  }
  case "replicate": {
    using target = new x.CoreFile(`${request.path}.replica`);
    const replica = new x.Database(target, db.hasher);
    const base = fs.readFileSync(`${request.path}.base`);
    const delta = fs.readFileSync(`${request.path}.delta`);
    replica.applyReplicated(0, reader(base), base.length);
    const before = replica.replicaState();
    if (db.replicationStart(before) !== base.length) throw new Error("prefix proof failed");
    const interrupted = replica.openReplicated(base.length, delta.length);
    interrupted.write(delta.subarray(0, Math.floor(delta.length / 2)));
    let rejected = false;
    try { interrupted.close(); } catch (error) {
      if (!(error instanceof x.EndOfStreamException)) throw error;
      rejected = true;
    }
    if (!rejected || replica.replicaState().checksum !== before.checksum || replica.committedSize() !== before.committedSize) throw new Error("interrupted replica published");
    replica.applyReplicated(base.length, reader(delta), delta.length);
    for (const [suffix, start, end] of [["base", 0, base.length], ["delta", base.length, db.committedSize()]] as const) {
      const chunks: Uint8Array[] = [];
      db.readCommitted(start, end, {write: (chunk: Uint8Array) => chunks.push(chunk.slice())});
      fs.writeFileSync(`${request.path}.reference.${suffix}`, Buffer.concat(chunks));
    }
    result = {interrupted: rejected, size: String(replica.committedSize()), checksum: replica.replicaState().checksum.toString()};
    break;
  }
  default: throw new Error("unsupported operation");
}
console.log(JSON.stringify(result));
