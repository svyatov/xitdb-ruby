package main

import (
	"bytes"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"iter"
	"os"
	"slices"
	"strconv"
	"strings"

	xitdb "github.com/xit-vcs/xitdb-go"
)

type value struct {
	Tag       string  `json:"tag"`
	Full      bool    `json:"full"`
	Bits      string  `json:"bits,omitempty"`
	Hex       *string `json:"hex,omitempty"`
	FormatTag *string `json:"format_tag"`
}

type request struct {
	Operation string `json:"operation"`
	Case      string `json:"case"`
	Path      string `json:"path"`
	Hash      struct {
		ID   string `json:"id"`
		Size int    `json:"size"`
	} `json:"hash"`
	FileID        string        `json:"file_id"`
	Value         value         `json:"value"`
	Values        []value       `json:"values"`
	Collection    string        `json:"collection"`
	Entries       []hashEntry   `json:"entries"`
	Removals      []string      `json:"removals"`
	Positions     []int64       `json:"positions"`
	Length        int64         `json:"length"`
	Deletions     []int64       `json:"deletions"`
	SplitIndex    int64         `json:"split_index"`
	Offset        int64         `json:"offset"`
	Size          int64         `json:"size"`
	SortedEntries []sortedEntry `json:"sorted_entries"`
}

type sortedEntry struct {
	KeyHex string `json:"key_hex"`
	Value  *value `json:"value"`
}

type hashEntry struct {
	Hash  string `json:"hash"`
	Key   value  `json:"key"`
	Value value  `json:"value"`
}

var collectionTags = map[string]xitdb.Tag{
	"hash_map": xitdb.TagHashMap, "hash_set": xitdb.TagHashSet,
	"counted_hash_map": xitdb.TagCountedHashMap, "counted_hash_set": xitdb.TagCountedHashSet,
}

var tags = map[string]xitdb.Tag{
	"none": xitdb.TagNone, "int": xitdb.TagInt, "uint": xitdb.TagUint,
	"float": xitdb.TagFloat, "bytes": xitdb.TagBytes, "short_bytes": xitdb.TagShortBytes,
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	var req request
	if err := json.NewDecoder(os.Stdin).Decode(&req); err != nil {
		return err
	}
	if req.Operation != "read" && req.Operation != "write" {
		return fmt.Errorf("unsupported operation: %s", req.Operation)
	}
	if req.Case != "empty" && req.Case != "scalars" && req.Case != "array-list" && req.Case != "hash-collections" && req.Case != "linked-array-insert" && req.Case != "linked-array-edit" && req.Case != "sorted-collections" && req.Case != "compaction" && req.Case != "replication" {
		return fmt.Errorf("unsupported case: %s", req.Case)
	}
	if req.Hash.ID != "sha1" || req.Hash.Size != 20 {
		return fmt.Errorf("unsupported hash configuration")
	}
	fileID, err := strconv.ParseUint(req.FileID, 10, 64)
	if err != nil {
		return err
	}
	flags := os.O_RDONLY
	if req.Operation == "write" {
		flags = os.O_RDWR | os.O_CREATE
	}
	file, err := os.OpenFile(req.Path, flags, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	db, err := xitdb.NewDatabase(xitdb.NewCoreFile(file), xitdb.Hasher{
		Hash: sha1.New, ID: xitdb.BytesToID([4]byte{'s', 'h', 'a', '1'}), FileID: fileID,
	})
	if err != nil {
		return err
	}
	if req.Operation == "write" && req.Case == "scalars" {
		data, err := writeValue(req.Value)
		if err != nil {
			return err
		}
		if err := db.RootCursor().Write(data); err != nil {
			return err
		}
	}
	if req.Case == "array-list" {
		return arrayList(db, req)
	}
	if req.Case == "hash-collections" {
		return hashCollections(db, req)
	}
	if req.Case == "linked-array-insert" {
		return linkedArrayInsert(db, req)
	}
	if req.Case == "linked-array-edit" {
		return linkedArrayEdit(db, req)
	}
	if req.Case == "sorted-collections" {
		return sortedCollections(db, req)
	}
	if req.Case == "compaction" {
		return compaction(db, req)
	}
	if req.Case == "replication" {
		return replication(db, req)
	}
	if req.Case == "empty" {
		data, err := os.ReadFile(req.Path)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]string{"file_hex": hex.EncodeToString(data)})
	}
	result, err := readValue(db.RootCursor().ReadCursor)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}

func compaction(db *xitdb.Database, req request) error {
	if req.Collection != "history" && req.Collection != "raw" {
		return fmt.Errorf("unsupported compaction root: %s", req.Collection)
	}
	payload := bytes.Repeat([]byte("opaque\x00payload"), 6000)
	if req.Operation == "write" {
		if err := writeCompactionGraph(db, req.Collection, payload); err != nil {
			return err
		}
	}
	original, err := os.ReadFile(req.Path)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(req.Path+".go-compact", os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	target, err := db.Compact(xitdb.NewCoreFile(file), make(xitdb.MemoryOffsetMap))
	if err != nil {
		return err
	}
	if target.Header.FileID == db.Header.FileID {
		return fmt.Errorf("compaction reused source identity")
	}
	after, err := os.ReadFile(req.Path)
	if err != nil {
		return err
	}
	if !bytes.Equal(original, after) {
		return fmt.Errorf("compaction changed source bytes")
	}
	return readCompactionGraph(target, req.Collection, payload)
}

func writeCompactionGraph(db *xitdb.Database, kind string, payload []byte) error {
	return db.RunContext(func(cursor *xitdb.WriteCursor) error {
		core := db.Core
		position, err := core.Length()
		if err != nil {
			return err
		}
		if err := core.SeekTo(position); err != nil {
			return err
		}
		data := binary.BigEndian.AppendUint64(nil, uint64(len(payload)))
		data = append(data, payload...)
		data = append(data, 0xff, 0)
		if err := core.Write(data); err != nil {
			return err
		}
		value := xitdb.Slot{Tag: xitdb.TagBytes, Value: position, Full: true}
		position += int64(len(data))
		graph := xitdb.Slot{Tag: xitdb.TagIndex, Value: position, Full: true}
		if kind == "history" {
			graph.Tag = xitdb.TagArrayList
			header := binary.BigEndian.AppendUint64(nil, 4)
			header = binary.BigEndian.AppendUint64(header, uint64(position+16))
			if err := core.Write(header); err != nil {
				return err
			}
		}
		short := xitdb.Slot{Tag: xitdb.TagShortBytes, Full: true,
			Value: int64(binary.BigEndian.Uint64([]byte{'s', 'h', 'o', 'r', 't', 0, 0xff, 0}))}
		block := make([]byte, xitdb.IndexBlockSize)
		for i, slot := range []xitdb.Slot{graph, value, value, short} {
			encoded := slot.ToBytes()
			copy(block[i*xitdb.SlotLength:], encoded[:])
		}
		if err := core.Write(block); err != nil {
			return err
		}
		if kind == "raw" {
			return cursor.Write(graph)
		}
		history, err := xitdb.NewWriteArrayList(cursor)
		if err != nil {
			return err
		}
		if err := history.Append(xitdb.NewUint(10)); err != nil {
			return err
		}
		return history.Append(graph)
	})
}

func readCompactionGraph(db *xitdb.Database, kind string, payload []byte) error {
	graph, err := db.RootCursor().Slot()
	if err != nil {
		return err
	}
	historyCount := int64(0)
	if kind == "history" {
		history, err := xitdb.NewReadArrayList(db.RootCursor().ReadCursor)
		if err != nil {
			return err
		}
		historyCount, err = history.Count()
		if err != nil {
			return err
		}
		if historyCount != 1 {
			return fmt.Errorf("compacted history has %d entries", historyCount)
		}
		graph, err = history.GetSlot(0)
		if err != nil {
			return err
		}
	}
	if !graph.Full || (kind == "history" && graph.Tag != xitdb.TagArrayList) || (kind == "raw" && graph.Tag != xitdb.TagIndex) {
		return fmt.Errorf("compacted graph tag or full bit changed")
	}
	pointer := graph.Value
	if kind == "history" {
		if err := db.Core.SeekTo(pointer); err != nil {
			return err
		}
		header := make([]byte, 16)
		if err := db.Core.Read(header); err != nil {
			return err
		}
		if binary.BigEndian.Uint64(header[:8]) != 4 {
			return fmt.Errorf("cyclic list size changed")
		}
		pointer = int64(binary.BigEndian.Uint64(header[8:]))
	}
	if err := db.Core.SeekTo(pointer); err != nil {
		return err
	}
	var children [4]xitdb.Slot
	for i := range children {
		var encoded [xitdb.SlotLength]byte
		if err := db.Core.Read(encoded[:]); err != nil {
			return err
		}
		children[i] = xitdb.SlotFromBytes(encoded)
	}
	if children[0] != graph || children[1] != children[2] {
		return fmt.Errorf("cycle or shared storage changed")
	}
	for _, i := range []int{1, 3} {
		cursor := &xitdb.ReadCursor{DB: db, SlotPtr: xitdb.SlotPointer{Slot: children[i]}}
		value, err := cursor.ReadBytesObject(int64(len(payload)))
		if err != nil {
			return err
		}
		expected := payload
		if i == 3 {
			expected = []byte("short")
		}
		if !bytes.Equal(value.Value, expected) || !bytes.Equal(value.FormatTag, []byte{0xff, 0}) {
			return fmt.Errorf("tagged byte content changed at %d", i)
		}
	}
	digest := sha256.Sum256(payload)
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"history": historyCount, "cycle": true, "shared": true,
		"payload_sha256": hex.EncodeToString(digest[:]), "tag": "ff00", "short": "short", "short_tag": "ff00",
	})
}

func sortedCollections(db *xitdb.Database, req request) error {
	set := req.Collection == "sorted_set"
	if !set && req.Collection != "sorted_map" {
		return fmt.Errorf("unsupported sorted collection: %s", req.Collection)
	}
	if req.Operation == "write" {
		if _, err := db.RootCursor().WritePath([]xitdb.PathPart{xitdb.SortedMapInitPart{Set: set}}); err != nil {
			return err
		}
		for _, entry := range req.SortedEntries {
			key, err := hex.DecodeString(entry.KeyHex)
			if err != nil {
				return err
			}
			var target xitdb.SortedMapGetTarget = xitdb.SortedMapGetKey{Key: key}
			if entry.Value != nil {
				target = xitdb.SortedMapGetValue{Key: key}
			}
			path := []xitdb.PathPart{xitdb.SortedMapGetPart{Target: target}}
			if entry.Value != nil {
				data, err := writeValue(*entry.Value)
				if err != nil {
					return err
				}
				path = append(path, xitdb.WriteData{Data: data})
			}
			if _, err := db.RootCursor().WritePath(path); err != nil {
				return err
			}
		}
		for _, encoded := range req.Removals {
			key, err := hex.DecodeString(encoded)
			if err != nil {
				return err
			}
			_, err = db.RootCursor().WritePath([]xitdb.PathPart{xitdb.SortedMapRemovePart{Key: key}})
			if err != nil && !errors.Is(err, xitdb.ErrKeyNotFound) {
				return err
			}
		}
	}
	reader, err := xitdb.NewReadSortedMap(db.RootCursor().ReadCursor)
	if err != nil {
		return err
	}
	slot, err := reader.Slot()
	if err != nil {
		return err
	}
	expectedTag := xitdb.TagSortedMap
	if set {
		expectedTag = xitdb.TagSortedSet
	}
	if slot.Tag != expectedTag {
		return fmt.Errorf("unexpected sorted tag: %d", slot.Tag)
	}
	count, err := reader.Count()
	if err != nil {
		return err
	}
	entries := make([]map[string]any, 0, count)
	keys := make([]string, 0, count)
	for cursor, err := range reader.All() {
		if err != nil {
			return err
		}
		pair, err := cursor.ReadKeyValuePair()
		if err != nil {
			return err
		}
		key, err := pair.KeyCursor.ReadBytesObject(1 << 20)
		if err != nil {
			return err
		}
		v, err := readValue(pair.ValueCursor)
		if err != nil {
			return err
		}
		rank, err := reader.RankByBytes(key.Value)
		if err != nil {
			return err
		}
		if rank != int64(len(entries)) {
			return fmt.Errorf("sorted rank %d at %d", rank, len(entries))
		}
		indexed, err := reader.GetIndexKeyValuePair(rank)
		if err != nil {
			return err
		}
		indexedKey, err := indexed.KeyCursor.ReadBytesObject(1 << 20)
		if err != nil {
			return err
		}
		encoded := hex.EncodeToString(key.Value)
		if hex.EncodeToString(indexedKey.Value) != encoded {
			return fmt.Errorf("sorted index differs at %d", rank)
		}
		keys = append(keys, encoded)
		entries = append(entries, map[string]any{"key_hex": encoded, "value": v})
	}
	if count != int64(len(entries)) {
		return fmt.Errorf("sorted count %d differs from %d entries", count, len(entries))
	}
	start := max(len(keys)-2, 0)
	startKey := []byte{}
	if len(keys) > 0 {
		startKey, err = hex.DecodeString(keys[start])
		if err != nil {
			return err
		}
	}
	for _, seq := range []iter.Seq2[*xitdb.ReadCursor, error]{reader.AllFrom(startKey), reader.AllFromIndex(int64(start))} {
		actual, err := sortedIterationKeys(seq)
		if err != nil {
			return err
		}
		if !slices.Equal(keys[start:], actual) {
			return fmt.Errorf("sorted suffix differs")
		}
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"tag": req.Collection, "count": count, "entries": entries})
}

func sortedIterationKeys(seq iter.Seq2[*xitdb.ReadCursor, error]) ([]string, error) {
	keys := []string{}
	for cursor, err := range seq {
		if err != nil {
			return nil, err
		}
		pair, err := cursor.ReadKeyValuePair()
		if err != nil {
			return nil, err
		}
		key, err := pair.KeyCursor.ReadBytesObject(1 << 20)
		if err != nil {
			return nil, err
		}
		keys = append(keys, hex.EncodeToString(key.Value))
	}
	return keys, nil
}

func linkedArrayEdit(db *xitdb.Database, req request) error {
	if req.Operation == "write" {
		list, err := xitdb.NewWriteLinkedArrayList(db.RootCursor())
		if err != nil {
			return err
		}
		for index := range req.Length {
			if err := list.Append(xitdb.Slot{Tag: xitdb.TagUint, Value: index}); err != nil {
				return err
			}
		}
		for turn, index := range req.Deletions {
			if err := list.Remove(index); err != nil {
				return err
			}
			count, err := list.Count()
			if err != nil {
				return err
			}
			if count != req.Length-int64(turn)-1 {
				return fmt.Errorf("linked count %d after deletion %d", count, turn)
			}
		}
		count, err := list.Count()
		if err != nil {
			return err
		}
		source, err := list.Slot()
		if err != nil {
			return err
		}
		if err := list.Slice(0, req.SplitIndex); err != nil {
			return err
		}
		left, err := list.Slot()
		if err != nil {
			return err
		}
		if err := db.RootCursor().Write(source); err != nil {
			return err
		}
		if err := list.Slice(req.SplitIndex, count-req.SplitIndex); err != nil {
			return err
		}
		right, err := list.Slot()
		if err != nil {
			return err
		}
		if err := db.RootCursor().Write(left); err != nil {
			return err
		}
		if err := list.Concat(right); err != nil {
			return err
		}
		if err := list.Slice(req.Offset, req.Size); err != nil {
			return err
		}
		selected, err := list.Slot()
		if err != nil {
			return err
		}
		if err := list.Slice(0, 0); err != nil {
			return err
		}
		empty, err := list.Slot()
		if err != nil {
			return err
		}
		if err := list.Concat(selected); err != nil {
			return err
		}
		if err := list.Concat(empty); err != nil {
			return err
		}
	}
	return linkedArrayInsert(db, request{Operation: "read"})
}

func linkedArrayInsert(db *xitdb.Database, req request) error {
	if req.Operation == "write" {
		list, err := xitdb.NewWriteLinkedArrayList(db.RootCursor())
		if err != nil {
			return err
		}
		for index, position := range req.Positions {
			data := xitdb.Slot{Tag: xitdb.TagUint, Value: int64(index)}
			var err error
			if position == int64(index) {
				err = list.Append(data)
			} else {
				err = list.Insert(position, data)
			}
			if err != nil {
				return err
			}
			count, err := list.Count()
			if err != nil {
				return err
			}
			if count != int64(index+1) {
				return fmt.Errorf("linked count %d after insertion %d", count, index)
			}
		}
	}
	list, err := xitdb.NewReadLinkedArrayList(db.RootCursor().ReadCursor)
	if err != nil {
		return err
	}
	slot, err := list.Slot()
	if err != nil {
		return err
	}
	if slot.Tag != xitdb.TagLinkedArrayList {
		return fmt.Errorf("expected linked-array tag, got %d", slot.Tag)
	}
	count, err := list.Count()
	if err != nil {
		return err
	}
	result := make([]string, 0, count)
	for index := range count {
		slot, err := list.GetSlot(index)
		if err != nil {
			return err
		}
		result = append(result, strconv.FormatUint(uint64(slot.Value), 10))
	}
	start := max(count-2, 0)
	index := start
	for cursor, err := range list.AllFrom(start) {
		if err != nil {
			return err
		}
		slot, err := cursor.Slot()
		if err != nil {
			return err
		}
		if index >= count || result[index] != strconv.FormatUint(uint64(slot.Value), 10) {
			return fmt.Errorf("linked suffix differs at %d", index)
		}
		index++
	}
	if index != count {
		return fmt.Errorf("linked suffix ended at %d, expected %d", index, count)
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}

func hashCollections(db *xitdb.Database, req request) error {
	tag, ok := collectionTags[req.Collection]
	if !ok {
		return fmt.Errorf("unsupported hash collection: %s", req.Collection)
	}
	counted := strings.HasPrefix(req.Collection, "counted")
	if req.Operation == "write" {
		if _, err := db.RootCursor().WritePath([]xitdb.PathPart{
			xitdb.HashMapInitPart{Counted: counted, Set: strings.HasSuffix(req.Collection, "set")},
		}); err != nil {
			return err
		}
		for _, entry := range req.Entries {
			hash, err := hex.DecodeString(entry.Hash)
			if err != nil {
				return err
			}
			_, err = db.RootCursor().WritePath([]xitdb.PathPart{
				xitdb.HashMapGetPart{Target: xitdb.HashMapGetKVPair{Hash: hash}},
				xitdb.Context{Function: func(cursor *xitdb.WriteCursor) error {
					pair, err := cursor.ReadKeyValuePair()
					if err != nil {
						return err
					}
					if entry.Key.Tag != "none" || entry.Key.Full {
						key, err := writeValue(entry.Key)
						if err != nil {
							return err
						}
						if err := pair.KeyCursor.WriteIfEmpty(key); err != nil {
							return err
						}
					}
					if entry.Value.Tag == "none" && !entry.Value.Full {
						return nil
					}
					data, err := writeValue(entry.Value)
					if err != nil {
						return err
					}
					return pair.ValueCursor.Write(data)
				}},
			})
			if err != nil {
				return err
			}
		}
		for _, encoded := range req.Removals {
			hash, err := hex.DecodeString(encoded)
			if err != nil {
				return err
			}
			if _, err := db.RootCursor().WritePath([]xitdb.PathPart{xitdb.HashMapRemovePart{Hash: hash}}); err != nil {
				return err
			}
		}
	}
	root := db.RootCursor().ReadCursor
	slot, err := root.Slot()
	if err != nil {
		return err
	}
	if slot.Tag != tag {
		return fmt.Errorf("expected collection tag %d, got %d", tag, slot.Tag)
	}
	entries := make([]map[string]any, 0)
	for cursor, err := range root.All() {
		if err != nil {
			return err
		}
		pair, err := cursor.ReadKeyValuePair()
		if err != nil {
			return err
		}
		key, err := readValue(pair.KeyCursor)
		if err != nil {
			return err
		}
		v, err := readValue(pair.ValueCursor)
		if err != nil {
			return err
		}
		hash := hex.EncodeToString(pair.Hash)
		found, err := root.ReadPath([]xitdb.PathPart{xitdb.HashMapGetPart{Target: xitdb.HashMapGetKVPair{Hash: pair.Hash}}})
		if err != nil {
			return err
		}
		if found == nil {
			return fmt.Errorf("enumerated hash %s is missing", hash)
		}
		entries = append(entries, map[string]any{"hash": hash, "key": key, "value": v})
	}
	slices.SortFunc(entries, func(a, b map[string]any) int {
		return strings.Compare(a["hash"].(string), b["hash"].(string))
	})
	if counted {
		count, err := root.Count()
		if err != nil {
			return err
		}
		if count != int64(len(entries)) {
			return fmt.Errorf("counted header %d differs from %d entries", count, len(entries))
		}
	}
	missing, err := root.ReadPath([]xitdb.PathPart{xitdb.HashMapGetPart{Target: xitdb.HashMapGetKVPair{Hash: []byte(strings.Repeat("\xff", 20))}}})
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"tag": req.Collection, "count": len(entries), "entries": entries, "missing": missing == nil,
	})
}

func arrayList(db *xitdb.Database, req request) error {
	if req.Operation == "write" {
		list, err := xitdb.NewWriteArrayList(db.RootCursor())
		if err != nil {
			return err
		}
		for _, v := range req.Values {
			if v.Tag == "none" && !v.Full {
				if _, err := list.AppendCursor(); err != nil {
					return err
				}
				continue
			}
			data, err := writeValue(v)
			if err != nil {
				return err
			}
			if err := list.Append(data); err != nil {
				return err
			}
		}
	}
	list, err := xitdb.NewReadArrayList(db.RootCursor().ReadCursor)
	if err != nil {
		return err
	}
	count, err := list.Count()
	if err != nil {
		return err
	}
	result := make([]map[string]any, 0, count)
	for i := range count {
		cursor, err := list.GetCursor(i)
		if err != nil {
			return err
		}
		if cursor == nil {
			result = append(result, map[string]any{"tag": "none", "full": false, "bits": "0"})
			continue
		}
		v, err := readValue(cursor)
		if err != nil {
			return err
		}
		result = append(result, v)
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}

func replication(db *xitdb.Database, req request) error {
	payload := bytes.Repeat([]byte("opaque\x00replication"), 6000)
	var firstSize int64
	if req.Operation == "write" {
		if err := db.RootCursor().Write(xitdb.Slot{Tag: xitdb.TagUint, Value: 7}); err != nil {
			return err
		}
		var err error
		firstSize, err = db.CommittedSize()
		if err != nil {
			return err
		}
		if err := db.RootCursor().Write(xitdb.NewTaggedBytes(payload, []byte{0xff, 0})); err != nil {
			return err
		}
		finish, err := db.CommittedSize()
		if err != nil {
			return err
		}
		for _, part := range []struct {
			name       string
			start, end int64
		}{{".base", 0, firstSize}, {".delta", firstSize, finish}} {
			var stream bytes.Buffer
			if err := db.ReadCommitted(part.start, part.end, &stream); err != nil {
				return err
			}
			if err := os.WriteFile(req.Path+part.name, stream.Bytes(), 0600); err != nil {
				return err
			}
		}
	} else {
		base, err := os.ReadFile(req.Path + ".base")
		if err != nil {
			return err
		}
		file, err := os.OpenFile(req.Path+".replica", os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		defer file.Close()
		replica, err := xitdb.NewDatabase(xitdb.NewCoreFile(file), xitdb.Hasher{
			Hash: sha1.New, ID: xitdb.BytesToID([4]byte{'s', 'h', 'a', '1'}), FileID: 9,
		})
		if err != nil {
			return err
		}
		if err := replica.ApplyReplicated(0, bytes.NewReader(base), int64(len(base))); err != nil {
			return err
		}
		state, err := replica.ReplicaState()
		if err != nil {
			return err
		}
		firstSize, err = db.ReplicationStart(state)
		if err != nil {
			return err
		}
		if firstSize != int64(len(base)) {
			return fmt.Errorf("historical replica is not a source prefix")
		}
		root, err := replica.RootCursor().Slot()
		if err != nil {
			return err
		}
		if root.Tag != xitdb.TagUint || root.Value != 7 {
			return fmt.Errorf("historical export root changed")
		}
		delta, err := os.ReadFile(req.Path + ".delta")
		if err != nil {
			return err
		}
		if err := replica.ApplyReplicated(firstSize, bytes.NewReader(delta), int64(len(delta))); err != nil {
			return err
		}
		db = replica
	}
	state, err := db.ReplicaState()
	if err != nil {
		return err
	}
	value, err := db.RootCursor().ReadBytesObject(int64(len(payload)))
	if err != nil {
		return err
	}
	if !bytes.Equal(value.Value, payload) || !bytes.Equal(value.FormatTag, []byte{0xff, 0}) {
		return fmt.Errorf("replicated opaque bytes changed")
	}
	digest := sha256.Sum256(payload)
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"first_size": firstSize, "size": state.CommittedSize,
		"checksum": strconv.FormatUint(state.Checksum, 10), "payload_sha256": hex.EncodeToString(digest[:]),
	})
}

func writeValue(v value) (xitdb.WriteableData, error) {
	tag, ok := tags[v.Tag]
	if !ok {
		return nil, fmt.Errorf("unsupported value tag: %s", v.Tag)
	}
	if tag == xitdb.TagBytes || tag == xitdb.TagShortBytes {
		if v.Hex == nil {
			return nil, fmt.Errorf("missing bytes")
		}
		data, err := hex.DecodeString(*v.Hex)
		if err != nil {
			return nil, err
		}
		if v.FormatTag == nil {
			return xitdb.NewBytes(data), nil
		}
		format, err := hex.DecodeString(*v.FormatTag)
		if err != nil {
			return nil, err
		}
		if len(format) != 2 {
			return nil, fmt.Errorf("format tag requires two bytes")
		}
		return xitdb.NewTaggedBytes(data, format), nil
	}
	bits, err := strconv.ParseUint(v.Bits, 10, 64)
	if err != nil {
		return nil, err
	}
	// Raw slots preserve unsigned integers and NaN payloads exactly.
	return xitdb.Slot{Tag: tag, Value: int64(bits), Full: v.Full}, nil
}

func readValue(cursor *xitdb.ReadCursor) (map[string]any, error) {
	slot, err := cursor.Slot()
	if err != nil {
		return nil, err
	}
	name := ""
	for key, tag := range tags {
		if slot.Tag == tag {
			name = key
			break
		}
	}
	if name == "" {
		return nil, fmt.Errorf("unsupported slot tag: %d", slot.Tag)
	}
	result := map[string]any{"tag": name, "full": slot.Full}
	if slot.Tag == xitdb.TagBytes || slot.Tag == xitdb.TagShortBytes {
		data, err := cursor.ReadBytesObject(1 << 20)
		if err != nil {
			return nil, err
		}
		result["hex"] = hex.EncodeToString(data.Value)
		result["format_tag"] = nil
		if data.FormatTag != nil {
			result["format_tag"] = hex.EncodeToString(data.FormatTag)
		}
	} else {
		result["bits"] = strconv.FormatUint(uint64(slot.Value), 10)
	}
	return result, nil
}
