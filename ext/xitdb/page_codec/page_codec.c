#include "ruby.h"
#include "ruby/encoding.h"
#include <stdint.h>
#include <string.h>

/* XP01 is a bounded schema followed by flat rows. No object deserialization. */
#define PAGE_LIMIT 65536
#define ROW_LIMIT 1024
#define FIELD_LIMIT 16

static int utf8_index, usascii_index, ascii8bit_index;
static ID default_id, default_proc_id, identity_id;
static VALUE invalid_value;

struct buffer { VALUE string; size_t used; int failed; };

static void append(struct buffer *output, const char *bytes, size_t length)
{
    if (output->failed || length > PAGE_LIMIT - output->used) {
        output->failed = 1;
        return;
    }
    memcpy(RSTRING_PTR(output->string) + output->used, bytes, length);
    output->used += length;
}

static void byte(struct buffer *output, unsigned char value)
{
    append(output, (const char *)&value, 1);
}

static void unsigned_value(struct buffer *output, uint64_t value)
{
    unsigned char bytes[10];
    int length = 0;
    do {
        bytes[length++] = (value & 127) | (value > 127 ? 128 : 0);
        value >>= 7;
    } while (value);
    append(output, (const char *)bytes, length);
}

static void cell(struct buffer *output, VALUE value)
{
    if (NIL_P(value)) { byte(output, 0); return; }
    if (value == Qfalse) { byte(output, 1); return; }
    if (value == Qtrue) { byte(output, 2); return; }
    if (FIXNUM_P(value)) {
        int64_t integer = FIX2LONG(value);
        byte(output, 3);
        unsigned_value(output, ((uint64_t)integer << 1) ^ (uint64_t)-(integer < 0));
        return;
    }
    if (CLASS_OF(value) == rb_cFloat) {
        double number = RFLOAT_VALUE(value);
        uint64_t bits;
        memcpy(&bits, &number, 8);
        byte(output, 4);
        for (int i = 7; i >= 0; i--) byte(output, (unsigned char)(bits >> (i * 8)));
        return;
    }
    if (CLASS_OF(value) != rb_cString) { output->failed = 1; return; }
    int encoding = rb_enc_get_index(value);
    if (encoding == utf8_index) byte(output, 5);
    else if (encoding == usascii_index) byte(output, 6);
    else if (encoding == ascii8bit_index) byte(output, 7);
    else {
        const char *name = rb_enc_name(rb_enc_from_index(encoding));
        size_t length = strlen(name);
        if (!length || length > 127) { output->failed = 1; return; }
        byte(output, 8);
        unsigned_value(output, length);
        append(output, name, length);
    }
    long length = RSTRING_LEN(value);
    unsigned_value(output, length);
    append(output, RSTRING_PTR(value), length);
}

struct encoder { struct buffer *output; VALUE keys; long index; int first; };

static int encode_pair(VALUE key, VALUE value, VALUE opaque)
{
    struct encoder *state = (struct encoder *)opaque;
    if (CLASS_OF(key) != rb_cString) { state->output->failed = 1; return ST_STOP; }
    if (state->first) {
        rb_ary_push(state->keys, key);
        cell(state->output, key);
    } else {
        VALUE expected = rb_ary_entry(state->keys, state->index);
        if (key != expected && (NIL_P(expected) || rb_enc_get_index(key) != rb_enc_get_index(expected) ||
            !RTEST(rb_str_equal(key, expected)))) {
            state->output->failed = 1;
            return ST_STOP;
        }
        cell(state->output, value);
    }
    state->index++;
    return state->output->failed ? ST_STOP : ST_CONTINUE;
}

static VALUE encode_page(VALUE self, VALUE rows)
{
    if (CLASS_OF(rows) != rb_cArray) return Qnil;
    long count = RARRAY_LEN(rows);
    if (count < 1 || count > ROW_LIMIT) return Qnil;
    VALUE first = rb_ary_entry(rows, 0);
    if (CLASS_OF(first) != rb_cHash) return Qnil;
    long width = RHASH_SIZE(first);
    if (width > FIELD_LIMIT) return Qnil;
    VALUE output = rb_str_new(NULL, PAGE_LIMIT);
    struct buffer buffer = { output, 0, 0 };
    append(&buffer, "XP01", 4);
    unsigned_value(&buffer, count);
    unsigned_value(&buffer, width);
    struct encoder state = { &buffer, rb_ary_new_capa(width), 0, 1 };
    rb_hash_foreach(first, encode_pair, (VALUE)&state);
    if (buffer.failed) return Qnil;
    state.first = 0;
    for (long i = 0; i < count; i++) {
        VALUE row = rb_ary_entry(rows, i);
        if (CLASS_OF(row) != rb_cHash) return Qnil;
        /* These public APIs preserve Hash defaults and identity semantics.
         * Callback exceptions propagate; only unsupported shapes return nil. */
        if (!NIL_P(rb_funcall(row, default_id, 0)) ||
            !NIL_P(rb_funcall(row, default_proc_id, 0)) ||
            RTEST(rb_funcall(row, identity_id, 0))) return Qnil;
        if (CLASS_OF(row) != rb_cHash || RHASH_SIZE(row) != (size_t)width) return Qnil;
        state.index = 0;
        rb_hash_foreach(row, encode_pair, (VALUE)&state);
        if (buffer.failed) return Qnil;
    }
    if (RARRAY_LEN(rows) != count) return Qnil;
    rb_str_set_len(output, buffer.used);
    RB_GC_GUARD(state.keys);
    RB_GC_GUARD(rows);
    return output;
}

struct decoder { const unsigned char *position; const unsigned char *end; };

static const unsigned char *take(struct decoder *state, uint64_t length)
{
    if (length > (uint64_t)(state->end - state->position)) rb_raise(invalid_value, "truncated Ruby page");
    const unsigned char *result = state->position;
    state->position += length;
    return result;
}

static uint64_t read_unsigned(struct decoder *state)
{
    uint64_t result = 0;
    for (int shift = 0; shift <= 63; shift += 7) {
        unsigned char part = *take(state, 1);
        if (shift == 63 && part > 1) rb_raise(invalid_value, "Ruby page integer overflow");
        result |= (uint64_t)(part & 127) << shift;
        if (!(part & 128)) {
            if (shift && !part) rb_raise(invalid_value, "noncanonical Ruby page integer");
            return result;
        }
    }
    rb_raise(invalid_value, "Ruby page integer overflow");
}

static rb_encoding *string_encoding(struct decoder *state, unsigned char tag)
{
    if (tag == 5) return rb_utf8_encoding();
    if (tag == 6) return rb_usascii_encoding();
    if (tag == 7) return rb_ascii8bit_encoding();
    if (tag != 8) rb_raise(invalid_value, "unknown Ruby page tag");
    uint64_t length = read_unsigned(state);
    if (!length || length > 127) rb_raise(invalid_value, "invalid Ruby page encoding name");
    char name[128];
    memcpy(name, take(state, length), length);
    name[length] = 0;
    if (strlen(name) != length) rb_raise(invalid_value, "invalid Ruby page encoding name");
    int index = rb_enc_find_index(name);
    if (index < 0 || index == utf8_index || index == usascii_index || index == ascii8bit_index)
        rb_raise(invalid_value, "invalid Ruby page encoding");
    rb_encoding *encoding = rb_enc_from_index(index);
    if (strcmp(name, rb_enc_name(encoding))) rb_raise(invalid_value, "noncanonical Ruby page encoding");
    return encoding;
}

static VALUE read_cell(struct decoder *state)
{
    unsigned char tag = *take(state, 1);
    switch (tag) {
      case 0: return Qnil;
      case 1: return Qfalse;
      case 2: return Qtrue;
      case 3: {
        uint64_t value = read_unsigned(state);
        int64_t integer = (int64_t)(value >> 1) ^ -(int64_t)(value & 1);
        return LL2NUM(integer);
      }
      case 4: {
        uint64_t bits = 0;
        for (int i = 0; i < 8; i++) bits = (bits << 8) | *take(state, 1);
        double number;
        memcpy(&number, &bits, 8);
        return rb_float_new(number);
      }
    }
    rb_encoding *encoding = string_encoding(state, tag);
    uint64_t length = read_unsigned(state);
    const unsigned char *bytes = take(state, length);
    return rb_enc_str_new((const char *)bytes, (long)length, encoding);
}

static void skip_cell(struct decoder *state)
{
    unsigned char tag = *take(state, 1);
    if (tag <= 2) return;
    if (tag == 3) { read_unsigned(state); return; }
    if (tag == 4) { take(state, 8); return; }
    string_encoding(state, tag);
    uint64_t length = read_unsigned(state);
    take(state, length);
}

static VALUE decode_selected(VALUE bytes, long selected, VALUE expected)
{
    Check_Type(bytes, T_STRING);
    if (RSTRING_LEN(bytes) > PAGE_LIMIT) rb_raise(invalid_value, "Ruby page byte limit exceeded");
    const unsigned char *start = (const unsigned char *)RSTRING_PTR(bytes);
    struct decoder state = { start, start + RSTRING_LEN(bytes) };
    if (memcmp(take(&state, 4), "XP01", 4)) rb_raise(invalid_value, "invalid Ruby page magic");
    uint64_t count = read_unsigned(&state), width = read_unsigned(&state);
    if (!count || count > ROW_LIMIT || width > FIELD_LIMIT) rb_raise(invalid_value, "invalid Ruby page count");
    if (!NIL_P(expected)) {
        if (!RB_INTEGER_TYPE_P(expected)) rb_raise(rb_eTypeError, "expected row count must be an Integer");
        if (!FIXNUM_P(expected) || FIX2LONG(expected) != (long)count)
            rb_raise(invalid_value, "Ruby page row count mismatch");
    }
    if (selected >= (long)count) rb_raise(rb_eIndexError, "row outside Ruby page");
    VALUE keys = rb_ary_new_capa(width);
    VALUE seen = rb_hash_new();
    VALUE result = selected < 0 ? rb_ary_new_capa(count) : Qnil;
    for (uint64_t i = 0; i < width; i++) {
        VALUE key = read_cell(&state);
        if (!RB_TYPE_P(key, T_STRING)) rb_raise(invalid_value, "Ruby page key must be a String");
        if (rb_hash_lookup2(seen, key, Qundef) != Qundef) rb_raise(invalid_value, "duplicate Ruby page key");
        key = rb_str_to_interned_str(key);
        rb_hash_aset(seen, key, Qtrue);
        rb_ary_push(keys, key);
    }
    for (uint64_t i = 0; i < count; i++) {
        if (selected >= 0 && i != (uint64_t)selected) {
            for (uint64_t j = 0; j < width; j++) skip_cell(&state);
            continue;
        }
        VALUE row = rb_hash_new();
        VALUE pairs[FIELD_LIMIT * 2];
        for (uint64_t j = 0; j < width; j++) {
            pairs[j * 2] = rb_ary_entry(keys, j);
            pairs[j * 2 + 1] = read_cell(&state);
        }
        rb_hash_bulk_insert((long)width * 2, pairs, row);
        if (selected < 0) rb_ary_push(result, row);
        else result = row;
    }
    if (state.position != state.end) rb_raise(invalid_value, "trailing Ruby page bytes");
    RB_GC_GUARD(bytes);
    RB_GC_GUARD(keys);
    RB_GC_GUARD(seen);
    return result;
}

static VALUE decode_page(int argc, VALUE *argv, VALUE self)
{
    VALUE bytes, expected;
    rb_scan_args(argc, argv, "11", &bytes, &expected);
    return decode_selected(bytes, -1, expected);
}

static VALUE decode_row(int argc, VALUE *argv, VALUE self)
{
    VALUE bytes, index, expected;
    rb_scan_args(argc, argv, "21", &bytes, &index, &expected);
    if (!RB_INTEGER_TYPE_P(index)) rb_raise(rb_eTypeError, "row index must be an Integer");
    if (!FIXNUM_P(index) || FIX2LONG(index) < 0) rb_raise(rb_eIndexError, "row outside Ruby page");
    return decode_selected(bytes, FIX2LONG(index), expected);
}

void Init_page_codec(void)
{
    VALUE xitdb = rb_const_get(rb_cObject, rb_intern("XitDB"));
    VALUE ruby = rb_define_module_under(xitdb, "Ruby");
    VALUE codec = rb_define_module_under(ruby, "PageCodec");
    invalid_value = rb_const_get(xitdb, rb_intern("InvalidValueError"));
    rb_global_variable(&invalid_value);
    utf8_index = rb_utf8_encindex();
    usascii_index = rb_usascii_encindex();
    ascii8bit_index = rb_ascii8bit_encindex();
    default_id = rb_intern("default");
    default_proc_id = rb_intern("default_proc");
    identity_id = rb_intern("compare_by_identity?");
    rb_define_singleton_method(codec, "encode_page", encode_page, 1);
    rb_define_singleton_method(codec, "decode_page", decode_page, -1);
    rb_define_singleton_method(codec, "decode_row", decode_row, -1);
}
