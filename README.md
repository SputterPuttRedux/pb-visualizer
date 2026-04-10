# Powerball Combo Index Visualizer

A data visualization that maps every Powerball draw since October 7, 2015 to a unique position in the game's full combination space — revealing where each winning ticket landed across 292 million possible outcomes.

**[View it live →](https://sputterputtredux.github.io/pb-visualizer/)**

---

## What it shows

Every possible Powerball ticket can be assigned a unique index between 0 and 292,201,337. This visualizer plots each historical draw by date on the x-axis and its combo index on the y-axis, with jackpot-winning draws highlighted in red.

---

## The math

Powerball draws 5 white balls from 1–69 (order doesn't matter, no repeats) and 1 red Powerball from 1–26. The total number of unique combinations is:

```
C(69, 5) × 26 = 11,238,513 × 26 = 292,201,338
```

Each draw is mapped to a single integer index using the **[combinatorial number system](https://en.wikipedia.org/wiki/Combinatorial_number_system)**:

1. The 5 white balls are sorted and assigned a [lexicographic](https://en.wikipedia.org/wiki/Lexicographic_order) rank — their position in the ordered list of all possible 5-ball combinations from 1–69
2. That rank is multiplied by 26
3. The Powerball value (shifted to [0-based](https://en.wikipedia.org/wiki/Zero-based_numbering)) is added

```
combo_index = white_ball_rank × 26 + (powerball - 1)
```

This gives every combination a unique, deterministic position in the full space — making it possible to visualize draws as points on a number line rather than as isolated number sets.

---

## Data

Draw results are sourced from the [Texas Lottery's Powerball past winning numbers page](https://www.texaslottery.com/export/sites/lottery/Games/Powerball/Winning_Numbers/), which includes jackpot winner status for each draw. Only draws on or after October 7, 2015 are included — the date Powerball adopted its current 5/69 + 1/26 matrix, which is the basis for the index math above.

---

## How it stays current

A GitHub Actions workflow runs automatically 24 hours after each draw (Monday, Wednesday, and Saturday nights) and does the following:

1. Loads the existing `data/powerball_data.json`
2. Drops all records from the current and previous calendar years
3. Fetches both years' draw results from the Texas Lottery site
4. Computes the combo index for each new draw
5. Merges with the retained historical data, sorts by date, and writes the updated JSON back to the repo
6. GitHub Pages redeploys automatically, serving the fresh data

Historical data (all years prior to the previous year) is never re-fetched — those draw results are immutable and are committed directly into the repo.

---

## Project structure

```
pb-visualizer/
├── index.html              # the visualization
├── data/
│   └── powerball_data.json # draw history with combo indices
├── lib/
│   └── powerball_sync.rb   # scheduled sync script
├── scripts/
│   └── seed.rb             # one-time historical data bootstrapper
└── .github/
    └── workflows/
        └── sync.yml        # GitHub Actions schedule
```

---

## Running locally

```bash
git clone https://github.com/dionnestanfield/pb-visualizer.git
cd pb-visualizer
python3 -m http.server 8000
```

Then open `http://localhost:8000` in your browser. The visualization reads from `data/powerball_data.json` which is committed to the repo, so no additional setup is needed to view it locally.

---

## Manually triggering a data sync

The sync workflow can be triggered manually from the GitHub Actions UI without waiting for the schedule — useful after the repo is first set up or to pull in a draw that was missed.

1. Go to the **Actions** tab in the repository
2. Select **Sync Powerball Data**
3. Click **Run workflow**