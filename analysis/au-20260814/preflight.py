# preflight.py — one streaming pass over the delta CSV:
#  1. field-name census (diff against CodeRegistry)
#  2. per-entity identity-churn stats (to pick the quality cohort)
import csv, json, sys, collections

csv.field_size_limit(sys.maxsize)

CSV = "/Users/wardvanhooreweghe/Downloads/prod-lu-20260814.csv"
OUT = "/private/tmp/claude-501/-Users-wardvanhooreweghe-workspace-ingot/efe31553-a87e-4c59-a781-30b5c24290a7/scratchpad"

# CodeRegistry's :identity fields (lib/ingest/code_registry.ex)
IDENTITY = {
    "cnk","cipOrAcl7","acl13","cip13","pzn","pznAustria","sukl","pdk","cn","cefip",
    "nationalCode","ndc","hri","pin","fred","zcode","lppr",
    "ean","gtin","eanGtin8","eanGtin12","eanGtin13","eanGtin14",
    "undefinedEanGtinCode","usaGtinCode","upc10","upc11","upc12","isbn13","isbn10",
}
KNOWN = IDENTITY | {
    "cbId","ospId","offisanteId","cisCode","publicPageIdentifier","productId","hsCode","pbs",
    # decoder-local (gen.exs): media / edges / dropped meta
    "media","descriptions","publicCategories","brands","labos","internationalBrands",
    "medipimCategories","organizations","updatedAt","updatedBy","createdAt","createdBy","legacyId",
}

fields = collections.Counter()
# entity -> [n_deltas, id_codes(set of "field=value"), id_removes, first_ts, last_ts]
ents = {}

n = 0
with open(CSV, newline="") as f:
    r = csv.DictReader(f)
    for row in r:
        n += 1
        ent = int(row["entity"])
        ts = int(row["created_at"] or 0)
        st = ents.get(ent)
        if st is None:
            st = ents[ent] = [0, None, 0, ts, ts]
        st[0] += 1
        st[4] = max(st[4], ts)
        try:
            events = json.loads(row["events"])
        except json.JSONDecodeError:
            continue
        for tr in events:
            if not isinstance(tr, list) or len(tr) < 2:
                continue
            op, key = tr[0], tr[1]
            base = key.split(":", 1)[0] if isinstance(key, str) else str(key)
            fields[base] += 1
            if base in IDENTITY:
                val = tr[2] if len(tr) > 2 else None
                if st[1] is None:
                    st[1] = set()
                if op in ("3", "4"):          # remove / delete
                    st[2] += 1
                if val not in (None, ""):
                    st[1].add(f"{base}={val}")
        if n % 500000 == 0:
            print(f"  …{n} rows, {len(ents)} entities", file=sys.stderr)

print(f"rows: {n}   entities: {len(ents)}")

print("\n== FIELD CENSUS (count · known?) ==")
for name, c in fields.most_common():
    tag = "" if name in KNOWN else "   <-- UNKNOWN to CodeRegistry"
    print(f"  {c:>9}  {name}{tag}")

# churn stats
multi = {e: s for e, s in ents.items() if s[1] and len(s[1]) > 1}
removes = {e: s for e, s in ents.items() if s[2] > 0}
print(f"\nentities with >1 distinct identity code: {len(multi)}")
print(f"entities with identity removes/deletes:  {len(removes)}")

# cohort: all churny entities (multi codes or removes), ranked by churn, capped
churny = sorted(set(multi) | set(removes), key=lambda e: -(len(ents[e][1] or ()) + ents[e][2]))
import random
random.seed(422156)
normal = random.sample([e for e in ents if e not in set(churny)], min(150, len(ents)))
cohort = churny[:350] + normal

with open(f"{OUT}/cohort.json", "w") as f:
    json.dump(sorted(cohort), f)

with open(f"{OUT}/entity_stats.json", "w") as f:
    json.dump({str(e): [s[0], sorted(s[1] or []), s[2], s[3], s[4]] for e, s in ents.items() if e in set(cohort)}, f)

print(f"\ncohort written: {len(cohort)} entities ({min(350, len(churny))} churny + {len(normal)} random baseline)")
print("top churn examples:", churny[:10])
