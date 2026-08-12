import { describe, expect, it } from "vitest";
import { advance, flatIndex, jumpTo, totalSteps } from "./steps";
import data from "../data/story.json";
import type { StoryData } from "./story";

const COUNTS = [4, 3, 2]; // a 3-chapter story

describe("advance", () => {
  it("moves within a chapter", () => {
    expect(advance({ chapter: 0, step: 1 }, 1, COUNTS)).toEqual({ chapter: 0, step: 2 });
    expect(advance({ chapter: 0, step: 2 }, -1, COUNTS)).toEqual({ chapter: 0, step: 1 });
  });

  it("overflows into the next chapter's first step", () => {
    expect(advance({ chapter: 0, step: 3 }, 1, COUNTS)).toEqual({ chapter: 1, step: 0 });
  });

  it("underflows into the previous chapter's last step", () => {
    expect(advance({ chapter: 1, step: 0 }, -1, COUNTS)).toEqual({ chapter: 0, step: 3 });
  });

  it("clamps at both ends of the story", () => {
    expect(advance({ chapter: 0, step: 0 }, -1, COUNTS)).toEqual({ chapter: 0, step: 0 });
    expect(advance({ chapter: 2, step: 1 }, 1, COUNTS)).toEqual({ chapter: 2, step: 1 });
  });
});

describe("jumpTo", () => {
  it("jumps to a chapter's first step, clamped to the story", () => {
    expect(jumpTo(1, COUNTS)).toEqual({ chapter: 1, step: 0 });
    expect(jumpTo(99, COUNTS)).toEqual({ chapter: 2, step: 0 });
    expect(jumpTo(-1, COUNTS)).toEqual({ chapter: 0, step: 0 });
  });
});

describe("flatIndex / totalSteps", () => {
  it("flattens positions for the progress readout", () => {
    expect(flatIndex({ chapter: 0, step: 0 }, COUNTS)).toBe(0);
    expect(flatIndex({ chapter: 1, step: 2 }, COUNTS)).toBe(6);
    expect(flatIndex({ chapter: 2, step: 1 }, COUNTS)).toBe(8);
    expect(totalSteps(COUNTS)).toBe(9);
  });
});

// The committed story.json matches what the chapter components expect — a drifted export fails here.
describe("story.json schema", () => {
  const story = data as unknown as StoryData;

  it("has the six scenes with their story beats", () => {
    expect(story.oldWay.steps.map((s) => s.id)).toEqual(["two-records", "match", "merge", "import"]);
    expect(story.claims.steps.map((s) => s.id)).toEqual([
      "first-claim",
      "first-attribute",
      "second-source",
      "media",
    ]);
    expect(story.priority.steps.map((s) => s.id)).toEqual([
      "one-product",
      "marketplace-weight",
      "supplier-weight",
      "manufacturer-weight",
      "color-tie",
      "steward-pick",
    ]);
    expect(story.record.steps.map((s) => s.id)).toEqual([
      "v1-replace",
      "v2-patch",
      "v3-withdraw",
      "v4-reactivate",
    ]);
    expect(story.clocks.steps.map((s) => s.id)).toEqual([
      "ask-january",
      "before-correction",
      "after-correction",
      "window-closed",
    ]);
    expect(story.mistake.steps.map((s) => s.id)).toEqual([
      "two-products",
      "wrong-merge",
      "contradiction",
      "split",
      "healed",
    ]);
  });

  it("every engine scene exposes its trust tiers (the engine's actual Priority)", () => {
    for (const scene of [story.claims, story.priority, story.mistake]) {
      expect(scene.tiers.length).toBeGreaterThan(0);
      for (const row of scene.tiers) {
        expect(typeof row.dimension).toBe("string");
        expect(row.tiers.length).toBeGreaterThan(0);
      }
    }
    expect(story.priority.tiers).toContainEqual({
      dimension: "color",
      tiers: [["manufacturer", "supplier"], ["marketplace"]],
    });
  });

  it("every engine step carries log, events, golden, and queue", () => {
    for (const scene of [story.claims, story.priority, story.mistake]) {
      for (const step of scene.steps) {
        expect(step.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
        expect(Array.isArray(step.log)).toBe(true);
        expect(Array.isArray(step.events)).toBe(true);
        expect(Array.isArray(step.golden)).toBe(true);
        expect(Array.isArray(step.queue)).toBe(true);
        expect(step.golden.length).toBeGreaterThan(0);
      }
    }
  });

  it("the record scene keeps one key across the withdrawal and the re-listing", () => {
    const byId = Object.fromEntries(story.record.steps.map((s) => [s.id, s]));
    expect(story.record.steps.every((s) => s.boundKey === "SK_1")).toBe(true);

    // withdrawn: nothing is published, yet the binding is still on screen
    expect(byId["v3-withdraw"].golden).toEqual([]);
    expect(byId["v3-withdraw"].revisions.at(-1)?.active).toBe(false);

    // re-listed under entirely different codes — same key, so customers' links survive
    const back = byId["v4-reactivate"].golden;
    expect(back).toHaveLength(1);
    expect(back[0].key).toBe("SK_1");
    expect(back[0].codes).toEqual(["cnk:1000914", "gtin:05012345679907"]);

    // a patch changes the named fact only
    const patched = byId["v2-patch"].revisions.at(-1);
    expect(patched?.operation).toBe("patch");
    expect(patched?.facts.filter((f) => f.changed).map((f) => f.slot)).toEqual(["attribute:weight_g"]);
  });

  it("the two-clock beats answer exactly what the narration claims", () => {
    const answer = (id: string) => {
      const beat = story.clocks.steps.find((s) => s.id === id)!;
      return story.clocks.cells.find(
        (c) => c.knownAt === beat.knownAt && c.effectiveAt === beat.effectiveAt,
      )!;
    };

    expect(answer("ask-january").value).toBe("Zinc oxide paste 30 g");
    // same real-world date, two different knowledge points -> two different answers
    expect(answer("before-correction").value).toBe("Zinc oxide paste 30 g");
    expect(answer("after-correction").value).toBe("Zinc oxide paste 50 g — promo pack");
    // the correction's interval is half-open, so its end date falls back to the original
    expect(answer("window-closed").value).toBe("Zinc oxide paste 30 g");

    // the grid is complete, and identity never wobbles across the correction
    expect(story.clocks.cells).toHaveLength(
      story.clocks.knownAxis.length * story.clocks.effectiveAxis.length,
    );
    expect(new Set(story.clocks.cells.map((c) => c.key))).toEqual(new Set(["SK_1"]));
  });

  it("the mistake arc's pivotal beats are present in the data", () => {
    const byId = Object.fromEntries(story.mistake.steps.map((s) => [s.id, s]));
    expect(byId["two-products"].golden).toHaveLength(2);
    expect(byId["wrong-merge"].golden).toHaveLength(1);
    expect(byId["contradiction"].queue).toEqual([
      expect.objectContaining({ type: "attr", field: "weight_g" }),
    ]);
    expect(byId["healed"].golden).toHaveLength(2);
    expect(byId["healed"].queue).toEqual([]);
  });
});
