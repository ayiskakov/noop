# SleepTrain — fitting `SleepStagerV3` to polysomnography

`SleepStagerV3` stages a night from a model fitted to human-scored polysomnography (PSG). This directory holds
everything that model came from: the feature definition, the dataset preparation, the fit, the
cross-validated report, and the generator for the oracle fixture that pins the Swift port. Nothing here ships
in the app, and no dataset is committed.

| File | What it does |
|---|---|
| `sleeptrain/features.py` | **The feature definition.** Plain numpy, every reduction spelled out; `SleepStagerV3.swift` is a line-for-line port of it. |
| `sleeptrain/model.py` | The two logistic-regression heads, the HMM decoder, and a reference of `SleepStagerV3.stageSession`. |
| `sleeptrain/data.py` | The shared night format (below) and the emulation of `SleepStager.bandSleepWindow`. |
| `prepare_sleep_accel.py`, `prepare_wearanize.py`, `prepare_dreamt.py` | Dataset → night format. |
| `train.py` | Features, 10-fold grouped cross-validation report, final fit, and `SleepStagerV3Model.swift`. |
| `make_oracle.py` | Regenerates `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/oracles/sleep_stager_v3.json`. |

## Setup

```bash
python3 -m venv ~/.venvs/sleeptrain && . ~/.venvs/sleeptrain/bin/activate
pip install -r Tools/SleepTrain/requirements.txt
```

Keep the datasets **outside** the repository, e.g. `~/datasets/noop-sleep/`.

## Data

### The night format

Each prepared cohort is a directory of per-night CSV files, timed in whole seconds from the night's first PSG
epoch: `{id}_grav.csv` (`ts,x,y,z`, per-second gravity in g), `{id}_hr.csv` (`ts,bpm`), `{id}_rr.csv`
(`ts,rr`, interval in ms stamped with the beat's whole second), `{id}_truth.csv` (one label per 30 s epoch:
`wake`, `light`, `deep`, `rem` or `none`) and optionally `{id}_truth2.csv` (a second scorer). That is exactly
what the app hands the stager (whole-second stamps, integer bpm and ms), so the model trains on what it will
read. `Tools/SleepPSG --section v3` replays the Swift stagers over the same directories.

### Training cohorts (open)

**Wearanize+ OA** — 88 usable nights of an Empatica E4 wristband (accelerometer, HR, PPG inter-beat
intervals) with lab PSG scored by two humans. Radboud University Data Repository,
DOI [10.34973/xrmf-5726](https://doi.org/10.34973/xrmf-5726), **CC BY 4.0** (attribution required). No login.

```bash
python3 Tools/SleepTrain/prepare_wearanize.py ~/datasets/noop-sleep/wearanize-nights
```

Downloads about 360 MB per subject one at a time and deletes it after processing; the server refuses more
than about four parallel downloads. The E4 clock drifts against the PSG recorder, so each subject's E4 is
mapped onto the PSG clock with a linear lag fitted hour by hour from the E4 inter-beat intervals against the
PSG ECG's R-R intervals. No sleep label takes part in that alignment.

**PhysioNet sleep-accel v1.0.0** — 31 nights of Apple Watch accelerometer and heart rate with PSG. Walch O,
Huang Y, Forger D, Goldstein C. *Sleep stage prediction with raw acceleration and photoplethysmography heart
rate data derived from a consumer wearable device.* SLEEP 42(12), zsz180 (2019). **ODC-By 1.0**
(attribution required). Download as in `Tools/SleepPSG/README.md`, then:

```bash
python3 Tools/SleepTrain/prepare_sleep_accel.py <extracted root> ~/datasets/noop-sleep/sleep-accel-nights
```

### Independent test cohort (restricted, never trained on)

**DREAMT v2.2.0** — 100 sleep-clinic patients on an Empatica E4 with PSG. PhysioNet, **Restricted Health Data
License 1.5.0**: it needs a PhysioNet account and the signed data use agreement, the files may not be shared,
and use is limited to scientific research. For that last reason DREAMT only ever *tests* the model and never
enters a fit, so no number in `SleepStagerV3Model.swift` is derived from it. Download `data_64Hz/` from
<https://physionet.org/content/dreamt/2.2.0/> after signing, then:

```bash
python3 Tools/SleepTrain/prepare_dreamt.py <data_64Hz dir> ~/datasets/noop-sleep/dreamt-nights
```

## Train and regenerate

```bash
cd Tools/SleepTrain
python3 train.py --wearanize ~/datasets/noop-sleep/wearanize-nights \
                 --sleep-accel ~/datasets/noop-sleep/sleep-accel-nights \
                 --dreamt ~/datasets/noop-sleep/dreamt-nights \
                 --swift ../../Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStagerV3Model.swift \
                 --report report.md
python3 make_oracle.py
cd ../../Packages/StrandAnalytics && swift test --filter SleepStagerV3
```

`--no-cv` skips the cross-validation and only refits and writes the model. Regenerating the model changes
what every night stages as, so a new model is its own reviewed change with its report attached.

## Results

Four-class Cohen's kappa against PSG over every scored epoch (wake outside the staged span), 10-fold
cross-validated by subject for the training cohorts. V2 is the shipped `SleepStagerV2`, replayed by
`Tools/SleepPSG --section v3` over the same prepared nights.

| Cohort | V2 | V3 | Second human scorer |
|---|---|---|---|
| Wearanize+ (88), band-style window | 0.363 | 0.547 | 0.742 |
| Wearanize+, whole span | 0.301 | 0.533 | — |
| sleep-accel (31, no beat intervals), band-style window | 0.434 | 0.504 | — |
| sleep-accel, whole span | 0.373 | 0.463 | — |
| DREAMT (10, never trained on), band-style window | 0.259 | 0.313 | — |
| DREAMT, whole span | 0.142 | 0.256 | — |

On Wearanize+ in the window, V3's stage shares are within 1 percentage point of PSG for every stage (V2:
light +13.5, deep −5.4, REM −7.0); per-night minute bias is +1 wake / +3 light / −4 deep / +0 REM. First deep
is 6 min early on average and never within 5 min of onset; first REM is 47 min late (V2: 48). `train.py
--report` writes the full table, with F1, limits of agreement and latencies.

## How the model is built, and why

- **Features are relative to the night.** Motion is per-second gravity jerk over the night's median jerk
  (V2's self-calibrating floor), posture change over the night's median change, heart rate as z-scores,
  percentile ranks and 5 / 11 / 20-minute variability, HRV scaled to the night's 5th-95th percentiles. An
  absolute-degree posture feature was tried first and failed across devices: the WHOOP strap reads about
  seven times the angle change of an Apple Watch on still sleep, and the model staged WHOOP nights as light.
- **Elapsed time as decays too.** Besides minutes since the start of the staged span, `exp(-t/10)`,
  `exp(-t/30)` and `exp(-t/90)`. A linear head reads minutes only as a straight line; without the decays it
  staged deep within 5 min of onset on 37 of 88 Wearanize+ nights (PSG: none).
- **Two heads, blended.** The base head reads motion and heart rate; the HRV head adds 5-minute beat-interval
  HRV. When at least half the staged epochs have 20 or more beats in their window both run and their
  log-posteriors are averaged with equal weight (untuned); otherwise the base head alone. The HRV head alone
  scored slightly higher (Wearanize+ 0.554 vs 0.547, DREAMT 0.320 vs 0.313) but called REM high out of its
  training cohort (+7.9 pp on DREAMT against +5.9 blended, and a quarter to over a third of sleep on WHOOP
  nights).
- **Two views of every night.** Each training night is used over its whole scored span and cropped to the
  band-style sleep window the app will stage inside, so both of the app's cases are in-distribution.
- **Decoder.** Emission = log posterior − 0.5 · log class prior; Viterbi with the transition matrix counted
  from the training hypnograms (add-one smoothed) and the prior as the start distribution.
- **Why a linear model.** Gradient-boosted trees scored about 0.02 kappa higher in the same cross-validation,
  and cost a far larger generated file and a tree evaluator to port and pin. The linear head is the smaller
  thing to verify.

## Limits

- No public dataset pairs a WHOOP strap with PSG, so the stage minutes on a WHOOP night are unverified; the
  cross-device check (train on one wrist device, test on the other) keeps kappa but shifts the deep share by
  about 8-10 percentage points toward the training cohort.
- Sleep-clinic nights (DREAMT) are much harder than healthy adults' for every stager tried: long still wake
  and little deep sleep. V3 over-counts deep there by about 50 min a night.
- First REM comes late: 47 min on Wearanize+ and 60 min on sleep-accel, where V2 is within 5 min.
