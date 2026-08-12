import { AnimatePresence, motion } from "motion/react";
import type {
  AttributeView,
  ClaimView,
  GoldenView,
  QueueItem,
  StoryEvent,
  StoryStep,
  TierView,
} from "../../lib/story";

export const chipClass = (code: string) =>
  code.startsWith("cnk:") ? "chip cnk" : code.startsWith("gtin:") ? "chip gtin" : "chip";

export function Chip({ code, className = "" }: { code: string; className?: string }) {
  return <span className={`${chipClass(code)} ${className}`.trim()}>{code}</span>;
}

// ── the claim log: immutable, source-attributed, append-only ───────────────────────────────────────
function claimBody(c: ClaimView) {
  if (c.kind === "identity") {
    return (
      <>
        lists <b>{c.ref}</b> under {c.codes?.map((code) => <Chip key={code} code={code} />)}
      </>
    );
  }
  if (c.kind === "attribute") {
    return (
      <>
        says {c.code && <Chip code={c.code} />} has <b>{c.field}</b> = <b>{String(c.value)}</b>
      </>
    );
  }
  // A steward's approved merge asserts its own evidence claim — the reason lands in the log too.
  if (c.kind === "identity_evidence") {
    return (
      <>
        asserts {c.left && <Chip code={c.left} />} and {c.right && <Chip code={c.right} />} are the{" "}
        <b>{c.relation ?? "same"}</b> product
      </>
    );
  }
  return (
    <>
      attaches <b>{c.asset}</b> to {c.target && <Chip code={c.target} />}
    </>
  );
}

export function ClaimLog({ log, newFrom }: { log: ClaimView[]; newFrom: number }) {
  return (
    <div className="claim-log">
      <div className="panel-label">claim log — append-only, never edited</div>
      <AnimatePresence initial={false}>
        {log.map((c, i) => (
          <motion.div
            key={c.order}
            className={`claim-card${i >= newFrom ? " fresh" : ""}`}
            layout
            initial={{ opacity: 0, x: -18 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ duration: 0.3 }}
          >
            <span className="claim-source">{c.source}</span>
            <span className="claim-date">{c.date}</span>
            <div className="claim-body">{claimBody(c)}</div>
          </motion.div>
        ))}
      </AnimatePresence>
    </div>
  );
}

// ── the golden projection: derived from the log, never stored ─────────────────────────────────────
function statusBadge(status: AttributeView["status"]) {
  if (status === "needs_review") return <span className="attr-status review">⚠ steward</span>;
  if (status === "resolved_by_steward") return <span className="attr-status steward">✓ steward</span>;
  return null;
}

export function AttributeRow({ attr, focus }: { attr: AttributeView; focus?: boolean }) {
  const contested = attr.candidates.length > 1;
  // A top-tier tie has NO winner — the engine refuses to decide. Don't show its provisional
  // value as if it won; show the tie itself and let the steward queue carry the resolution.
  const undecided = attr.status === "needs_review";
  return (
    <motion.div className={`attr-row${focus ? " focus" : ""}${undecided ? " undecided" : ""}`} layout>
      <div className="attr-main">
        <span className="attr-field">{attr.field}</span>
        {undecided ? (
          <motion.span
            className="attr-undecided"
            key="undecided"
            initial={{ opacity: 0, y: -6 }}
            animate={{ opacity: 1, y: 0 }}
          >
            undecided
          </motion.span>
        ) : (
          <motion.b
            className="attr-value"
            key={String(attr.value)}
            initial={{ opacity: 0, y: -6 }}
            animate={{ opacity: 1, y: 0 }}
          >
            {String(attr.value)}
          </motion.b>
        )}
        {!undecided && attr.winner && <span className="attr-winner">← {attr.winner}</span>}
        {statusBadge(attr.status)}
      </div>
      {contested && (
        <div className="attr-candidates">
          {attr.candidates.map((c, i) => (
            <span key={c.source} className="candidate-wrap">
              {undecided && i > 0 && <span className="vs">vs</span>}
              <span
                className={`candidate${!undecided && c.source === attr.winner ? " winner" : ""}${
                  undecided ? " tied" : ""
                }`}
              >
                {c.source}: {String(c.value)}
              </span>
            </span>
          ))}
        </div>
      )}
    </motion.div>
  );
}

export function GoldenCard({ golden, focusField }: { golden: GoldenView; focusField?: string }) {
  return (
    <motion.div
      className="card golden-card"
      layout
      layoutId={golden.key}
      initial={{ opacity: 0, scale: 0.92 }}
      animate={{ opacity: 1, scale: 1 }}
      exit={{ opacity: 0, scale: 0.92 }}
      transition={{ duration: 0.35 }}
    >
      <div className="card-key">
        golden <b>{golden.key}</b> <span className="derived-tag">derived</span>
      </div>
      <div className="chips">
        {golden.codes.map((c) => (
          <Chip key={c} code={c} />
        ))}
      </div>
      <div className="attrs">
        {golden.attributes.map((a) => (
          <AttributeRow key={a.field} attr={a} focus={a.field === focusField} />
        ))}
      </div>
      {golden.media.length > 0 && (
        <div className="media-row">
          {golden.media.map((m) => (
            <span key={m.asset} className="media-tag" title={m.uri}>
              ▣ {m.asset} <i>({m.source})</i>
            </span>
          ))}
        </div>
      )}
    </motion.div>
  );
}

// ── the open steward queue ─────────────────────────────────────────────────────────────────────────
export function QueuePanel({ queue }: { queue: QueueItem[] }) {
  return (
    <AnimatePresence>
      {queue.length > 0 && (
        <motion.div
          className="queue-panel"
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: 10 }}
        >
          <div className="panel-label flag-label">steward queue — the engine won't guess</div>
          {queue.map((q, i) => (
            <div key={i} className="queue-item">
              {q.type === "attr" ? (
                <>
                  ⚠ <b>{q.field}</b> on <b>{q.key}</b> — top-tier tie:{" "}
                  {q.candidates.map((c) => `${c.source} says ${c.value}`).join(" vs ")}
                </>
              ) : (
                <>
                  ⚠ merge proposed: <b>{q.keys.join(" + ")}</b> — gated for review
                </>
              )}
            </div>
          ))}
        </motion.div>
      )}
    </AnimatePresence>
  );
}

// ── the trust tiers: the ranking the engine resolves with, visible so the reasoning is on screen ──
export function TierPanel({ tiers, focusField }: { tiers: TierView[]; focusField?: string }) {
  // the focused field uses its own row if it has one, otherwise the default row decides it
  const hasOwnRow = tiers.some((t) => t.dimension === focusField);
  const rowFocused = (t: TierView) =>
    focusField != null && (t.dimension === focusField || (!hasOwnRow && t.dimension === "default"));
  return (
    <div className="tier-panel">
      <div className="panel-label">trust tiers — higher tier wins; sources in ONE tier are equal</div>
      {tiers.map((t) => (
        <div key={t.dimension} className={`tier-row${rowFocused(t) ? " focus" : ""}`}>
          <span className="tier-dim">{t.dimension === "default" ? "all other fields" : t.dimension}</span>
          <span className="tier-chain">
            {t.tiers.map((tier, i) => (
              <span key={i} className="tier-group">
                {i > 0 && <span className="tier-sep">≻</span>}
                <span className={`tier-box${tier.length > 1 ? " tied" : ""}`}>{tier.join(" = ")}</span>
              </span>
            ))}
          </span>
        </div>
      ))}
    </div>
  );
}

// ── this beat's engine events, as a strip of badges ───────────────────────────────────────────────
function eventText(e: StoryEvent) {
  switch (e.type) {
    case "MINT":
      return `MINT ${e.key}`;
    case "MEMBERS":
      return `MEMBERS ${e.key}`;
    case "MERGE":
      return `MERGE ${e.from.join("+")} → ${e.into}`;
    case "SPLIT":
      return `SPLIT ${e.key} → ${e.into.map((p) => p.key).join(", ")}`;
    case "FLAG":
      return `FLAG ${e.keys.join("+")}`;
    case "DECISION":
      return `DECISION ${e.subject}: ${e.decision} — by ${e.by}`;
  }
}

export function EventStrip({ events }: { events: StoryEvent[] }) {
  if (events.length === 0) return null;
  return (
    <div className="event-strip">
      {events.map((e, i) => (
        <motion.span
          key={i}
          className={`event-badge ${e.type.toLowerCase()}`}
          initial={{ opacity: 0, scale: 0.8 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ delay: i * 0.12 }}
        >
          {eventText(e)}
        </motion.span>
      ))}
    </div>
  );
}

// ── the canonical engine-chapter layout: log on the left, fold to golden on the right ─────────────
export function EngineStage({
  step,
  prevStep,
  focusField,
  tiers,
}: {
  step: StoryStep;
  prevStep?: StoryStep;
  focusField?: string;
  tiers?: TierView[];
}) {
  return (
    <div className="engine-stage">
      <ClaimLog log={step.log} newFrom={prevStep ? prevStep.log.length : 0} />
      <div className="fold-arrow" aria-hidden="true">
        <span>fold</span>⟶
      </div>
      <div className="golden-side">
        <div className="panel-label gold-label">golden — a projection of the log</div>
        <div className="golden-stack">
          <AnimatePresence mode="popLayout">
            {step.golden.map((g) => (
              <GoldenCard key={g.key} golden={g} focusField={focusField} />
            ))}
          </AnimatePresence>
        </div>
        <QueuePanel queue={step.queue} />
        {tiers && <TierPanel tiers={tiers} focusField={focusField} />}
        <EventStrip events={step.events} />
      </div>
    </div>
  );
}
