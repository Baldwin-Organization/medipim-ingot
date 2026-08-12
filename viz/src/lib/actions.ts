// The story is action-driven: the "advance" button IS the operation that produces the next beat —
// the presenter (or viewer) runs the import, or acts as the steward. Keyed by the step the action
// leads INTO ("chapterId/targetStepId"). Steps without an entry fall back to the shell's default
// (entering a chapter, embedded scenes).

export type ActionKind = "import" | "steward" | "watch";

export interface StepAction {
  label: string;
  kind: ActionKind;
}

const ACTIONS: Record<string, StepAction> = {
  // 1 — the old way (illustration)
  "oldWay/match": { label: "Run the matcher", kind: "watch" },
  "oldWay/merge": { label: "Merge the records — the old way", kind: "import" },
  "oldWay/import": { label: "Run the next import", kind: "import" },

  // 2 — claims, not records
  "claims/first-attribute": { label: "Import: manufacturer says weight 250 g", kind: "import" },
  "claims/second-source": { label: "Import: a supplier listing arrives", kind: "import" },
  "claims/media": { label: "Import: supplier attaches an image", kind: "import" },

  // 3 — who wins?
  "priority/marketplace-weight": { label: "Import: marketplace says 300 g", kind: "import" },
  "priority/supplier-weight": { label: "Import: supplier says 260 g", kind: "import" },
  "priority/manufacturer-weight": { label: "Import: manufacturer says 250 g", kind: "import" },
  "priority/color-tie": { label: "Import: white vs ivory arrive", kind: "import" },
  "priority/steward-pick": { label: "Steward: resolve the colour tie", kind: "steward" },

  // 4 — the record keeps changing
  "record/v2-patch": { label: "Revision 2: the supplier patches the weight", kind: "import" },
  "record/v3-withdraw": { label: "Revision 3: the supplier delists it", kind: "import" },
  "record/v4-reactivate": { label: "Revision 4: it returns with new barcodes", kind: "import" },

  // 6 — two clocks
  "clocks/before-correction": { label: "Ask about 5 February — from March", kind: "watch" },
  "clocks/after-correction": { label: "Ask the same question again in April", kind: "watch" },
  "clocks/window-closed": { label: "Ask about 10 February instead", kind: "watch" },

  // 7 — the guard
  "guard/bridge": { label: "Import: the same barcode arrives on both", kind: "import" },

  // 8 — the mistake is cheap
  "mistake/wrong-merge": { label: "Steward: approve the merge", kind: "steward" },
  "mistake/contradiction": { label: "Look closer at the fused weights", kind: "watch" },
  "mistake/split": { label: "Steward: split BOLT back out", kind: "steward" },
  "mistake/healed": { label: "Re-project the golden records", kind: "watch" },
};

export function actionInto(chapterId: string, stepId: string): StepAction | undefined {
  return ACTIONS[`${chapterId}/${stepId}`];
}
