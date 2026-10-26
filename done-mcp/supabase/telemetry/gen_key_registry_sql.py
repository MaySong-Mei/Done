#!/usr/bin/env python3 -I
"""key_registry.json -> key_registry_load.sql (idempotent upsert).

The registry's STRUCTURE lives in migrations/016_spike_runs_telemetry.sql; its
ROWS live only in key_registry.json (exported by the Swift tests, wire
contract §4) and reach the database through the SQL this script writes.
Nothing is hand-copied into a migration.

    python3 -I gen_key_registry_sql.py            # rewrite key_registry_load.sql
    python3 -I gen_key_registry_sql.py --check    # exit 1 if the SQL on disk is stale
    python3 -I gen_key_registry_sql.py --expect   # print a temp-table script for the checks (T11)

Standard library only. Validation (any failure exits 2 and writes nothing):
  * every entry has exactly the contract's nine fields;
  * key unique and non-empty; kind / family / value_schema from the contract's
    vocabularies; since_build a positive int; retired_build null or an int
    greater than since_build; spike_id non-empty; description a string;
  * liveness_key, when not null, names another key in the set whose
    value_schema is number (the views test it with > 0);
  * kind = histogram requires value_schema = fixed_string; kind = counter
    requires value_schema = number (counter_long casts counters to numeric);
    value_schema = number_list (wire v1.1: space-separated numbers) requires
    kind = gauge.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
JSON_PATH = os.path.join(HERE, "key_registry.json")
SQL_PATH = os.path.join(HERE, "key_registry_load.sql")

FIELDS = ("key", "kind", "family", "value_schema", "since_build",
          "retired_build", "liveness_key", "spike_id", "description")
KINDS = ("counter", "histogram", "gauge")
FAMILIES = ("fixwatch", "usage", "incident", "metrickit", "self")
VALUE_SCHEMAS = ("number", "fixed_string", "bool", "number_list")


def fail(msg):
    sys.stderr.write("gen_key_registry_sql: %s\n" % msg)
    sys.exit(2)


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, list) or not data:
        fail("top level must be a non-empty JSON array")
    return data


def validate(entries):
    seen = {}
    for i, e in enumerate(entries):
        where = "entry %d" % i
        if not isinstance(e, dict):
            fail("%s: not an object" % where)
        if tuple(sorted(e.keys())) != tuple(sorted(FIELDS)):
            fail("%s: fields must be exactly %s, got %s" % (where, sorted(FIELDS), sorted(e.keys())))
        key = e["key"]
        if not isinstance(key, str) or not key.strip():
            fail("%s: key must be a non-empty string" % where)
        if key in seen:
            fail("duplicate key %r (entries %d and %d)" % (key, seen[key], i))
        seen[key] = i
        where = "key %r" % key
        if e["kind"] not in KINDS:
            fail("%s: kind %r not in %s" % (where, e["kind"], KINDS))
        if e["family"] not in FAMILIES:
            fail("%s: family %r not in %s" % (where, e["family"], FAMILIES))
        if e["value_schema"] not in VALUE_SCHEMAS:
            fail("%s: value_schema %r not in %s" % (where, e["value_schema"], VALUE_SCHEMAS))
        sb = e["since_build"]
        if isinstance(sb, bool) or not isinstance(sb, int) or sb < 1:
            fail("%s: since_build must be a positive integer" % where)
        rb = e["retired_build"]
        if rb is not None and (isinstance(rb, bool) or not isinstance(rb, int) or rb <= sb):
            fail("%s: retired_build must be null or an integer > since_build" % where)
        if not isinstance(e["spike_id"], str) or not e["spike_id"].strip():
            fail("%s: spike_id must be a non-empty string" % where)
        if not isinstance(e["description"], str):
            fail("%s: description must be a string" % where)
        lk = e["liveness_key"]
        if lk is not None and not isinstance(lk, str):
            fail("%s: liveness_key must be null or a string" % where)
        if e["value_schema"] == "number_list" and e["kind"] != "gauge":
            fail("%s: a number_list is a gauge" % where)
        if e["kind"] == "histogram" and e["value_schema"] != "fixed_string":
            fail("%s: a histogram is a fixed_string" % where)
        if e["kind"] == "counter" and e["value_schema"] != "number":
            fail("%s: a counter is a number" % where)
    by_key = {e["key"]: e for e in entries}
    for e in entries:
        lk = e["liveness_key"]
        if lk is None:
            continue
        if lk not in by_key:
            fail("key %r: liveness_key %r is not in the set" % (e["key"], lk))
        if lk == e["key"]:
            fail("key %r: liveness_key names itself" % e["key"])
        if by_key[lk]["value_schema"] != "number":
            fail("key %r: liveness_key %r must have value_schema number" % (e["key"], lk))


def lit(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def row(e):
    return "  (%s)" % ", ".join(lit(e[f]) for f in FIELDS)


def render_load(entries):
    out = []
    out.append("-- GENERATED by gen_key_registry_sql.py from key_registry.json — do not edit.")
    out.append("-- Idempotent upsert of the key registry (wire contract §4). Applied after")
    out.append("-- migration 016 (structure); a rerun changes nothing when the JSON did not.")
    out.append("-- One statement, so a liveness_key that points forward in the list resolves")
    out.append("-- at statement end (the self-reference is a plain, non-deferrable FK).")
    out.append("-- Retired keys stay (retired_build set); this file never deletes a row.")
    out.append("-- %d keys." % len(entries))
    out.append("insert into public.key_registry (%s) values" % ", ".join(FIELDS))
    out.append(",\n".join(row(e) for e in entries))
    out.append("on conflict (key) do update set")
    out.append(",\n".join("  %s = excluded.%s" % (f, f) for f in FIELDS if f != "key"))
    out.append("where (%s) is distinct from (%s);" % (
        ", ".join("public.key_registry.%s" % f for f in FIELDS if f != "key"),
        ", ".join("excluded.%s" % f for f in FIELDS if f != "key")))
    return "\n".join(out) + "\n"


def render_expect(entries):
    """A psql snippet the checks runner prepends: the JSON as a temp table."""
    out = []
    out.append("-- GENERATED by gen_key_registry_sql.py --expect: the JSON as the oracle for T11.")
    out.append("create temp table expected_key_registry (like public.key_registry including defaults);")
    out.append("insert into expected_key_registry (%s) values" % ", ".join(FIELDS))
    out.append(",\n".join(row(e) for e in entries) + ";")
    return "\n".join(out) + "\n"


def main(argv):
    mode = argv[1] if len(argv) > 1 else "--write"
    if mode not in ("--write", "--check", "--expect"):
        fail("usage: gen_key_registry_sql.py [--write | --check | --expect]")
    entries = load(JSON_PATH)
    validate(entries)
    if mode == "--expect":
        sys.stdout.write(render_expect(entries))
        return 0
    sql = render_load(entries)
    if mode == "--check":
        try:
            with open(SQL_PATH, "r", encoding="utf-8") as fh:
                on_disk = fh.read()
        except FileNotFoundError:
            on_disk = None
        if on_disk != sql:
            sys.stderr.write("gen_key_registry_sql: %s is stale; rerun without --check\n" % SQL_PATH)
            return 1
        print("key_registry_load.sql is current (%d keys)" % len(entries))
        return 0
    with open(SQL_PATH, "w", encoding="utf-8") as fh:
        fh.write(sql)
    print("wrote %s (%d keys)" % (SQL_PATH, len(entries)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
