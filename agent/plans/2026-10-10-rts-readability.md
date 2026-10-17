# RTS Visual Proportions

Request: make buildings slightly larger, mobile units slightly smaller, and raise/pull back the opening camera. Development root: `G:/AIRTS/AI_RTS`; packaged deliveries and user instances are out of scope.

## Candidate R1

| Entity | Relative authored size |
|---|---|
| CommandCenter, AircraftFactory | 1.10 |
| VehicleFactory, OreRefinery | 1.20 |
| Barracks, three turrets | 1.15 |
| Eleven mobile units | 0.92 |
| Opening camera | size 42.5 -> 46.75, height 60 -> 66 |

Keep root scale at one. Adjust existing Geometry transforms, collider resource dimensions/centers, obstacle/movement radii, selection/target rings and model-relative anchors together. Construction footprints in both balance catalogs follow each building's obstacle radius. Do not alter speed, range, sight, production timing, build range, navigation algorithm or asset imports. World-space UI line thickness, terrain offsets and health-bar readability remain unchanged.

## Verification

1. Record current file hashes and exact file backups; obtain a fresh real-Match baseline with a bounded non-interfering probe.
2. Apply one coupled proportions candidate. Compile, then launch a new headless real Match: all nineteen entities, movement command, cleanup and restart.
3. Replay the same GPU composition on an independent Windows desktop; inspect before/after PNGs. Never switch desktop or inject OS input.
4. Run targeted collision, shape, placement, production/spawn, grounding, muzzle and camera regressions. Independent reviewer checks patch and geometry contracts.
5. Record failures without changing unrelated gameplay or weakening tests. Per the user's latest instruction, skip full autonomous playtesting and full unrelated regression; subjective gameplay is for the user.

Champion starts at recorded baseline. Promote only after scoped gates pass; otherwise report `needs-review`, not completion. Checklist and evidence: `agent/runs/20261010-rts-readability/`.

## Final Checklist

- [x] Fresh baseline, exact backups and hashes.
- [x] Coupled R1 authored dimensions, footprints, test expectations and camera values.
- [x] Build rc=0, fresh real-Match movement/production/cleanup measurements.
- [x] Successful before/after GPU screenshots opened and inspected.
- [x] Related regressions executed and failures classified, not hidden.
- [x] Independent read-only numerical and visual review.
- [x] Owned-process cleanup checked; user instances untouched.
- [ ] Fully clean S3 / global champion promotion. Existing fixture errors and later GPU runtime failure remain documented; full unrelated testing is excluded by user instruction.

Status: `needs-review`. See `agent/reports/closed-loop/2026-10-10-rts-readability.md`. No unrelated game fixes were added to make tests green.

## Refinement R2

User request: enlarge OreRefinery further, make CommandCenter the largest building, and retire Scout while keeping Drone. Confirmed via the user's explicit reply, not inferred from the screenshot.

1. One coupled building patch: CommandCenter and OreRefinery authored linear dimensions +30% relative to R1. Keep the camera and all other entities unchanged. Main-base ground extent/area and body volume must exceed the other structures; an airport antenna may remain taller.
2. Synchronize collider dimensions/centers, obstacle radii, rings, health-bar anchors, both construction catalogs and exact-value expectations. Preserve root scale one and existing shape/navigation-margin semantics.
3. Fresh build and real-Match replay before moving to the next logical patch. R2 baseline is `r2-baseline-headless`: functional assertions passed, but pre-existing headless Minimap texture errors mean this is not a fully clean champion.
4. Retire the Scout unit from both unit/production catalogs, both asset manifests, required-content contracts, current HUD and current test rosters. Preserve the distinct scout action/role/lane/tag: Drone still scouts. Do not delete the old scene or rewrite historical evidence.
5. Add negative assertions for absent Scout production/registration and positive assertions for Drone production. Run catalog/fixture, placement/size/spawn and fresh Match lifecycle gates; inspect fresh GPU screenshots and request an independent read-only review.
6. Record scoped acceptance versus pre-existing failures, cleanup and hashes. No full autonomous playtest; user performs subjective gameplay.

### R2 Checklist

- [x] Saved exact R1 building/config backups and fresh baseline measurements.
- [x] CC/refinery +30%, coupled collider/anchor/footprint/expectation updates.
- [x] Scout retired across active catalogs/manifests/contracts/HUD/AI/rosters; Drone preserved.
- [x] Build rc=0; fresh GPU real Match: 50 assertions, actual Tank/Drone deployment, cleanup/restart.
- [x] Fresh opening/lineup PNGs opened; independent numerical, catalog and visual review.
- [x] Python 150 tests rc=0; relevant size/spawn/placement/shape/reach suites executed.
- [x] Original/current data A/B classifies the 25 core failures and early-startup fixture failure; no assertions weakened.
- [ ] Fully clean S3/global promotion: headless texture errors, fixture errors/leaks, unexplained GPU exit and excluded full regression remain.

R2 status: scoped behavior verified, global `needs-review`; candidate retained for the user's new-match inspection, not promoted as globally regression-clean. Exact pre-edit backups: `agent/runs/20261010-rts-readability/r2-baseline-files/` and `r2-retirement-baseline-files/`. Report and evidence retain all failed attempts.
