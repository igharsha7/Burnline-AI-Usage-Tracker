# Comparisons

Playful, concrete comparisons that make abstract figures legible: "In the
last 30 days, that's the King James Bible, nearly nine times over." They are
**texture, not analytics**. They sit in low-stakes places and never inside a
cost, quota or reset figure.

Settings → General → Activity turns them off entirely (`showComparisons`) and
picks the tone (`comparisonTone`).

## Where they appear

| Place | What it says |
|---|---|
| **Overview, top** (`ComparisonLine`) | One quiet line about the figure on screen: the range's cost on Cost, its tokens on Tokens. While usage is arriving, the live pace joins the token lines. It changes every 25 seconds while the window is open, and at once when the range or the measure changes. |
| **Page footers** (`ComparisonFooter`) | A few comparisons for the range on screen, taking turns |
| **Popover** | One line |
| **Limits page** (`WindowQuip`) | The focus window's usage from this Mac, as a comparison |
| **Milestone notifications** | "Your first 100,000 tokens: …" |
| **Medal detail** | A volume medal borrows the milestone line |

`ComparisonTicker` turns the line only while it is on screen, and holds the
first line under Reduce Motion.

## Tones

| Tone | Character |
|---|---|
| `dry` | Plain. Frames only, with a factual aside ("For scale: Dune, about 188,000 words.") |
| `nerd` | Adds the unit's own nerdy punchline |
| `roast` | Adds a gentle roast of the unit, never of the user |
| Mix | Any of the three |

**Tone boundaries.** Playful and factual. Never mocking the user, never
implying waste, never judging spend in either direction. A roast is about the
thing compared with ("Not one of them was funny, either"), not the person.

## The accuracy rule

**An unverified comparison is worse than no comparison.** The rest of Burnline
rests on a careful line between facts and estimates, and a casually wrong
"29×" undermines the cost and quota figures beside it.

- Every unit carries its quantity in the unit it is natively counted in
  (words, lines of code, tokens or dollars), the basis for that number, and a
  confidence.
- **Token values are not stored.** Units declare words or code lines, and the
  engine converts once at load: 1.3 tokens a word, 9 tokens a line of code.
  The conversion lives in exactly one place. Both are English/Latin-script
  assumptions.
- Only titles and counts are stored. **Never the underlying text.**
- If no unit fits the figure's magnitude, nothing is shown.

## The corpus

`shared/corpus/comparisons.json`, schema version 4. It is data, so it can be
corrected or extended without an app release.

| Key | Holds |
|---|---|
| `schemaVersion`, `generated`, `notes` | Version, date, and the authoring rules |
| `conversions` | `tokensPerWord` (1.3), `tokensPerCodeLine` (9) |
| `frames` | Opening sentences per metric (`tokens`, `cost`) that say what a figure is in terms of a unit |
| `singles` | Frames for a figure between one and two of a unit, where a multiplier would read as noise |
| `units` | 76 units (67 plain, 5 derived, 4 composite) across literature, code, everyday, meme, training, physical, subscriptions, human, burn and cache |
| `milestones` | Lifetime token thresholds and their lines |
| `scopes` | How each period is said: a `lead` ("Today alone, ") and a `tail` (" today") |
| `facts` | The dry tone's aside per kind of quantity |

### A plain unit

```json
{ "id": "lit.bee-movie", "kind": "unit", "metric": "tokens", "category": "meme",
  "label": "the Bee Movie script", "words": 9800, "basis": "~9,800 words x 1.3",
  "confidence": "approx", "many": "Bee Movie scripts",
  "lines": { "nerd": ["…"], "roast": ["…"] } }
```

- `label` is a noun phrase with its article. `many` is its plural for counting
  ("copies of Dune", never "Dunes"); frames that count are used only for units
  that have one.
- `discrete: true` marks a countable object; its multiplier is floored to a
  whole number.
- `lines` are punchlines per tone, said after the frame. They never carry a
  count.
- `confidence`: `verified` (natively counted in the metric it claims),
  `approx` (through an assumed ratio), `volatile` (changes over time, such as a
  subscription price).

### Derived and composite units

- A **derived** unit is a formula over the figure alone, such as reading it
  aloud at 150 words a minute. It scales without bound, so it covers the
  extremes.
- A **composite** unit is a formula plus a reference the engine picks, such as
  a burn rate said against a familiar pace. Each declares what it `requires`,
  and the requirement is checked **before** the unit is considered, so a unit
  is never chosen and then silently dropped.

Both carry whole sentences per tone (`templates`) rather than a frame and a
punchline.

### Frame slots

| Slot | Becomes |
|---|---|
| `{label}` | The unit's noun phrase |
| `{many}` | Its counting plural |
| `{count}`, `{times}` | The multiplier in words: "eight and a half", "nearly nine times", "twice", "about 1,200 times" |
| `{lead}`, `{tail}` | The period, at the start or inside the sentence; empty with no period |
| `{duration}` and the like | A derived unit's result |

With a period given, only frames that carry `{lead}` or `{tail}` are used, so
every line says which period it means. A finished line stays under about 130
characters to fit two lines.

## The engine

`ComparisonEngine` is main-actor isolated on purpose: it is string formatting
with no contention, and an actor would only force `await` on trivial calls.
One engine is shared by the dashboard and the menu bar, so their rotations do
not repeat each other.

- **Multipliers** read best between 2 and 60 times, ideally around 9. Below 2
  a multiplier reads as noise ("1.2× Dune"); above 60 it stops meaning
  anything. Scoring falls off logarithmically either side of the ideal.
- **Derived units** stay in rotation even when plain units are plentiful, with
  a probability that falls as more plain units fit, never below a quarter.
  Below 50,000 tokens they are skipped, since their formulas produce "0 days".
- **Composite lines** (burn and cache) describe something beside the figure
  asked about, so they appear about one time in five.
- **Rotation history** (the last eight) outlives a launch
  (`UserDefaultsRecentStore`), so a user who quits often does not see the same
  line every morning. Randomness is injected, so tests are deterministic.
- `unrenderableUnitIDs` lists corpus entries this build cannot render. Empty
  is healthy, and a test holds the shipped corpus to it.

Loading checks the schema version and reports a missing file, a malformed one
and a version mismatch as different errors. If loading fails, comparisons are
off and everything else runs.

## Adding a unit

1. Find a defensible count from a citable source, in the unit's own measure.
2. Add it to `units` with `basis`, `confidence`, `label`, and `many` if it is
   countable. Add tone lines.
3. Keep every line under about 130 characters, and within the tone
   boundaries.
4. Run `swift test --package-path macos/Packages --filter ComparisonEngineTests`.
   The tests load the shipped corpus and check that every unit renders.
