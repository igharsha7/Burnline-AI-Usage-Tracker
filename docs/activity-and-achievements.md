# Activity and achievements

The Activity page (heatmap, streaks, the climb) and the Achievements page
(medals, monthly challenges, records). Everything here is computed locally
from the usage database, never uploaded, and can be hidden entirely in
Settings → General → "Show streaks and achievements" (`showAchievements`).

## The framing constraint

Burnline is a spend and quota monitor. A progression layer in a spend tracker
carries an obvious perverse incentive, and the product must not create one.
This rule decides every design question on these pages:

- Streaks, medals and comparisons are **observations about work already
  done**, never goals.
- Burnline **never prompts the user to keep a streak**, never frames less
  usage as failure, and **never celebrates cost** as an accomplishment.
- **Progress is shown only toward habits**: streaks, efficiency, pacing.
  Volume, session and breadth ladders show what was earned but never how far
  the next one is, because that would invite more usage to reach it
  (`AchievementCategory.isHabit`).
- Every monthly challenge rewards **rest, restraint or craft**, never more
  usage.
- Personal records are **observations, not medals**: a bigger day is not an
  accomplishment in a spend monitor.

A change that adds an incentive to use more will not be merged.

## Days

`ActivityService` reads every tracked day at once, from the rollups so
compacted history counts, into `ActivityDay`s: each local day's active quarter
hours, sessions, tokens, cost and events.

- An **active day** has at least one event. It drives the heatmap and the
  "active days" figure.
- A **day before tracking began** is drawn apart from a tracked day with no
  usage (EC-U2).

## The heatmap

One square per day, a column per week starting on the user's first weekday,
ending with the week holding today. Settings choose what a square's shade
measures (tokens, cost, sessions or events) and how far back it reaches (3
months, 6 months, a year, or all). Shades derive from the visible range, so a
brand-new user still sees a gradient (EC-U5). Hovering a square shows that
day's figures by provider, in a card like the chart's.

## Streaks

`StreakRule` (Core) decides what a day asks:

- **A streak day has at least an hour of usage**, counted in 15-minute
  stretches that need not be consecutive. Active time, not tokens, is the
  measure: token counts vary a hundredfold between models, plans and cache
  behaviour, and a token bar would reward burning more.
- **Every 90 days of a streak add a quarter hour** to what a day asks, up to
  two hours. A broken streak starts again at an hour.
- **Freezes.** Every 7 counted days earn a freeze, two at most. A freeze covers
  a whole day that fell short, without adding to the streak. Freezes belong to
  their streak and end with it.
- **Today never breaks a streak** while it is under way. Until today meets its
  bar, the current streak stands on yesterday and waits; the dial shows how
  much of today's hour is done.

The rule for breaking a streak is stated in the interface, and freezes are
always visible, so the displayed number is never a surprise.

`StreakRule.walk` gives each day an outcome: counted (with the streak's length
through it), frozen, missed, or waiting (today, short so far). `Streaks`
summarises the runs: current and longest (the latest on a tie), every streak,
whether today has met its bar, freezes held, and counted days this month and
year.

### Tiers

Named stops along a streak (`StreakTier`). Each changes how the streak's flame
looks; the three majors change it most. They mark how long a run has lasted
and are never targets.

| Days | Tier | | Days | Tier |
|---|---|---|---|---|
| 1 | Pilot Light | | 150 | Afterburner |
| 7 | Hot Reload | | 200 | Rocket Fuel |
| 14 | Campfire | | 300 | Solar Flare |
| **30** | **Bonfire** (major) | | 400 | Red Giant |
| 60 | Thermal Throttling | | **500** | **Supernova** (major) |
| 80 | The Forge | | 600 | Pulsar |
| **100** | **Blue Flame** (major) | | 700 | Big Bang |

Past the last tier, the ring counts laps of 100 days. The ring's arc is the
span to the next tier: it starts empty at each tier, so it is never stuck full.

### The Streaks card

- **The dial**: the current streak in a ring with its flame. The flame is
  Google's animated Noto fire, recoloured per tier by turning every gradient
  stop's hue (`FireAnimation`); a painted flame (`StreakFlame`) stands in when
  the animation cannot load and in rendered frames.
- **Bot-7's story**: a 340 × 100 pixel-art scene drawn a pixel at a time, as a
  16-bit game would (`PixelBuffer`, `StoryPainter`). Five chapters change with
  the tier: a campfire, a forge, a launch pad, a flight to the sun, the cosmos.
  Bot-7 gains shoulder plates, boot thrusters, fins and a halo along the way.
  Labels use the Silkscreen pixel font. It draws fifteen frames a second.
- **The tier road**: every tier as a stop, lit up to the streak.
- **This month and year**, and **the year's streaks as a skyline**, each
  streak a bar as tall as it was long, the current one in its tier's colour and
  the best marked with a star.

Every animation holds still under Reduce Motion, while the window is inactive,
and in rendered frames. `StreakCardTests` can render the card at several
lengths: `BURNLINE_STREAKS_RENDER=/dir swift test --filter StreakCardTests`.

## The climb

Everything ever processed, printed and stacked (`PaperStack`): 1.3 tokens a
word, 500 words a page, a tenth of a millimetre a sheet of 80 gsm paper. The
constants match the comparison corpus's paper stack, and a test holds them to
it.

The stack climbs past landmarks, each at most about twice the height of the
one before, so there is always one ahead:

| Landmark | Height | | Landmark | Height |
|---|---|---|---|---|
| Tower of Pisa | 56 m | | Mount Washington | 1,917 m |
| Statue of Liberty | 93 m | | Half Dome | 2,696 m |
| Great Pyramid | 139 m | | Mount Fuji | 3,776 m |
| Space Needle | 184 m | | Matterhorn | 4,478 m |
| Golden Gate Bridge | 227 m | | Kilimanjaro | 5,895 m |
| Eiffel Tower | 330 m | | Mount Everest | 8,849 m |
| Empire State | 443 m | | Cruising Altitude | 10.7 km |
| Taipei 101 | 508 m | | Concorde | 18.3 km |
| Shanghai Tower | 632 m | | Weather Balloon | 30 km |
| Burj Khalifa | 828 m | | Record Balloon | 53 km |
| Angel Falls | 979 m | | Edge of Space | 100 km |
| Table Mountain | 1,085 m | | Sputnik 1 | 215 km |
| Mount Vesuvius | 1,281 m | | Space Station | 408 km |

The **ClimbCard** draws the climb as one wide world: time runs right, height
runs up, and every landmark stands at its true height. The card is a camera
that follows the stack, framing the ground up to about twice its height on a
linear scale, so sizes are honest and the view never jumps when a landmark is
passed. **Replay** runs the climb again from the first day, every landmark
reached where it was. `Climb` keeps the height at the end of each day, thinned
to a fixed number of points with the first and last kept, so a long history
draws as cheaply as a short one. It also gives the pace over the last 30 days
and when the next landmark would be reached at that pace (with at least a
week of history).

Landmarks are drawn as themselves (`LandmarkArt`) from simple parts joined
into one outline, so the same shape engraves a medal and fills the climb.

## Achievements

### How they are awarded

`Achievement.earned(_:)` (Core, pure) judges an `AchievementHistory`: every
tracked day, the first use of each model and project, weekly and 5-hour quota
windows, each day's tokens by project, the models used each day, every
session's span, and the app's version.

- **Retroactive.** Reading the activity snapshot awards anything the history
  has earned and the store lacks, so a backfill is awarded where its usage
  happened.
- **Dated by the history.** `awardedAt` is when the history first met it, not
  when Burnline noticed: a threshold crossed during a day is dated from the
  day's start, since usage is summed by day; a period's award from the
  period's end.
- **Never rewritten.** A stored achievement is never changed, so recomputing
  after a backfill or a repricing cannot move its date.
- **Fresh** means awarded within the last three days. Only fresh ones are
  announced and celebrated; older ones awarded late by a backfill join their
  shelf quietly.
- After an import, notifications judge at most once every five minutes. Setup
  and Add Provider show the medals an import found (`FoundMedals`).

### Metals

Every medal has a metal for how hard it is to earn. Six metals with three
grades each make eighteen rungs, Bronze I to Ember III. **Every ladder spreads
its rungs across the eighteen by how far up the ladder each sits**, so the same
metal and grade mean the same rarity on every shelf, and every ladder tops out
at Ember III. A single medal takes the metal of the rung it would sit on:
bronze for a first time, silver for a week's habit, gold for a month's or a
feat, platinum for a year's, ember for never again.

Each shelf has its own medal outline (coin, shield, hexagon, octagon, diamond,
rosette, disc, seal, sunburst, plaque), so a medal's shape says what it is for
before its face is read.

### The shelves

| Shelf | Medals |
|---|---|
| **Volume** | Lifetime processed tokens: 1M, 50M, 100M, 500M, 1B, 2B, 5B, 10B, 20B, 50B, 100B, 200B, 500B, 1T, 1.5T, 2T, 2.5T, 3T. **Odometer** (secret): lifetime tokens roll past 123,456,789. |
| **Landmarks** | One per landmark the paper stack passes |
| **Streaks** | Streaks of 3, 7, 14, 30, 60, 100, 200, 365 and 730 days. **Saved by a Freeze**: a freeze carries the streak over a short day. **Rest Day**: a whole day off with a freeze keeping the streak. |
| **Efficiency** | Cache savings of $10, $50, $100, $500, $1K, $10K, $100K and $1M against plain input prices. **Cache Master**: 90% of a busy week's input from the cache, then of each busy month's (at least 4M input tokens), for 1, 3, 6, 9, 12, 18 and 24 months running. |
| **Pacing** | **Steady Hand**: 2, 4, 8, 12, 26 and 52 busy weekly windows in a row closed without reaching the limit. Windows under 50% used neither extend nor break a run: an idle week shows no restraint. |
| **Sessions** | 10, 50, 100, 500, 1K, 5K, 25K and 100K sessions. Secret: **Night Owl** (a session started between midnight and 5 a.m.), **Early Bird** (5 to 7 a.m.), **Marathon** (one session four hours long; longer than 16 hours counts as a conversation resumed days later), **Leap Day** (active on 29 February), **Midnight Crossing** (a session running as the new year arrives). |
| **Explorer** | **First session** on each provider. **Two at Once** and **Full House**: two or three providers on one day. 3, 6, 12, 25 and 50 **models**. 5, 10, 25, 50 and 100 **projects**. **Deep Dive**: 100M, 500M, 1B, 5B and 10B tokens in one project. **Project Hopper**: 5, 10 or 15 projects in a day. **Comeback** after 30, 90, 180 or 365 days away. **Model Hopper**: five models in a day. **Around the Clock**: sessions started in every hour of the day, over time. **Seven Days**: on every weekday, over time. **Old Friend**: one project worked in for a year. |
| **Again and Again** | Earned once per period: **Perfect Week** (every day of a calendar week counted toward the streak), **Hot Cache** (over 90% of a week's input from the cache, with at least 1M tokens), **Under the Line** (past 75% of a weekly limit and still closed without reaching it) |
| **Monthly Challenges** | One per month on a fixed schedule (below), each set in its birthstone once earned |
| **Limited Edition** | **Alpha Tester** (used during the first alpha, 0.1), **Founding Year** (used in 2026), **One Year of Burnline** (tracked for a year), **A Year of Building** (active on 100 days in one calendar year) |

Secret medals show as "???" until earned.

### Monthly challenges

A fixed schedule starting September 2026 (`MonthlyChallenge.schedule`). A
month needs at least five active days before resting or caching in it means
anything: an idle month rests by default. A challenge is judged on the whole
month once it is over.

| Challenge | Asks |
|---|---|
| Under the Limit | Close every weekly window this month without reaching its limit |
| Cache Keeper | Serve 70% of the month's input from the cache |
| Showing Up | Be active on 15 days this month |
| Lights Out | Start no sessions between midnight and 5 a.m. all month |
| New Ground | Try a model never used before |
| Steady Weeks | Keep every weekly window this month under 80% |
| Deep Focus | Hold 10 sessions of an hour or more |
| Better Cache | Serve more input from the cache than last month |
| Weekends Off | Take 4 weekend days off entirely |
| Spread Out | Be active in every week that starts this month |
| Rested | Take at least one day off in every full week of the month |
| Full Roster | Use every tracked provider on the same day, 10 times |
| One Thing Well | Spend 80% of the month's tokens in one project |
| Calm Limits | Keep every 5-hour window this month at or under 90% |

The fourteen repeat in order: September 2026 is Under the Limit, October
Cache Keeper, November Showing Up, and so on through December 2028. Months of
a later year stay off the shelf until their year comes.

### Records

Personal bests, shown as observations: the biggest day, the biggest week, the
longest session (under the 16-hour ceiling), the longest streak, and the most
sessions in a day, each with the day it was set.

## The pages

**Activity** shows the heatmap, then the Streaks card, the climb, and
comparisons for the range on screen. It has its own range and measure, so the
toolbar's range control stands aside for it.

**Achievements** shows every medal shelf by shelf (around where the user stands
on each, with the rest a click away), this month's challenge and how it
stands, and personal records. **History** lists everything earned in the order
it happened. A medal opens its detail:

- a **3D medal** (`MedalScene`): its outline extruded with rounded edges and
  cast in physically based metal in SceneKit, its face and back printed from
  the 2D art. Dragged sideways it turns over, carrying a flick's momentum;
  dragged up or down it tips and springs back. Its back is engraved with the
  user's name (Settings → General, `userName`) and when it was earned;
- every time it was earned, and for a volume medal, the corpus's milestone
  line.

At rest, an unhovered medal is drawn once into a cached image
(`MedalImages`), so a scrolling grid only places bitmaps.

**Arrivals.** A fresh medal plays its arrival once on the Achievements page
(`celebrated_at`). The sidebar shows a badge with how many wait.
