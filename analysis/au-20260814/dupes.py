# dupes.py — cross-entity code collision scan: which canonical codes are claimed by >1 entity?
# Tracks CURRENT ownership (adds minus removes/nulls) per (entity, canonical code), streaming.
import csv, json, sys, collections

csv.field_size_limit(sys.maxsize)
OUT = "/private/tmp/claude-501/-Users-wardvanhooreweghe-workspace-ingot/efe31553-a87e-4c59-a781-30b5c24290a7/scratchpad"

GTIN = {"ean","gtin","eanGtin8","eanGtin12","eanGtin13","eanGtin14","undefinedEanGtinCode","usaGtinCode","upc10","upc11","upc12"}
OTHER_ID = {"fred","zcode","pbs_ignore"}  # fred/zcode are the AU national codes

def canon(base, val):
    if val is None: return None
    v = str(val)
    if v.startswith(base + "_"): v = v[len(base)+1:]
    if base in GTIN:
        v = "".join(c for c in v if c.isdigit())
        if not v or len(v) > 14: return None
        return ("gtin", v.zfill(14))
    return (base, v.strip())

# (code) -> {entity: last_state}  where state True=owned, False=removed
owner = collections.defaultdict(dict)
n = 0
with open("/Users/wardvanhooreweghe/Downloads/prod-lu-20260814.csv", newline="") as f:
    for row in csv.DictReader(f):
        n += 1
        ent = int(row["entity"])
        try: events = json.loads(row["events"])
        except json.JSONDecodeError: continue
        for tr in events:
            if not isinstance(tr, list) or len(tr) < 2: continue
            op, key = tr[0], tr[1]
            base = key.split(":", 1)[0] if isinstance(key, str) else ""
            if base not in GTIN and base not in {"fred","zcode"}: continue
            val = tr[2] if len(tr) > 2 else None
            if op in ("1","2"):            # set / add
                c = canon(base, val)
                if c: owner[c][ent] = True
            elif op == "3":                 # remove (value given)
                c = canon(base, val)
                if c: owner[c][ent] = False
            elif op == "4":                 # delete whole field: can't know which value w/o state; skip
                pass
        # note: 'set None' arrives as op 1 with null value -> canon returns None -> ignored;
        # that means a nulled code still counts as owned. Conservative: may overcount collisions.

live = {c: [e for e, on in ents.items() if on] for c, ents in owner.items()}
coll = {c: es for c, es in live.items() if len(es) > 1}
print(f"rows scanned: {n}")
print(f"distinct canonical identity codes: {len(owner)}")
print(f"codes ever claimed by >1 entity (live adds): {len(coll)}")
hist = collections.Counter(len(es) for es in coll.values())
print("collision size histogram:", dict(sorted(hist.items())))
sample = sorted(coll.items(), key=lambda kv: -len(kv[1]))[:15]
for c, es in sample:
    print(" ", c, "->", es[:8], "…" if len(es) > 8 else "")
json.dump({f"{s}:{v}": es for (s, v), es in coll.items()}, open(f"{OUT}/au_collisions.json","w"))
