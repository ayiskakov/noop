# Healthspan upgrade — WHOOP-comparable Body Age & Pace of Aging

**Status:** planned · **Tracking:** 3 PRs, in order · **Started:** 2026-09-23
**Sibling plan:** [Resilience (Experimental)](2026-09-23-resilience.md), which adds a new section to the same tab

This upgrades the **existing** Healthspan feature in place: `VitalityEngine`, `PaceOfAgingEngine`, the
weekly pipeline in `IntelligenceEngine`, and `HealthspanView`. It is not a parallel model. The goals:

- make it methodologically comparable to WHOOP's Healthspan (WHOOP Age / Pace of Aging);
- correct it against the current device-measured mortality literature;
- make the tab explain itself (years per driver, the biggest lever, the trend).

It remains a wellness estimate, never a clinical biological age. The per-driver hazard ratios are
observational, and nothing here is validated against a mortality outcome (WHOOP's model is not either).

## Checklist

- [x] **PR 1 — Engine** (`Packages/StrandAnalytics`: `VitalityEngine` + `PaceOfAgingEngine`, `swift test`)
- [x] **PR 2 — Pipeline** (`Strand/Data/IntelligenceEngine.swift`: windows, inputs, persisted breakdown)
- [x] **PR 3 — Healthspan tab** (`Strand/Screens/HealthspanView.swift`, macOS + iOS)

## What is wrong with the current feature (found 2026-09-23)

| # | Gap | Where |
|---|---|---|
| 1 | Body Age is computed from the **last 7 days**, so it jumps week to week. WHOOP uses 6 months. | `fa7` → `healthspanInputs`, IntelligenceEngine ~L2681 |
| 2 | Pace is an OLS slope needing ≥ 60 rolling samples (~3 months before any number). WHOOP projects the last-30-day averages against the 6-month age. | `PaceOfAgingEngine` |
| 3 | Referent is "average for your age"; WHOOP's is "meeting health targets". | `VitalityEngine.contributions` |
| 4 | Zone targets 150 / 75 min/wk come from **self-report** studies and are applied to **device** zone minutes, so almost everyone is penalised on zones 4–5. | `moderateTargetMinPerWeek`, `vigorousTargetMinPerWeek` |
| 5 | "Sleep regularity" is 1 − CV of nightly **duration**, not the timing-based Sleep Regularity Index the evidence uses. | `VitalityEngine.sleepConsistency` |
| 6 | VO₂max is never passed in (8 of WHOOP's 9 drivers). | `healthspanInputs` has no vo2max argument |
| 7 | HRV is scored and rewarded when high. It is not in WHOOP's nine; it is non-causal (Mendelian randomisation null) and U-shaped in older adults. | `rmssd` contribution |
| 8 | The sleep-duration curve is symmetric around 7.5 h; the evidence is asymmetric with a nadir near 7 h. | sleep contribution |
| 9 | The tab cannot show years per driver, because nothing persists a breakdown (see the HealthspanView header). | `HealthspanView` |

## Decisions (locked)

| Decision | Choice | Why |
|---|---|---|
| Referent ("at your age") | **Meeting health targets** (WHOOP's anchor), chosen by the user 2026-09-23 | Comparable to WHOOP; each "years" figure is distance from a healthy target. An average adult reads roughly +6 y (WHOOP WP Table 2: +6 for a 30-year-old man, +7.5 for a 30-year-old woman). |
| Years per unit hazard | **10 · ln(HR)** | WHOOP's effective-age transform (Spiegelhalter 2016). The current engine uses 8/ln2 ≈ 11.5 · ln(HR). |
| Body Age window | **Last 182 days** | WHOOP Age uses 6 months. |
| Pace of Aging | **Projection**: hold the last-30-day averages for 6 months → projected Body Age; pace = (projected − current) / 0.5 y, clamped −1…3× | WHOOP's published definition (WP p.19). Keep the current honesty rule: ±margin, and "holding steady" when the margin spans 1×. |
| Unlock | ≥ 21 scored days in the last 31; age ≥ 18 | WHOOP's gate. |
| Cadence | ~~Weekly headline (Sunday, like WHOOP) plus a daily point for the trend chart~~ **One point per day; the headline is the newest point** (revised in PR 2) | A Sunday headline beside a daily chart would put two different "current" Body Ages on one screen, which AGENTS.md forbids. The 182-day window already gives the week-to-week stability the Sunday cadence was for. |
| HRV | Shown on the tab as context, **not scored** | See gap 7. |
| Model change on stored rows | Bump a `healthspan_model` version; re-derive the stored `body_age` / `pace_of_aging` history under the new model in one idempotent pass | Otherwise the trend chart would splice two models together at the upgrade date. |

## PR 1 — Engine

Changes inside `VitalityEngine` / `PaceOfAgingEngine`. Each curve carries its citation in its doc comment.

| Driver | Target (0 years) | Curve | Evidence |
|---|---|---|---|
| Sleep regularity (SRI) | ≥ 70 | Hinge: most hazard below the lowest quintile (HR 0.80 Q2 → 0.70 Q5 vs Q1); plateau above the median (~81) | Windred, SLEEP 2024 (doi 10.1093/sleep/zsad253), device; Cribb, eLife 2023 (doi 10.7554/eLife.88359) |
| Sleep duration | 7–9 h | Asymmetric; short worse per hour on device data (short 1.27, long 1.16); **down-weighted when SRI is present** | Yin, JAHA 2017; UK Biobank device, J Gerontol A 2023 (doi 10.1093/gerona/glad108) |
| Zones 1–3 (%HRR) | 70–100 min/wk, age-declining (WHOOP Table 1) | Device dose-response, flat above ~2–3× target | Ekelund, BMJ 2019 (device); Lee DH, Circulation 2022 |
| Zones 4–5 (%HRR) | 7–10 min/wk, age-declining | Device: 15 min/wk HR 0.82, 54 min/wk HR 0.64 | Ahmadi, EHJ 2022 (doi 10.1093/eurheartj/ehac572); Stamatakis, Nat Med 2022 |
| Strength | ≥ 40 min/wk; no extra benefit > 2 h | Benefit-only J-shape | Momma, BJSM 2022 |
| Steps | 8,000/day (≥ 60 y: 5,600) | Steep from ~3.5k; plateau age-dependent | Paluch, Lancet Public Health 2022; Banach, EJPC 2023 |
| VO₂max | Age/sex curve (~44 M / 38 F at 30) | ~0.86–0.89 per MET, no upper cap | Kokkinos, JACC 2022; Lang, BJSM 2024; Mandsager 2018 |
| Resting HR (sleep) | < 60 M / < 64 F | Linear, 1.12 per +10 bpm (literature 1.09–1.17) | Zhang, CMAJ 2016; Aune, NMCD 2017 |
| Lean mass % | ≥ 80 % M / 67 % F at 30, age-adjusted | Penalty-only below target | FFM meta-analysis, JCSM 2026 (RR 1.31–1.42, doi 10.1002/jcsm.70331) |

- **Overlap.** Keep the domain √n shrink and the cross-domain shrink. When VO₂max is **strap-derived**
  (largely a function of resting HR), fold it and RHR into one fitness term. An external VO₂max scores on
  its own.
- **SRI helper.** SRI = 200 · P(same sleep/wake state at t and t+24 h) − 100 over 30-second epochs, built
  from sleep sessions (`effectiveStartTs`/`endTs` plus the wake epochs in `stagesJSON`). Pure function.
- **Outputs** gain `projectedBodyAge`, `unlocked`, `daysUntilUnlock` and `biggestLever`. The per-driver
  `deltaYears` still sums exactly to the unclamped delta.
- **Verification.** Oracle-pinned outputs (`Tests/.../oracles/healthspan_v2.json`), generated by running
  the helpers standalone:
  - every curve over its whole domain;
  - an "exactly at every target" person → Δ = 0;
  - an average US 30 M / 30 F person → approximately +6 / +7.5 y;
  - SRI on synthetic schedules;
  - pace-projection edge cases.

  Update the existing `VitalityEngineTests`, `PaceOfAgingEngineTests` and `HealthspanOracleTests`
  deliberately, with the reason for each change noted in the test.

## PR 2 — Pipeline

- One resolver (`healthspanInputs`) builds the inputs for the 182-day window and the 30-day window.
- **%HRR zone minutes.** Add per-day `zone_min_hrr_1_3` / `zone_min_hrr_4_5` from the same HR scan (the
  Karvonen zones already exist in `StrainScorer`). The current `HRZones` are %HRmax.
- **SRI** from stored sleep sessions.
- **VO₂max** from `vo2max_est` (tagged strap-derived) or an imported value (tagged external).
- **Lean-mass %** from the imported `lean_mass` and body weight.
- **Persist** `body_age`, `pace_of_aging`, `pace_of_aging_margin` and **per-driver `hs_years_<driver>`**,
  so the tab can show years per driver from the same stored funnel as the headline (closes gap 9).
- Model-version bump and a one-shot history re-derivation (see Decisions).
- **Verification.** Resolver unit tests (`HealthspanInputsTests`) plus a local `xcodebuild` of `Strand`
  **and** `NOOPiOS`.

## PR 3 — Healthspan tab (upgrade of `HealthspanView`)

1. **Hero:** Body Age vs calendar age, ±band, "N years younger/older", a "6-month" overline, and the unlock
   countdown (x/21 scored days in 31) until ready.
2. **Pace dial:** −1…3× with four bands (reversing / slowing / steady / accelerated), the margin, and
   "holding steady" when it spans 1×.
3. **Drivers:** each row shows the value, target, a **signed years chip** (from the persisted
   `hs_years_*`), and a 30-day vs 6-month arrow (the driver behind the pace). Tap for the curve and its
   citation.
4. **Biggest lever:** "Reaching your strength target would take ~X years off."
5. **Trend:** Body Age and pace over 6 months (StrandDesign chart).
6. **Context (not scored):** HRV.
7. **Method sheet:** the referent choice, the limits, the references.
8. The **Resilience** section (sibling plan) mounts below, behind its Experimental toggle. *(Not in this PR: it ships with the Resilience plan.)*

The same rule applies to every readout: hero, dial, chips and chart all read one stored point per day.
Design tokens only. New copy must go into `Strand/Resources/Localizable.xcstrings` with de / es / fr /
pt-PT translations, or `i18n-coverage` fails. Build both schemes locally.

## Follow-ups

- **Sedentary time** as a tenth driver (device HR 2.63, most vs least sedentary; offset by 30–40 min/day of
  MVPA; Ekelund, BMJ 2019 / BJSM 2020). `SedentaryDetector` already exists.
- **Sleep-apnea hypoxic burden** from strap SpO₂ (Azarbarzin, EHJ 2019; CVD-specific). Depends on the
  byte-82 SpO₂ candidate being validated.
- **Week-by-week comparison** against the user's own WHOOP app readings.

## References

- WHOOP, *The WHOOP Healthspan Feature* white paper, rev. 2025-09-04 —
  https://assets.ctfassets.net/rbzqg6pelgqa/3ONehqJslbqxI7CQlwGjfT/36429d6f66940e1fd866a772ed5bfc93/WHOOP_2025_White_Paper_Healthspan__6_.pdf
- Spiegelhalter D, BMC Med Inform Decis Mak 2016;16:104, doi 10.1186/s12911-016-0342-z
- Windred DP et al., SLEEP 2024;47(1):zsad253, doi 10.1093/sleep/zsad253
- Cribb L et al., eLife 2023, doi 10.7554/eLife.88359
- Yin J et al., J Am Heart Assoc 2017 (sleep-duration dose-response meta-analysis), PMID 28889101
- UK Biobank device-measured sleep duration & efficiency, J Gerontol A 2023, doi 10.1093/gerona/glad108
- Ahmadi MN et al., Eur Heart J 2022, doi 10.1093/eurheartj/ehac572
- Stamatakis E et al., Nat Med 2022, doi 10.1038/s41591-022-02100-x
- Ekelund U et al., BMJ 2019, doi 10.1136/bmj.l4570
- Lee DH et al., Circulation 2022, doi 10.1161/CIRCULATIONAHA.121.058162
- Momma H et al., BJSM 2022, doi 10.1136/bjsports-2021-105061
- Paluch AE et al., Lancet Public Health 2022, doi 10.1016/S2468-2667(21)00302-9
- Banach M et al., Eur J Prev Cardiol 2023 (steps meta-analysis), PMID 37555441
- Mandsager K et al., JAMA Netw Open 2018, doi 10.1001/jamanetworkopen.2018.3605
- Kokkinos P et al., JACC 2022 (PMID 35926933); Lang JJ et al., BJSM 2024 (PMID 38599681)
- Zhang D et al., CMAJ 2016 (PMID 26598376); Aune D et al., NMCD 2017 (PMID 28552551)
- Jarczok MN et al., Neurosci Biobehav Rev 2022 (HRV and mortality meta-analysis), PMID 36243195
- UK Biobank HRV Mendelian randomisation (null causal effect), Commun Biol 2023, PMID 37803156
- Ekelund U et al., BJSM 2020 (sedentary time × MVPA; follow-up only), PMID 33239356
- Fat-free mass meta-analysis, J Cachexia Sarcopenia Muscle 2026, doi 10.1002/jcsm.70331
- Azarbarzin A et al., Eur Heart J 2019 (hypoxic burden; follow-up only), doi 10.1093/eurheartj/ehy624
- Pyrkov TV et al., Nat Commun 2021, doi 10.1038/s41467-021-23014-1 — used by the sibling
  [Resilience plan](2026-09-23-resilience.md)
- Doherty C, critique of WHOOP Healthspan (Medium, 2025-09-30) — no uncertainty shown, additive
  aggregation, SEM factors fitted on a healthier member base —
  https://web.archive.org/web/20260108073828/https://medium.com/@cailbhe/is-whoop-really-able-to-measure-your-healthspan-728b88e69175
