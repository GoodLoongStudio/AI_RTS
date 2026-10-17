# 512m Map Independent Review

Date: 2026-10-11 (Asia/Shanghai). Reviewer: `/root/map512_review`.

## Decision and Scope

The requested 512x512 world-metre geometry and unchanged unit sizes pass this independent static review. Default Forward+ base framing passes image inspection. Overall task remains **needs-review**, not a clean full-regression promotion, because runtime logs and related suites retain errors.

Development root: `G:/AIRTS/AI_RTS`. Git identity and `check_workspace_target.py --mode develop` returned rc=0 for the root and this report. Mandatory workspace/closed-loop/RSI contracts were read. The reviewer launched no Godot processes, touched no user instances, and changed only this report. Runtime artifacts below were produced by the implementation agent and independently read here, not independently rerun.

## Independent Static Checks

Two read-only Python checks parsed serialized scene transforms, JSON indexes, PNG RGBA masks and little-endian float height fields. Transform composition, raw bilinear height sampling, mask classification, submerged/cliff stamping and rotated bridge-box footprints were recomputed independently. Both commands returned rc=0.

| Scene | World XZ / Terrain span | Root scale | Spawns | Ores | Bridge slabs |
|---|---|---|---:|---:|---:|
| PlainAndSimple | 512 / 512m | 1,1,1 | 4 | 16 | 0 |
| 36-1846106761-767a002977 | 512 / 512m | 1,1,1 | 4 | 28 | 42 |
| 39-655312406-767a002977 | 512 / 512m | 1,1,1 | 4 | 28 | 42 |
| 47-903520021-767a002977 | 512 / 512m | 1,1,1 | 4 | 28 | 42 |
| 8-561215132-767a002977 | 512 / 512m | 1,1,1 | 4 | 28 | 42 |
| 8-608324557-767a002977 | 512 / 512m | 1,1,1 | 4 | 28 | 42 |
| HTTP 47-903520021-7544ea830a | 512 / 512m | 1,1,1 | 4 | 28 | 42 |

- Terrain `world_scale=1` throughout; spawn/ore transform basis lengths remain 1, with no out-of-bounds centres.
- All ore centres pass shoreline/rock masks and height-based submerged/cliff checks. No ore centre overlaps a rotated bridge deck footprint or its XZ AABB grown by 1.25m. All bridge slabs are nondegenerate and within bounds.
- Ore Y matches independently sampled raw terrain within 0.00002985m. The seven previously reported bridge-height/bridge-footprint ores are cleared without deleting resources. Repair evidence: [resource-repair.json](G:/AIRTS/AI_RTS/agent/runs/map512/migration/resource-repair.json).
- All six generated indexes declare `[512,512]`, source raster `[256,256]`, `cell_m=2` and `world-meters-v2`; their height-data SHA-256 hashes match the actual binaries. The new HTTP geometry contract additionally declares root scale `[1,1,1]` and height scale 1. Older migrated scenes do not carry a separate geometry-contract JSON.
- All **177** unit-related hashes match [unit-hashes-before.json](G:/AIRTS/AI_RTS/agent/runs/map512/unit-hashes-before.json). Units were not enlarged again.

## Runtime Evidence Read

| Implementation-agent run | Engine rc | Assertions / observations |
|---|---:|---|
| [candidate-04](G:/AIRTS/AI_RTS/agent/runs/map512/candidate-04/run.json) | 0 | Four lobby maps plus HTTP map; no dimension/assertion failures; random scene guard accepts valid maps; root/unit scale 1; accepted far-side tank moves; cleanup flag true |
| [rendered-05](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-05/run.json) | 0 | Five Forward+ maps; no dimension/assertion failures; normal screenshots produced and actually opened by this reviewer |

Both runs report map/terrain/minimap 512, fog grid 256x256, camera size 46.75 and camera Y 80. The corrected random-client guard handles JSON float dimensions and `./Geometry/Terrain` SceneState paths. Earlier candidate-03/rendered-02 failures are superseded, not counted as passes.

## Images Actually Inspected

All following normal Forward+ PNGs were opened individually. Their mtimes are 2026-10-11 01:37:20 through 01:38:19, matching the fresh rendered-05 run.

- [PlainAndSimple.png](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-05/PlainAndSimple.png): centred base, flat ground and local reveal circle.
- [map_47-903520021-767a002977.png](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-05/map_47-903520021-767a002977.png): centred base, textured terrain and coherent local reveal.
- [map_36-1846106761-767a002977.png](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-05/map_36-1846106761-767a002977.png): visible base beside a terrain transition; local reveal and framing coherent.
- [map_8-561215132-767a002977.png](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-05/map_8-561215132-767a002977.png): visible base beside a terrain edge; apparent base dimensions consistent with other maps.
- [HTTP map_47-903520021-7544ea830a.png](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-05/map_47-903520021-7544ea830a.png): base and nearby gold ores visible on terrain, with no obvious additional entity scale.

The minimaps show a local revealed spot and camera rectangle at the expected spawn region, but most terrain remains unrevealed. These images do not establish full-map minimap texture alignment, mobile-unit visual size, bridge traversal, mining loops or player-input workflows. The latter movement evidence is command-level, not UI interaction or temporal playtest.

## Residual Gates

- [rendered-05/probe.log](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-05/probe.log) still contains `map_index < 0` errors and missing-sight-range fixture warnings. [candidate-04/probe.log](G:/AIRTS/AI_RTS/agent/runs/map512/candidate-04/probe.log) also contains headless dummy-texture errors and ObjectDB/resource exit leaks. rc=0 and `cleanup_ok=true` do not make these logs clean. Dummy/map-index error classes also occur in the saved baseline; this review does not prove every residual is pre-existing.
- [related-01/summary.json](G:/AIRTS/AI_RTS/agent/runs/map512/related-01/summary.json): movement-scale and navigation-stability rc=0 but `passed=false`/dirty forbidden output; terrain-ground-collision rc=0 and clean; automatic-construction rc=0 with dirty logs; fog-of-war-sight-range rc=1. Full regression and S3 promotion are not established by this review.
- Compatibility/OpenGL rendered-02/03 images were nearly blank despite the base projecting to the centre. Forward+ normal and geometry-only rendered-04 images show the base correctly. The pre-existing shader's renderer-dependent depth reconstruction is a hypothesis for that difference, not a verified repair; the shader was not changed.
- The worktree contains extensive concurrent/pre-existing modifications. No rollback, cleanup, product edit or test edit was performed by this reviewer. The conclusions apply to the inspected snapshot, not to unrelated workspace changes.

## Final Normal-Spawn Evidence

The final probe now uses normal `Match._spawn_player_units`, without manually injected bases. The reviewer read [candidate-06/run.json](G:/AIRTS/AI_RTS/agent/runs/map512/candidate-06/run.json), [candidate-06/measurements.json](G:/AIRTS/AI_RTS/agent/runs/map512/candidate-06/measurements.json), [rendered-06/run.json](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-06/run.json) and [rendered-06/measurements.json](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-06/measurements.json). Each covers Plain, original 47, 36, 8 and the new HTTP 47 map. Every map starts four `command_center` and four `drone` entities, all with root scale `(1,1,1)`. Both measurements have `failures=[]` and `cleanup_ok=true`; world/Terrain/minimap remain 512, fog remains 256x256, and generated maps have `random_accepts=true`. All measured ore centres are in bounds and unblocked. Accepted far-side tank commands produce 6.59-9.32m movement and 1.62-1.72m arrival error; this remains command-level evidence.

Both engines exit rc=0 with `assertions_passed=true`, but both run summaries retain `passed=false` and `log_clean=false`; the implementation agent reports strict runner rc=1. Each run contains nine `map_index < 0` errors. Candidate-06 additionally has 30 known dummy-texture errors; rendered-06 has none. Empty `forbidden_hits` is not a clean-log or overall-pass result. The overall decision remains **needs-review**.

All five normal rendered-06 PNGs were opened individually, with mtimes 2026-10-11 01:49:41 through 01:50:40:

- [PlainAndSimple.png](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-06/PlainAndSimple.png): visible normal-opening base and hovering drone on clear terrain.
- [map_47-903520021-767a002977.png](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-06/map_47-903520021-767a002977.png): visible base/drone with consistent scale and framing.
- [map_36-1846106761-767a002977.png](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-06/map_36-1846106761-767a002977.png): visible base/drone very close to a terrain transition.
- [map_8-561215132-767a002977.png](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-06/map_8-561215132-767a002977.png): visible base/drone very close to a terrain edge.
- [HTTP map_47-903520021-7544ea830a.png](G:/AIRTS/AI_RTS/agent/runs/map512/rendered-06/map_47-903520021-7544ea830a.png): visible base/drone and nearby gold ores.

Normal Forward+ terrain/fog and local minimap reveal/markers/camera rectangles are visible and coherent across these images. Centre grounding does **not** establish support or clearance for the entire building footprint; that check remains unvalidated, especially for maps 36 and 8. Full-map minimap alignment and the other residual gates above also remain unproven. These final artifacts supersede the earlier manually injected-base probe as evidence of normal opening-unit presence, without promoting the overall runtime result.
