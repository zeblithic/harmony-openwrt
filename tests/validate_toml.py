#!/usr/bin/env python3
"""Validate TOML from stdin with optional key assertions.

Usage:
    cat config.toml | python3 validate_toml.py
    cat config.toml | python3 validate_toml.py --check key value --check-absent key2
    cat config.toml | python3 validate_toml.py --check-section "tunnels[0].node_id" value
"""
import argparse
import sys
import tomllib


def resolve_path(data: dict, path: str):
    """Resolve a dotted path with optional array indexing.

    Examples:
        "listen_address"        -> data["listen_address"]
        "tunnels[0].node_id"   -> data["tunnels"][0]["node_id"]
    """
    parts = path.replace("]", "").split("[")
    keys = []
    for part in parts:
        keys.extend(part.split("."))

    obj = data
    for key in keys:
        if key == "":
            continue
        try:
            idx = int(key)
            obj = obj[idx]
        except (ValueError, TypeError):
            obj = obj[key]
    return obj


def coerce(expected_str: str, actual):
    """Coerce expected string to match actual's type."""
    if isinstance(actual, bool):
        return expected_str.lower() in ("true", "1")
    if isinstance(actual, int):
        try:
            return int(expected_str)
        except ValueError:
            return expected_str
    if isinstance(actual, float):
        try:
            return float(expected_str)
        except ValueError:
            return expected_str
    return expected_str


def main():
    parser = argparse.ArgumentParser(description="Validate TOML from stdin")
    parser.add_argument(
        "--check", nargs=2, action="append", default=[],
        metavar=("KEY", "VALUE"),
        help="Assert a root-level key equals value (auto type coercion)",
    )
    parser.add_argument(
        "--check-absent", action="append", default=[],
        metavar="KEY",
        help="Assert a root-level key is NOT present",
    )
    parser.add_argument(
        "--check-section", nargs=2, action="append", default=[],
        metavar=("PATH", "VALUE"),
        help="Assert a nested path (e.g. tunnels[0].node_id) equals value",
    )
    args = parser.parse_args()

    raw = sys.stdin.buffer.read()
    try:
        data = tomllib.loads(raw.decode("utf-8"))
    except tomllib.TOMLDecodeError as e:
        print(f"TOML parse error: {e}", file=sys.stderr)
        sys.exit(1)

    errors = []

    for key, expected in args.check:
        if key not in data:
            errors.append(f"--check {key}: key not found in TOML")
            continue
        actual = data[key]
        expected_coerced = coerce(expected, actual)
        if actual != expected_coerced:
            errors.append(
                f"--check {key}: expected {expected_coerced!r}, got {actual!r}"
            )

    for key in args.check_absent:
        if key in data:
            errors.append(
                f"--check-absent {key}: key IS present (value={data[key]!r})"
            )

    for path, expected in args.check_section:
        try:
            actual = resolve_path(data, path)
        except (KeyError, IndexError, TypeError) as e:
            errors.append(f"--check-section {path}: path not found ({e})")
            continue
        expected_coerced = coerce(expected, actual)
        if actual != expected_coerced:
            errors.append(
                f"--check-section {path}: expected {expected_coerced!r}, got {actual!r}"
            )

    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
