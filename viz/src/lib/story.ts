// Mirrors the shape `demo_export.exs` writes to src/data/story.json.
// The browser reimplements NO engine logic — every snapshot below is precomputed by the engine.

export interface CandidateView {
  source: string;
  value: string | number;
}

export type ClaimKind = "identity" | "attribute" | "media" | "identity_evidence";

export interface ClaimView {
  order: number;
  source: string;
  kind: ClaimKind;
  date: string;
  // identity
  ref?: string;
  codes?: string[];
  // attribute
  code?: string;
  field?: string;
  value?: string | number;
  // media
  asset?: string;
  target?: string;
  uri?: string;
  // identity_evidence — a steward's recorded reason for merging
  left?: string;
  right?: string;
  relation?: string;
  by?: string;
  reason?: string | null;
}

export interface AttributeView {
  field: string;
  value: string | number;
  winner: string | null; // a source, or "steward:<name>"
  status: "resolved" | "needs_review" | "resolved_by_steward";
  candidates: CandidateView[]; // the full ranking, best first
}

export interface MediaView {
  asset: string;
  source: string;
  uri: string;
}

export interface GoldenView {
  key: string;
  codes: string[];
  attributes: AttributeView[];
  media: MediaView[];
}

export type QueueItem =
  | { type: "attr"; key: string; field: string; candidates: CandidateView[] }
  | { type: "merge"; keys: string[] };

export type StoryEvent =
  | { date: string; type: "MINT" | "MEMBERS"; key: string; codes: string[] }
  | { date: string; type: "MERGE"; from: string[]; into: string }
  | { date: string; type: "SPLIT"; key: string; kept: string[]; into: { key: string; codes: string[] }[] }
  | { date: string; type: "FLAG"; keys: string[] }
  | { date: string; type: "DECISION"; subject: string; decision: string; by: string };

export interface StoryStep {
  id: string;
  date: string;
  log: ClaimView[]; // the full append-only claim log, as of this beat
  events: StoryEvent[]; // what THIS beat emitted
  golden: GoldenView[]; // the projection — derived, never stored
  queue: QueueItem[]; // the open steward queue
}

// One row of the scene's trust ranking, straight from the engine's Priority struct.
// "default" applies to every field without its own row. Sources inside one tier are EQUAL.
export interface TierView {
  dimension: string;
  tiers: string[][];
}

export interface EngineScene {
  label: string;
  tiers: TierView[];
  steps: StoryStep[];
}

// The one hand-authored scene: destructive merging is what the engine refuses to do,
// so it cannot be engine-exported. The viz labels it an illustration.
export interface OldWayRecord {
  source: string | null;
  code?: string;
  codes?: string[];
  name: string;
  weight_g: number;
  image: string;
}

export interface OldWayStep {
  id: string;
  a?: OldWayRecord;
  b?: OldWayRecord;
  matchedOn?: string;
  merged?: OldWayRecord;
  lost?: string[];
}

export interface OldWayScene {
  label: string;
  steps: OldWayStep[];
}

// ── one upstream record, revised over time ────────────────────────────────────────────────────────
// A record is addressed by {source, ref}. Each revision stores its COMPLETE snapshot, so `changed`
// is a diff the exporter computed against the previous revision — the browser diffs nothing.
export type RecordOperation = "replace" | "patch" | "withdraw" | "reactivate";

export interface RecordFact {
  slot: string;
  kind: ClaimKind;
  changed: boolean;
  ref?: string;
  codes?: string[];
  code?: string;
  field?: string;
  value?: string | number;
  asset?: string;
  target?: string;
  uri?: string;
}

export interface RevisionView {
  revision: string;
  operation: RecordOperation;
  active: boolean;
  recordedAt: string;
  validFrom: string;
  validTo: string | null;
  facts: RecordFact[];
}

export interface RecordStep {
  id: string;
  date: string;
  revisions: RevisionView[]; // every revision so far — nothing is ever replaced in place
  current: string; // the revision governing this beat
  boundKey: string | null; // the permanent record→key binding, remembered even while withdrawn
  golden: GoldenView[]; // empty while the record is withdrawn: nothing is published
}

export interface RecordScene {
  label: string;
  tiers: TierView[];
  steps: RecordStep[];
}

// ── two clocks: what we knew, and when it was true ────────────────────────────────────────────────
// Every cell is the engine's own answer for one (known_at, effective_at) pair.
export interface ClockCell {
  knownAt: string;
  effectiveAt: string;
  revision: string | null; // which revision governed that answer
  key: string | null;
  value: string | null; // null when no record applied
}

export interface ClockStep {
  id: string;
  knownAt: string;
  effectiveAt: string;
}

export interface ClocksScene {
  label: string;
  revisions: RevisionView[];
  knownAxis: string[];
  effectiveAxis: string[];
  cells: ClockCell[];
  steps: ClockStep[];
}

export interface StoryData {
  oldWay: OldWayScene;
  claims: EngineScene;
  priority: EngineScene;
  record: RecordScene;
  clocks: ClocksScene;
  mistake: EngineScene;
}
