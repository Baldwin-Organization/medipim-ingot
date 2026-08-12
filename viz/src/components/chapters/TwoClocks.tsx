import { AnimatePresence, motion } from "motion/react";
import type { ClockCell, ClocksScene } from "../../lib/story";

// Chapter 6 — the two clocks. A correction that arrived in April says the pack was different for
// nine days in February, so "what did we know" and "what was true" are separate questions. Every
// cell below is the engine's own answer for one (known_at, effective_at) pair (demo_export.exs).

function cellAt(scene: ClocksScene, knownAt: string, effectiveAt: string): ClockCell | undefined {
  return scene.cells.find((c) => c.knownAt === knownAt && c.effectiveAt === effectiveAt);
}

// One line per revision that actually shows up as an answer, so the grid's "rev N" cells are readable.
function legend(scene: ClocksScene) {
  const seen = new Map<string, string>();
  for (const cell of scene.cells) {
    if (cell.revision && cell.value && !seen.has(cell.revision)) seen.set(cell.revision, cell.value);
  }
  return [...seen.entries()].sort(([a], [b]) => a.localeCompare(b));
}

function Dial({
  label,
  hint,
  dates,
  active,
}: {
  label: string;
  hint: string;
  dates: string[];
  active: string;
}) {
  return (
    <div className="dial">
      <div className="dial-label">
        {label}
        <i>{hint}</i>
      </div>
      <div className="dial-track">
        {dates.map((date) => (
          <span key={date} className={`dial-stop${date === active ? " active" : ""}`}>
            {date}
            {date === active && (
              <motion.span className="dial-marker" layoutId={`marker-${label}`} transition={{ duration: 0.3 }} />
            )}
          </span>
        ))}
      </div>
    </div>
  );
}

export default function TwoClocks({ scene, step }: { scene: ClocksScene; step: number }) {
  const s = scene.steps[step];
  const answer = cellAt(scene, s.knownAt, s.effectiveAt);
  const rows = legend(scene);

  return (
    <div className="panel">
      <div className="readout">
        <b>{scene.label}</b> · supplier record <b>SUP-77120</b>
      </div>

      <div className="clocks-stage">
        <div className="clocks-left">
          <div className="panel-label">what the supplier sent</div>
          {scene.revisions.map((revision) => (
            <div key={revision.revision} className={`clock-revision rev-${revision.revision}`}>
              <div className="clock-revision-head">
                <span className="revision-num">rev {revision.revision}</span>
                <span className="clock-revision-recorded">received {revision.recordedAt}</span>
              </div>
              <div className="clock-revision-window">
                true from <b>{revision.validFrom}</b>
                {revision.validTo ? (
                  <>
                    {" "}
                    until <b>{revision.validTo}</b>
                  </>
                ) : (
                  " onwards"
                )}
              </div>
              {revision.facts
                .filter((f) => f.kind === "attribute")
                .map((f) => (
                  <div key={f.slot} className="clock-revision-fact">
                    {f.field} = <b>{String(f.value)}</b>
                  </div>
                ))}
            </div>
          ))}
          <p className="clocks-note">
            The correction arrived <b>two months late</b> and covers only nine days in February. Nothing was
            overwritten — both revisions stand.
          </p>
        </div>

        <div className="clocks-right">
          <Dial
            label="what we knew on"
            hint="when the question is asked"
            dates={scene.knownAxis}
            active={s.knownAt}
          />
          <Dial
            label="asking about"
            hint="the real-world date"
            dates={scene.effectiveAxis}
            active={s.effectiveAt}
          />

          <AnimatePresence mode="wait">
            <motion.div
              className="clock-answer"
              key={`${s.knownAt}/${s.effectiveAt}`}
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -10 }}
              transition={{ duration: 0.25 }}
            >
              <div className="panel-label gold-label">Ingot answers</div>
              <div className="clock-answer-value">{answer?.value ?? "no record applied"}</div>
              <div className="clock-answer-meta">
                {answer?.revision ? (
                  <>
                    from <b>rev {answer.revision}</b> · key <b>{answer.key}</b>
                  </>
                ) : (
                  "nothing applicable on that date"
                )}
              </div>
            </motion.div>
          </AnimatePresence>

          <div className="clock-grid-wrap">
            <div className="panel-label">every answer, precomputed by the engine</div>
            <table className="clock-grid">
              <thead>
                <tr>
                  <th className="clock-corner">
                    knew ↓ / asking →
                  </th>
                  {scene.effectiveAxis.map((e) => (
                    <th key={e}>{e}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {scene.knownAxis.map((k) => (
                  <tr key={k}>
                    <th>{k}</th>
                    {scene.effectiveAxis.map((e) => {
                      const cell = cellAt(scene, k, e);
                      const active = k === s.knownAt && e === s.effectiveAt;
                      return (
                        <td
                          key={e}
                          className={`clock-cell rev-${cell?.revision ?? "none"}${active ? " active" : ""}`}
                        >
                          {cell?.revision ? `rev ${cell.revision}` : "—"}
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="clock-legend">
              {rows.map(([revision, value]) => (
                <span key={revision} className={`clock-legend-item rev-${revision}`}>
                  rev {revision} = {value}
                </span>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
