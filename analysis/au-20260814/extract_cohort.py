# extract_cohort.py — second streaming pass: write one raw.jsonl per cohort entity
import csv, json, sys, os

csv.field_size_limit(sys.maxsize)
OUT = "/private/tmp/claude-501/-Users-wardvanhooreweghe-workspace-ingot/efe31553-a87e-4c59-a781-30b5c24290a7/scratchpad"
RAW = f"{OUT}/au_raw"
os.makedirs(RAW, exist_ok=True)

cohort = set(json.load(open(f"{OUT}/cohort.json")))
handles = {}
n_rows = 0
n_entities = set()

with open("/Users/wardvanhooreweghe/Downloads/prod-lu-20260814.csv", newline="") as f:
    for row in csv.DictReader(f):
        n_rows += 1
        ent = int(row["entity"])
        n_entities.add(ent)
        if ent not in cohort:
            continue
        h = handles.get(ent)
        if h is None:
            h = handles[ent] = open(f"{RAW}/medipim_au_{ent}.raw.jsonl", "w")
        h.write(json.dumps({
            "id": int(row["id"]), "entity": ent,
            "events": json.loads(row["events"]),
            "tag": row["tag"], "created_at": int(row["created_at"]) if row["created_at"] not in ("", "NULL") else 0,
            "created_by": int(row["created_by"]) if row["created_by"] not in ("", "NULL") else None,
        }) + "\n")

for h in handles.values():
    h.close()
print(f"total rows: {n_rows}, total entities in export: {len(n_entities)}")
print(f"cohort files written: {len(handles)}")
