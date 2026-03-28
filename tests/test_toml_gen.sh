#!/bin/sh
# Test harness for harmony-node init script TOML generation.
# Mocks OpenWRT's UCI/procd/filesystem APIs so start_service runs
# unmodified outside a router.
#
# Usage: sh tests/test_toml_gen.sh
# Requires: Python 3.11+ (for tomllib)
set -e

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# ── UCI var tracking ──────────────────────────────────────────────────
_UCI_VARS=""
set_uci() {
    eval "$1='$2'"
    _UCI_VARS="$_UCI_VARS $1"
}
reset_uci() {
    for _v in $_UCI_VARS; do unset "$_v" 2>/dev/null; done
    _UCI_VARS=""
}

# ── UCI mocks ─────────────────────────────────────────────────────────
config_load() { :; }

config_get() {
    local _var="$1" _section="$2" _key="$3" _default="$4"
    local _env_var="UCI_${_section}_${_key}"
    eval "$_var=\"\${$_env_var:-$_default}\""
}

# Limitation: real config_get_bool normalizes "true"/"yes" to 1.
# This mock passes through raw values. Use 0/1 only.
config_get_bool() { config_get "$@"; }

config_list_foreach() {
    local _section="$1" _key="$2" _cb="$3"
    local _env_var="UCI_${_section}_${_key}_LIST"
    eval "local _list=\"\${$_env_var:-}\""
    for _item in $_list; do
        "$_cb" "$_item"
    done
}

# ── Procd mocks ───────────────────────────────────────────────────────
procd_open_instance() { :; }
procd_set_param() { :; }
procd_close_instance() { :; }
procd_add_reload_trigger() { :; }

# ── Filesystem mocks ─────────────────────────────────────────────────
mkdir() { :; }
chown() { :; }
chmod() { :; }
mountpoint() { return 1; }
block() { :; }

# ── Logger mock ───────────────────────────────────────────────────────
LOGGER_OUTPUT=""
logger() { LOGGER_OUTPUT="$LOGGER_OUTPUT $*"; }

# ── Source the init script ────────────────────────────────────────────
# IMPORTANT: Source BEFORE overriding TOML_FILE. The init script's
# top-level TOML_FILE="/tmp/harmony-node.toml" executes during sourcing
# and would clobber our override if we set it first.
. "$SCRIPT_DIR/../harmony-node/files/harmony-node.init"

# ── Override TOML path (AFTER sourcing) ───────────────────────────────
TOML_FILE="$TEST_TMPDIR/harmony-node.toml"

# ── Validator helper ──────────────────────────────────────────────────
validate() {
    python3 "$SCRIPT_DIR/validate_toml.py" "$@" < "$TOML_FILE"
}

# ── Test runner ───────────────────────────────────────────────────────
run_test() {
    local name="$1"
    reset_uci
    rm -f "$TOML_FILE"
    LOGGER_OUTPUT=""
    if "$name" 2>"$TEST_TMPDIR/stderr.log"; then
        PASS=$((PASS + 1))
        printf "  PASS  %s\n" "$name"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL  %s\n" "$name"
        # Show stderr on failure for debugging
        [ -s "$TEST_TMPDIR/stderr.log" ] && cat "$TEST_TMPDIR/stderr.log" >&2
    fi
}

# ── Test: defaults ────────────────────────────────────────────────────
test_defaults() {
    # No UCI vars set — all defaults
    start_service
    validate \
        --check listen_address "0.0.0.0:4242" \
        --check identity_file "/etc/harmony/identity.key" \
        --check cache_capacity 256 \
        --check compute_budget 100000 \
        --check filter_broadcast_ticks 30 \
        --check filter_mutation_threshold 100 \
        --check encrypted_durable_persist false \
        --check encrypted_durable_announce false \
        --check no_public_ephemeral_announce false \
        --check no_mdns false \
        --check mdns_stale_timeout 60 \
        --check data_dir "/var/lib/harmony" \
        --check-absent relay_url \
        --check-absent tunnels
}

# ── Test: disabled ────────────────────────────────────────────────────
test_disabled() {
    set_uci UCI_main_enabled 0
    start_service
    # start_service should return early — no TOML file written
    [ ! -f "$TOML_FILE" ]
}

# ── Test: relay_url present ───────────────────────────────────────────
test_relay_url_present() {
    set_uci UCI_main_relay_url "https://relay.example.com"
    start_service
    validate --check relay_url "https://relay.example.com"
}

# ── Test: relay_url absent ────────────────────────────────────────────
test_relay_url_absent() {
    # Empty relay_url (default) — key should not appear
    start_service
    validate --check-absent relay_url
}

# ── Test: mdns_stale_timeout conditional ──────────────────────────────
test_mdns_timeout_conditional() {
    set_uci UCI_main_no_mdns 1
    start_service
    validate \
        --check no_mdns true \
        --check-absent mdns_stale_timeout
}

# ── Test: tunnel peers + section ordering ─────────────────────────────
test_tunnel_peers_and_ordering() {
    set_uci UCI_main_tunnel_peer_LIST "aabbccdd00112233aabbccdd00112233aabbccdd00112233aabbccdd00112233 ddeeff0011223344ddeeff0011223344ddeeff0011223344ddeeff0011223344"
    start_service
    # Validate tunnel content
    validate \
        --check-section "tunnels[0].node_id" "aabbccdd00112233aabbccdd00112233aabbccdd00112233aabbccdd00112233" \
        --check-section "tunnels[1].node_id" "ddeeff0011223344ddeeff0011223344ddeeff0011223344ddeeff0011223344"
    # Validate ordering: data_dir must appear before first [[tunnels]]
    local data_line tunnel_line
    data_line=$(grep -n '^data_dir' "$TOML_FILE" | head -1 | cut -d: -f1)
    tunnel_line=$(grep -n '^\[\[tunnels\]\]' "$TOML_FILE" | head -1 | cut -d: -f1)
    [ -n "$data_line" ] && [ -n "$tunnel_line" ] && [ "$data_line" -lt "$tunnel_line" ]
}

# ── Test: special characters in strings ───────────────────────────────
test_special_chars_in_strings() {
    set_uci UCI_main_identity_file '/etc/harmony/my key\.key'
    set_uci UCI_main_listen_address '[::1]:4242'
    start_service
    validate \
        --check identity_file '/etc/harmony/my key\.key' \
        --check listen_address '[::1]:4242'
}

# ── Test: newline injection ───────────────────────────────────────────
test_newline_injection() {
    # A newline in a UCI value should not corrupt TOML structure.
    # _toml_str does NOT escape newlines — it only escapes \ and ".
    # The generated TOML will contain a literal newline inside a
    # double-quoted string, which is invalid TOML. This test documents
    # the current behavior: we expect a TOML parse failure.
    # If _toml_str is later improved to escape \n, change this test
    # to expect success.
    UCI_main_relay_url="$(printf 'https://evil.example.com\ninjected_key = "pwned"')"
    _UCI_VARS="$_UCI_VARS UCI_main_relay_url"
    start_service
    # The TOML should fail to parse (newline inside bare string).
    # If it somehow parses, the injected key must NOT exist.
    if python3 "$SCRIPT_DIR/validate_toml.py" < "$TOML_FILE" 2>/dev/null; then
        # Parsed successfully — injection must not have created a real key
        python3 "$SCRIPT_DIR/validate_toml.py" --check-absent injected_key < "$TOML_FILE"
        return $?
    fi
    # Parse failure is the expected (safe) outcome
    return 0
}

# ── Test: integer validation fallback ─────────────────────────────────
test_int_validation() {
    set_uci UCI_main_cache_capacity "abc"
    set_uci UCI_main_compute_budget "-5"
    start_service
    validate \
        --check cache_capacity 256 \
        --check compute_budget 100000
}

# ── Run ───────────────────────────────────────────────────────────────
printf "Running TOML generation tests...\n\n"
run_test test_defaults
run_test test_disabled
run_test test_relay_url_present
run_test test_relay_url_absent
run_test test_mdns_timeout_conditional
run_test test_tunnel_peers_and_ordering
run_test test_special_chars_in_strings
run_test test_newline_injection
run_test test_int_validation

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
