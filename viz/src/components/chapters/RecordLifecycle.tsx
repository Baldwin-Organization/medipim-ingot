import { AnimatePresence, motion } from "motion/react";
import type { RecordFact, RecordScene, RevisionView } from "../../lib/story";
import { Chip, GoldenCard } from "./shared";

// Chapter 4 — one upstream record, revised over time. The source owns its own record and says how
// each revision applies; Ingot keeps every version and never loses the identity. Every snapshot is
// real engine output (demo_export.exs drives SourceRecords + History.project_bitemporal).

const OPERATION_BLURB: Record<RevisionView["operation"], string> = {
  replace: "the whole record, as the source sent it",
  patch: "only the named facts change — the rest is carried over",
  withdraw: "delisted — this revision publishes nothing",
  reactivate: "back again, as a whole fresh record",
};

function factLabel(fact: RecordFact) {
  if (fact.kind === "identity") return "codes";
  if (fact.kind === "attribute") return String(fact.field);
  return String(fact.asset ?? fact.slot);
}

function factValue(fact: RecordFact) {
  if (fact.kind === "identity") {
    return <>{fact.codes?.map((code) => <Chip key={code} code={code} />)}</>;
  }
  if (fact.kind === "attribute") return <b>{String(fact.value)}</b>;
  return <span className="media-tag">▣ {fact.asset}</span>;
}

// Superseded revisions collapse to one line: they are still on screen (nothing is ever replaced)
// without pushing the revision that actually governs today out of view.
function summarize(revision: RevisionView) {
  if (!revision.active) return "delisted — published nothing";
  const changed = revision.facts.filter((f) => f.changed).map(factLabel);
  if (changed.length === 0) return `${revision.facts.length} facts`;
  return `changed ${changed.join(", ")}`;
}

function Revision({ revision, current }: { revision: RevisionView; current: boolean }) {
  return (
    <motion.div
      className={`revision-card${current ? " current" : " past"}${revision.active ? "" : " withdrawn"}`}
      layout
      initial={{ opacity: 0, x: -18 }}
      animate={{ opacity: 1, x: 0 }}
      transition={{ duration: 0.3 }}
    >
      <div className="revision-head">
        <span className="revision-num">rev {revision.revision}</span>
        <span className={`revision-op ${revision.operation}`}>{revision.operation}</span>
        {current && <span className="revision-governs">governs today</span>}
      </div>
      <div className="revision-dates">
        received {revision.recordedAt} · applies from {revision.validFrom}
        {revision.validTo && ` until ${revision.validTo}`}
      </div>

      {current ? (
        <>
          <div className="revision-blurb">{OPERATION_BLURB[revision.operation]}</div>
          <div className="revision-facts">
            {revision.facts.map((fact) => (
              <div key={fact.slot} className={`revision-fact${fact.changed ? " changed" : ""}`}>
                <span className="fact-label">{factLabel(fact)}</span>
                <span className="fact-value">{factValue(fact)}</span>
                {fact.changed && <span className="fact-changed">changed</span>}
              </div>
            ))}
          </div>
        </>
      ) : (
        <div className="revision-summary">{summarize(revision)}</div>
      )}
    </motion.div>
  );
}

export default function RecordLifecycle({ scene, step }: { scene: RecordScene; step: number }) {
  const s = scene.steps[step];
  const published = s.golden.length > 0;

  return (
    <div className="panel">
      <div className="readout">
        <b>{scene.label}</b> · supplier record <b>SUP-88431</b> · as-of <b>{s.date}</b>
      </div>

      <div className="record-stage">
        <div className="revision-stack">
          <div className="panel-label">the source's record — every revision kept, none replaced</div>
          <AnimatePresence initial={false}>
            {s.revisions.map((revision) => (
              <Revision key={revision.revision} revision={revision} current={revision.revision === s.current} />
            ))}
          </AnimatePresence>
        </div>

        <div className="fold-arrow" aria-hidden="true">
          <span>fold</span>⟶
        </div>

        <div className="golden-side">
          <div className="panel-label gold-label">what Ingot publishes today</div>
          <div className="golden-stack">
            <AnimatePresence mode="popLayout">
              {s.golden.map((g) => (
                <GoldenCard key={g.key} golden={g} />
              ))}
              {!published && (
                <motion.div
                  key="nothing"
                  className="card nothing-card"
                  initial={{ opacity: 0, scale: 0.94 }}
                  animate={{ opacity: 1, scale: 1 }}
                  exit={{ opacity: 0, scale: 0.94 }}
                >
                  <div className="nothing-title">nothing published</div>
                  <div className="nothing-body">
                    The record is withdrawn, so it contributes no codes, no attributes, no images.
                  </div>
                </motion.div>
              )}
            </AnimatePresence>
          </div>

          {s.boundKey && (
            <div className="binding-panel">
              <span className="panel-label">permanent binding</span>
              <div className="binding-body">
                this record is bound to <b>{s.boundKey}</b> —{" "}
                {published
                  ? "every revision resolves to that same key, whatever codes it carries"
                  : "remembered even now, while the record publishes nothing"}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
