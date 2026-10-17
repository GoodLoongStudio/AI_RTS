# Building Repair Status Icon

Confirmed requirement: a building actively repairing must show a wrench above the building, independently of selection and the repair-targeting cursor. The initial sidebar hypothesis was incorrect and no sidebar source was edited.

1. Reproduce a damaged building repairing without a status icon in a fresh normal Match. Keep the earlier toolbar probe and its too-short HP wait as failed diagnostic evidence.
2. Reuse `cursor_repair.png` in a lazy Sprite3D directly under Structure. Anchor above the model and health bar; billboard, unshaded, no shadow. Do not change repair economics, building size, selection or targeting.
3. Route explicit, full-HP and insufficient-funds stops through the same presentation update. The icon inherits building visibility and is freed with the building.
4. Mirror the server repair flag through the existing snapshot into a presentation-only method, never client repair simulation.
5. Verify actual targeting, HP/resources, persistent icon after leaving targeting, explicit stop, full HP, insufficient funds, sale/death, eight building types and snapshot start/stop. Inspect fresh GPU screenshots in a separate desktop. Run narrow repair/cursor/presentation regressions. No whole-game autonomous playtest.
6. Record original/candidate hashes, commands/rc, screenshots and unverified coverage in a closed-loop report. Keep packaged releases and user windows untouched.

Status: feature candidate verified; global workspace remains `needs-review` because unrelated C# and existing test cleanup failures are still present. Evidence: `agent/runs/20261010-repair-icon/`.
