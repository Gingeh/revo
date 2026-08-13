//
// c extensions, for revo
// build: make extension   (produces extension.so on mac)
//
// the shared lib exports revo_bindings which import(".so") picks up
//
// values cross the boundary nanboxed: a RevoData is a u64. numbers are raw
// f64 bits, boxed values carry an intern id in the low 48 bits, never a
// pointer. read strings with revo_string_data / revo_string_length and
// create them with revo_intern + revo_string.
//

#include "revo.h"
#include <regex.h>
#include <string.h>

/// > greet(name: string) -> string
static void greet_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 1 || !revo_is_string(argv[0])) {
    *out_result = revo_nil();
    return;
  }

  const char *name = (const char *)revo_string_data(vm, revo_string_id(argv[0]));
  size_t name_len = revo_string_length(vm, revo_string_id(argv[0]));

  // build "hello, <name>!" and intern it
  char buf[256];
  memcpy(buf, "hello, ", 7);
  memcpy(buf + 7, name, name_len);
  buf[7 + name_len] = '!';

  uint64_t sid = revo_intern(vm, (uint64_t)(uintptr_t)buf, 7 + name_len + 1);
  *out_result = revo_string(sid);
}

/// > add(a: number, b: number) -> number
static void add_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  (void)vm;
  if (argc < 2 || !revo_is_number(argv[0]) || !revo_is_number(argv[1])) {
    *out_result = revo_nil();
    return;
  }
  *out_result = revo_num(revo_num_value(argv[0]) + revo_num_value(argv[1]));
}

/// > echo(s: string) -> string
static void echo_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  (void)vm;
  if (argc < 1 || !revo_is_string(argv[0])) {
    *out_result = revo_nil();
    return;
  }
  // string ids pass through as-is, no re-intern needed
  *out_result = revo_string(revo_string_id(argv[0]));
}

/// > strlen(s: string) -> number
static void strlen_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 1 || !revo_is_string(argv[0])) {
    *out_result = revo_num(0);
    return;
  }
  *out_result = revo_num((double)revo_string_length(vm, revo_string_id(argv[0])));
}

/// > typ(x) -> number
/// returns the RevoType tag of the value
static void typ_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  (void)vm;
  if (argc < 1) {
    *out_result = revo_nil();
    return;
  }
  *out_result = revo_num((double)revo_type(argv[0]));
}

/// > regex(pattern: string, text: string) -> bool
static void regex_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 2 || !revo_is_string(argv[0]) || !revo_is_string(argv[1])) {
    *out_result = revo_num(0);
    return;
  }

  // intern ids are slices without a nul terminator; copy for regcomp
  char pattern[256];
  char text[256];
  {
    const char *p = (const char *)revo_string_data(vm, revo_string_id(argv[0]));
    size_t plen = revo_string_length(vm, revo_string_id(argv[0]));
    if (plen >= sizeof(pattern)) {
      *out_result = revo_num(0);
      return;
    }
    memcpy(pattern, p, plen);
    pattern[plen] = '\0';

    const char *t = (const char *)revo_string_data(vm, revo_string_id(argv[1]));
    size_t tlen = revo_string_length(vm, revo_string_id(argv[1]));
    if (tlen >= sizeof(text)) {
      *out_result = revo_num(0);
      return;
    }
    memcpy(text, t, tlen);
    text[tlen] = '\0';
  }

  regex_t regex;
  if (regcomp(&regex, pattern, REG_EXTENDED | REG_NOSUB) != 0) {
    regfree(&regex);
    *out_result = revo_num(0);
    return;
  }

  int match = regexec(&regex, text, 0, NULL, 0);
  regfree(&regex);

  *out_result = revo_bool(match == 0);
}

__attribute__((visibility("default"))) const RevoBinding revo_bindings[] = {
  {"greet", greet_fn},
  {"add", add_fn},
  {"echo", echo_fn},
  {"strlen", strlen_fn},
  {"typ", typ_fn},
  {"regex", regex_fn},
  {NULL, NULL},
};