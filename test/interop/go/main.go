package main

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
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
	FileID     string      `json:"file_id"`
	Value      value       `json:"value"`
	Values     []value     `json:"values"`
	Collection string      `json:"collection"`
	Entries    []hashEntry `json:"entries"`
	Removals   []string    `json:"removals"`
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
	if req.Case != "empty" && req.Case != "scalars" && req.Case != "array-list" && req.Case != "hash-collections" {
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
