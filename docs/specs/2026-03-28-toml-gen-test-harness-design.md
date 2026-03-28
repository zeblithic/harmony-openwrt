# Init Script TOML Generation Test Harness

**Date:** 2026-03-28
**Bead:** harmony-openwrt-yyb
**Status:** Design

## Problem

The init script (`harmony-node/files/harmony-node.init`) generates TOML configuration from UCI options using shell string escaping, integer validation, conditional emission, and section ordering. A single bad escape or missing newline produces invalid TOML that bricks the service on a remote router. There are zero tests.

## Goal

A test harness that validates the init script's TOML generation logic end-to-end: syntax correctness, semantic accuracy, edge case handling, and structural ordering.

## Approach

Shell test runner with Python TOML validation. Mock OpenWRT's UCI functions and filesystem commands so `start_service` runs unmodified outside a router.

## Files

| File | Purpose |
|------|---------|
| `tests/test_toml_gen.sh` | POSIX shell test runner — mocks UCI + filesystem, sources init script, runs test cases |
| `tests/validate_toml.py` | Python 3.11+ script — parses TOML from stdin via `tomllib`, optional typed key assertions |

## Sourcing the Init Script

The init script starts with `#!/bin/sh /etc/rc.common` and sets `USE_PROCD=1`, `START=95`, `STOP=10`. When sourced in a test shell:
- The shebang is treated as a comment (harmless)
- `USE_PROCD`, `START`, `STOP` become globals (harmless)
- `start_service` is defined but never called automatically — the test runner calls it explicitly
- All mocks (UCI, procd, filesystem) must be defined **before** sourcing the init script, since sourcing only defines functions and sets variables — no top-level side effects

The init script uses `<<-EOF` (tab-stripped heredoc) for TOML generation. The test must preserve the init script's tab indentation — do not reformat it.

## UCI Mocking Strategy

The init script depends on OpenWRT's UCI shell API (`config_load`, `config_get`, `config_get_bool`, `config_list_foreach`) and procd functions. The test runner replaces these with shell functions that read from environment variables:

```sh
# config_get VAR SECTION KEY DEFAULT
# Reads UCI_<SECTION>_<KEY>, falls back to DEFAULT
config_get() {
    local _var="$1" _section="$2" _key="$3" _default="$4"
    local _env_var="UCI_${_section}_${_key}"
    eval "$_var=\"\${$_env_var:-$_default}\""
}

# config_get_bool VAR SECTION KEY DEFAULT
# Same as config_get — init script's _bool() handles 1/0 conversion.
# Limitation: real OpenWRT config_get_bool normalizes "true"/"yes"/"on"
# to 1 and "false"/"no"/"off" to 0. This mock passes through raw values.
# Test authors MUST use 0/1 for boolean UCI vars, not "true"/"false".
config_get_bool() { config_get "$@"; }

# config_load PACKAGE — no-op (config already in env)
config_load() { :; }

# config_list_foreach SECTION KEY CALLBACK
# Iterates space-separated UCI_<SECTION>_<KEY>_LIST
config_list_foreach() {
    local _section="$1" _key="$2" _cb="$3"
    local _env_var="UCI_${_section}_${_key}_LIST"
    eval "local _list=\"\${$_env_var:-}\""
    for _item in $_list; do
        "$_cb" "$_item"
    done
}
```

Also mocked as no-ops: `procd_open_instance`, `procd_set_param`, `procd_close_instance`, `procd_add_reload_trigger`. `logger` is mocked to append to a capture variable for warning assertions.

The init script is sourced directly — its helpers (`_bool`, `_toml_str`, `_int`) and the full `start_service` function run unmodified.

## Filesystem Mocking

`start_service` calls `mkdir`, `chown`, `chmod`, `block info`, and `mountpoint` which would fail or cause side effects on the test host. The test runner overrides these as mock functions:

```sh
# Filesystem mocks — prevent side effects on host
mkdir() { :; }      # no-op (we don't need real directories)
chown() { :; }      # no-op (no harmony user on host)
chmod() { :; }      # no-op
mountpoint() { return 1; }  # always "not a mountpoint" — disables USB auto-detect
block() { :; }      # no-op (disables USB label detection)
```

This means USB storage auto-detection is effectively disabled in tests (always falls through to volatile `/var/lib/harmony`). The `test_storage_custom_path` test exercises the explicit UCI override path which does not depend on `block`/`mountpoint`.

`TOML_FILE` is overridden from `/tmp/harmony-node.toml` to a test-specific temp path (`$TEST_TMPDIR/harmony-node.toml`) to avoid collisions and host pollution.

## Python Validator

`validate_toml.py` reads TOML from stdin, parses with `tomllib` (stdlib since Python 3.11), and supports optional typed key assertions:

```
Usage:
  # Syntax check only
  cat config.toml | python3 tests/validate_toml.py

  # Syntax check + assert specific values (auto-coerced types)
  cat config.toml | python3 tests/validate_toml.py \
    --check listen_address "0.0.0.0:4242" \
    --check cache_capacity 256 \
    --check-absent relay_url \
    --check-section "tunnels[0].node_id" "abc123"
```

**Type coercion for `--check`:** The validator compares the TOML-parsed value against the CLI argument. Since CLI arguments are always strings, the validator coerces the expected value to match the parsed type: if the parsed value is `int`, attempt `int(expected)`; if `float`, attempt `float(expected)`; if `bool`, match `"true"/"false"`. If coercion fails, compare as strings. This prevents false failures from `256 (int) != "256" (str)`.

Exit codes: 0 = valid + all assertions pass, 1 = parse error or assertion failure. Error messages to stderr.

## Test Cases

Each test case is a shell function that sets UCI env vars, calls `start_service`, and validates the output.

### test_defaults

All UCI options at their default values. Validates:
- TOML parses successfully
- `listen_address = "0.0.0.0:4242"`
- `cache_capacity = 256`
- `compute_budget = 100000`
- `encrypted_durable_persist = false`
- `no_mdns = false`
- `mdns_stale_timeout = 60` (present because mDNS enabled)
- `relay_url` absent
- `data_dir = "/var/lib/harmony"` (volatile fallback)
- No `[[tunnels]]` sections

### test_disabled

`enabled=0`. Validates `start_service` returns early and no TOML file is written.

### test_relay_url_present

`relay_url="https://relay.example.com"`. Validates `relay_url = "https://relay.example.com"` appears in output.

### test_relay_url_absent

`relay_url=""` (empty). Validates `relay_url` key does not appear in output.

### test_mdns_timeout_conditional

`no_mdns=1`. Validates `mdns_stale_timeout` key does not appear in output (only emitted when mDNS is enabled).

### test_tunnel_peers_and_ordering

Two tunnel peers: `aabbcc...` and `ddeeff...`. Validates:
- Two `[[tunnels]]` sections exist
- Each contains the correct `node_id` value
- `data_dir` line appears before the first `[[tunnels]]` line (TOML root-level keys must precede section headers)

### test_special_chars_in_strings

Identity file path with spaces and backslashes: `/etc/harmony/my key\.key`. Also tests `listen_address` with IPv6 brackets: `[::1]:4242`. Validates TOML escaping produces parseable strings that round-trip to the original values.

### test_newline_injection

UCI value containing a literal newline character. Validates the TOML output either escapes it properly or the generated TOML still parses (no structure corruption from injected newlines).

### test_int_validation

Non-numeric values for integer fields (`cache_capacity="abc"`, `compute_budget="-5"`). Validates fallback to defaults (256, 100000).

### test_storage_none

`storage_path="none"`. Validates `data_dir = "/var/lib/harmony"` (forced volatile).

### test_storage_custom_path

`storage_path="/mnt/usb/custom"`. Validates `data_dir = "/mnt/usb/custom"` (explicit UCI override, exercises `_toml_str` escaping on the data_dir value).

### test_bool_edge_cases

Non-numeric boolean UCI values (`encrypted_durable_persist="yes"`). Validates `_bool` falls through to `false` when the value isn't numeric (the `-eq` comparison fails silently). Documents that the mock doesn't normalize like real `config_get_bool`.

## Test Runner Structure

```sh
#!/bin/sh
# tests/test_toml_gen.sh
set -e

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Track UCI vars for reliable cleanup
_UCI_VARS=""
set_uci() {
    local var="$1" val="$2"
    eval "$var=\"$val\""
    _UCI_VARS="$_UCI_VARS $var"
}

# Override TOML output path to temp dir
TOML_FILE="$TEST_TMPDIR/harmony-node.toml"

# Define all mocks (UCI, procd, filesystem) BEFORE sourcing init script
# ... mocks here ...

# Source the init script (defines start_service, _bool, _toml_str, _int)
. "$SCRIPT_DIR/../harmony-node/files/harmony-node.init"

run_test() {
    local name="$1"
    # Reset UCI env and TOML file
    for _v in $_UCI_VARS; do unset "$_v"; done
    _UCI_VARS=""
    rm -f "$TOML_FILE"
    LOGGER_OUTPUT=""
    # Run the test function
    if "$name"; then
        PASS=$((PASS + 1))
        printf "  PASS  %s\n" "$name"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL  %s\n" "$name"
    fi
}

# ... test functions ...

run_test test_defaults
run_test test_disabled
# ... etc ...

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]  # exit code
```

## Dependencies

- POSIX shell (sh/bash/zsh — any will work for running tests)
- Python 3.11+ (for `tomllib` in stdlib)
- No OpenWRT-specific tools required

## Out of Scope

- Testing `procd` service management (mocked as no-ops)
- Testing USB storage auto-detection (`block info`, `mountpoint` — mocked to disable; explicit `storage_path` override is tested)
- Testing firewall/UCI-defaults scripts (separate concern)
- CI integration (can be added later)
