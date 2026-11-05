import io.github.radarroark.xitdb.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;

@SuppressWarnings("unchecked")
public class Main {
    static final List<String> KINDS = List.of("array_list", "linked_array_list", "hash_map", "hash_set", "counted_hash_map", "counted_hash_set", "sorted_map", "sorted_set");
    static final HexFormat HEX = HexFormat.of();
    static final List<Object> NUMBERS = new ArrayList<>();
    static final List<Integer> ITERATION = new ArrayList<>();
    static final List<String> WRITER_REJECTIONS = new ArrayList<>();

    static Map<String, Object> object(Object value) { return (Map<String, Object>) value; }
    static String string(Map<String, Object> value, String key) { return (String) value.get(key); }

    static Database.WriteableData scalar(Map<String, Object> value) throws Exception {
        if (value.containsKey("hex")) return new Database.Bytes(HEX.parseHex(string(value, "hex")), value.get("format_tag") == null ? null : HEX.parseHex(string(value, "format_tag")));
        long bits = Long.parseUnsignedLong(string(value, "bits"));
        return switch (string(value, "tag")) {
            case "uint" -> bits < 0 ? highUint(bits) : new Database.Uint(bits);
            case "int" -> new Database.Int(bits);
            default -> new Slot(bits, Tag.valueOf(string(value, "tag").toUpperCase(Locale.ROOT)), (boolean) value.get("full"));
        };
    }

    static Slot highUint(long bits) throws Exception {
        var probe = new Database(new CoreMemory(new RandomAccessMemory()), new Hasher(MessageDigest.getInstance("SHA-1")));
        try {
            probe.rootCursor().write(new Database.Uint(bits));
            throw new AssertionError("pinned Uint writer unexpectedly accepted high unsigned value");
        } catch (IllegalArgumentException error) {
            if (!error.getMessage().equals("Uint must not be negative")) throw error;
            WRITER_REJECTIONS.add(Long.toUnsignedString(bits));
        }
        return new Slot(bits, Tag.UINT, false);
    }

    static Object tree(ReadCursor cursor) throws Exception {
        var slot = cursor.slot();
        var tag = slot.tag().name().toLowerCase(Locale.ROOT);
        if (!KINDS.contains(tag)) {
            var result = new LinkedHashMap<String, Object>();
            result.put("tag", tag);
            result.put("full", slot.full());
            if (tag.equals("bytes") || tag.equals("short_bytes")) {
                var bytes = cursor.readBytesObject(null);
                result.put("hex", HEX.formatHex(bytes.value()));
                result.put("format_tag", bytes.formatTag() == null ? null : HEX.formatHex(bytes.formatTag()));
            } else {
                var bits = Long.toUnsignedString(slot.value());
                result.put("bits", bits);
                if (tag.equals("int") || tag.equals("uint")) {
                    try {
                        NUMBERS.add(Map.of("tag", tag, "bits", bits, "number", Long.toString(tag.equals("int") ? cursor.readInt() : cursor.readUint())));
                    } catch (Database.ExpectedUnsignedLongException error) {
                        NUMBERS.add(Map.of("tag", tag, "bits", bits, "error", error.getClass().getSimpleName()));
                    }
                }
            }
            return result;
        }
        var items = new ArrayList<Object>();
        if (tag.endsWith("list")) {
            var iterator = cursor.iterator();
            int returned = 0;
            while (iterator.next() != null) returned++;
            ITERATION.add(returned);
            for (long i = 0; i < cursor.count(); i++) {
                var child = tag.equals("array_list") ? new ReadArrayList(cursor).getCursor(i) : new ReadLinkedArrayList(cursor).getCursor(i);
                items.add(child == null ? Map.of("tag", "none", "full", false, "bits", "0") : tree(child));
            }
            return Map.of("tag", tag, "items", items);
        }
        var iterator = cursor.iterator();
        ReadCursor child;
        while ((child = iterator.next()) != null) {
            if (tag.equals("sorted_set")) items.add(Arrays.asList(HEX.formatHex(child.readBytes(null)), null));
            else {
                var pair = child.readKeyValuePair();
                items.add(Arrays.asList(HEX.formatHex(pair.keyCursor.readBytes(null)), tag.endsWith("set") ? null : tree(pair.valueCursor)));
            }
        }
        items.sort(Comparator.comparing(item -> (String) ((List<?>) item).get(0)));
        return Map.of("tag", tag, "items", items);
    }

    static void populate(Database db, Map<String, Object> request, String path) throws Exception {
        var history = new WriteArrayList(db.rootCursor());
        history.append(new Database.Uint(7));
        long first = db.committedSize();
        history.appendContext(null, cursor -> {
            var list = new WriteArrayList(cursor);
            for (var value : (List<Object>) request.get("scalars")) list.append(scalar(object(value)));
            for (var kind : KINDS) {
                for (int count : new int[]{0, 17}) {
                    var child = list.appendCursor();
                    switch (kind) {
                        case "array_list" -> {
                            var collection = new WriteArrayList(child);
                            for (int i = 0; i < count; i++) {
                                if (i == 0) {
                                    if (!collection.appendCursor().slot().empty()) throw new AssertionError("unexpected array append cursor occupancy");
                                } else collection.append(i == 1 ? new Slot(0, Tag.NONE, false) : new Database.Uint(i));
                            }
                        }
                        case "linked_array_list" -> {
                            var collection = new WriteLinkedArrayList(child);
                            for (int i = 0; i < count; i++) {
                                if (i == 0) {
                                    if (collection.appendCursor().slot().empty()) throw new AssertionError("unexpected linked append cursor occupancy");
                                } else collection.append(i == 1 ? new Slot(0, Tag.NONE, false) : new Database.Uint(i));
                            }
                        }
                        case "hash_map", "counted_hash_map" -> {
                            var collection = kind.equals("hash_map") ? new WriteHashMap(child) : new WriteCountedHashMap(child);
                            for (int i = 0; i < count; i++) collection.put("k%02d".formatted(i), new Database.Uint(i));
                        }
                        case "hash_set", "counted_hash_set" -> {
                            var collection = kind.equals("hash_set") ? new WriteHashSet(child) : new WriteCountedHashSet(child);
                            for (int i = 0; i < count; i++) collection.put("k%02d".formatted(i));
                        }
                        case "sorted_map" -> {
                            var collection = new WriteSortedMap(child);
                            for (int i = 0; i < count; i++) collection.put("k%02d".formatted(i), new Database.Uint(i));
                        }
                        case "sorted_set" -> {
                            var collection = new WriteSortedSet(child);
                            for (int i = 0; i < count; i++) collection.put("k%02d".formatted(i));
                        }
                    }
                }
            }
        });
        try (var output = Files.newOutputStream(Path.of(path + ".base"))) { db.readCommitted(0, first, output); }
        try (var output = Files.newOutputStream(Path.of(path + ".delta"))) { db.readCommitted(first, db.committedSize(), output); }
    }

    public static void main(String[] args) throws Exception {
        var request = object(new Json(new String(System.in.readAllBytes(), StandardCharsets.UTF_8)).parse());
        if (!string(request, "case").equals("all-kinds")) throw new IllegalArgumentException("unsupported case");
        var hash = object(request.get("hash"));
        var hashId = string(hash, "id");
        var algorithm = switch (hashId) {
            case "sha1" -> "SHA-1"; case "rb01" -> "SHA-256"; case "s384" -> "SHA-384";
            default -> throw new IllegalArgumentException("unsupported hash");
        };
        var hasher = new Hasher(MessageDigest.getInstance(algorithm), Hasher.stringToId(hashId));
        if (hasher.md().getDigestLength() != ((Long) hash.get("size")).intValue()) throw new IllegalArgumentException("unsupported hash size");
        var path = string(request, "path");
        var operation = string(request, "operation");
        try (var file = new RandomAccessFile(path, operation.equals("write") ? "rw" : "r")) {
            var db = new Database(new CoreFile(file), hasher, 1L);
            Object result;
            switch (operation) {
                case "write", "read" -> {
                    if (operation.equals("write")) populate(db, request, path);
                    result = Map.of("tree", tree(db.rootCursor()), "numbers", NUMBERS, "iteration", ITERATION);
                    if (operation.equals("write")) {
                        var written = new LinkedHashMap<>(object(result));
                        written.put("writer_rejections", WRITER_REJECTIONS);
                        result = written;
                    }
                }
                case "compact" -> {
                    try (var target = new RandomAccessFile(path + ".compact", "rw")) {
                        var compacted = db.compact(new CoreFile(target));
                        result = Map.of("size", Long.toString(compacted.committedSize()));
                    }
                }
                case "replicate" -> {
                    try (var target = new RandomAccessFile(path + ".replica", "rw")) {
                        var replica = new Database(new CoreFile(target), hasher);
                        var base = Files.readAllBytes(Path.of(path + ".base"));
                        var delta = Files.readAllBytes(Path.of(path + ".delta"));
                        replica.applyReplicated(0, new ByteArrayInputStream(base), base.length);
                        var before = replica.replicaState();
                        if (db.replicationStart(before) != base.length) throw new AssertionError("prefix proof failed");
                        boolean rejected = false;
                        try (var interrupted = replica.openReplicated(base.length, delta.length)) {
                            interrupted.write(delta, 0, delta.length / 2);
                        } catch (Database.EndOfStreamException error) { rejected = true; }
                        if (!rejected || !before.equals(replica.replicaState())) throw new AssertionError("interrupted replica published");
                        replica.applyReplicated(base.length, new ByteArrayInputStream(delta), delta.length);
                        try (var output = Files.newOutputStream(Path.of(path + ".reference.base"))) { db.readCommitted(0, base.length, output); }
                        try (var output = Files.newOutputStream(Path.of(path + ".reference.delta"))) { db.readCommitted(base.length, db.committedSize(), output); }
                        result = Map.of("interrupted", true, "size", Long.toString(replica.committedSize()), "checksum", Long.toUnsignedString(replica.replicaState().checksum()));
                    }
                }
                default -> throw new IllegalArgumentException("unsupported operation");
            }
            System.out.println(Json.dump(result));
        }
    }

    // The adapter protocol needs JSON without an external Java dependency.
    static class Json {
        final String input;
        int at;
        Json(String input) { this.input = input; }
        void whitespace() { while (at < input.length() && Character.isWhitespace(input.charAt(at))) at++; }
        char take() { whitespace(); return input.charAt(at++); }
        void expect(char token) { if (take() != token) throw new IllegalArgumentException("invalid JSON"); }
        Object parse() {
            char token = take();
            if (token == '{') {
                var result = new LinkedHashMap<String, Object>();
                whitespace();
                if (input.charAt(at) == '}') { at++; return result; }
                do { var key = (String) parse(); expect(':'); result.put(key, parse()); token = take(); } while (token == ',');
                if (token != '}') throw new IllegalArgumentException("invalid JSON object");
                return result;
            }
            if (token == '[') {
                var result = new ArrayList<Object>();
                whitespace();
                if (input.charAt(at) == ']') { at++; return result; }
                do { result.add(parse()); token = take(); } while (token == ',');
                if (token != ']') throw new IllegalArgumentException("invalid JSON array");
                return result;
            }
            if (token == '"') {
                var result = new StringBuilder();
                while ((token = input.charAt(at++)) != '"') {
                    if (token == '\\') {
                        token = input.charAt(at++);
                        token = switch (token) {
                            case 'n' -> '\n'; case 'r' -> '\r'; case 't' -> '\t'; case 'b' -> '\b'; case 'f' -> '\f';
                            case 'u' -> { char value = (char) Integer.parseInt(input.substring(at, at + 4), 16); at += 4; yield value; }
                            case '"', '\\', '/' -> token;
                            default -> throw new IllegalArgumentException("invalid JSON escape");
                        };
                    }
                    result.append(token);
                }
                return result.toString();
            }
            int start = at - 1;
            while (at < input.length() && ",]} \r\n\t".indexOf(input.charAt(at)) < 0) at++;
            return switch (input.substring(start, at)) {
                case "true" -> true; case "false" -> false; case "null" -> null;
                default -> Long.valueOf(input.substring(start, at));
            };
        }
        static String dump(Object value) {
            if (value == null) return "null";
            if (value instanceof String text) return "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "\"";
            if (value instanceof Map<?, ?> map) {
                var entries = new ArrayList<String>();
                map.forEach((key, item) -> entries.add(dump(key) + ":" + dump(item)));
                return "{" + String.join(",", entries) + "}";
            }
            if (value instanceof List<?> list) return "[" + String.join(",", list.stream().map(Json::dump).toList()) + "]";
            return value.toString();
        }
    }
}
