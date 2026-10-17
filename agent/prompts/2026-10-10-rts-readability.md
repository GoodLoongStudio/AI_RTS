# Reproduce / Refine RTS Proportions

Read AGENTS.md, workspace boundaries and RSI rules. Develop only in `G:/AIRTS/AI_RTS`; do not update packaged releases or manipulate user game/editor processes. Read the corresponding plan and closed-loop report before changing values again.

The approved direction is larger buildings, smaller mobile units and a slightly wider/higher opening view, not a new global world scale. R1 targets: command center/airport +10%, factory/refinery +20%, barracks/turrets +15%, mobile units -8%, opening orthographic size 46.75 and height 66. Building proportions are deliberately type-specific. Do not apply these multipliers again to already-updated files.

Use authored scene values; keep roots at scale one. Synchronize geometry, collider dimensions and centers, movement/obstacle radii, indicator radii, model-relative anchors, both balance construction footprints and exact-value test tables. Preserve collider shape choice and navigation margins. Muzzles below Geometry follow its transform automatically; do not double-scale them. Leave speed, attack/sight ranges, build range, costs, timings and unrelated effects unchanged.

Use `_RtsReadabilityProbe.tscn` with a fresh `AIRTS_READABILITY_OUT` directory. Compare real-Match values against the recorded baseline, not old size reports. Skinned resource AABBs are not animated body measurements; label their limitations. Verify moved units actually arrive, current-match root scales remain one, the match can be freed/restarted, and production spawns stay outside enlarged buildings. Run related regression suites, inspect fresh screenshots and retain an independent review. No long automated playtest unless explicitly requested; the user handles subjective gameplay. Never pop console windows, steal focus, warp the cursor or send OS input.

Write every result, command/exit code and unresolved gate to the closed-loop report. Never infer completion from a screenshot, a successful compile, an old evidence file or a test marker alongside script errors. Do not hide known pre-existing failures.

## R2 Overrides (2026-10-10)

The user explicitly requested retiring Scout, keeping Drone, a larger refinery and the main base as the largest structure. R2 supersedes R1 only for these two buildings and the retired unit. CommandCenter Geometry is 2.145, cylinder radius 4.9764/height 5.9059/centerY 2.95295; OreRefinery Geometry is 1.559999, box 5.928 x 4.0872 x 6.0372/centerY 2.0436. Match both catalogs' construction footprints to 4.9764 and 3.0186 respectively. Do not multiply already-refined values again.

Remove Scout from active catalogs/manifests/contracts/portraits and current test rosters together; preserve scout gameplay actions, roles, lanes and augment tags. Keep old scene/assets and historical probes as inactive references, not current production content. Verify Drone remains discoverable/producible and retired Scout is rejected, and reopen a normal Match to prevent the earlier missing-type startup regression. Do not substitute a hidden model or delete only a single catalog entry.
