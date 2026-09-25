# Changelog

## [2026-09-25 - Canonical planning sync]

### Added

- Added `docs/策划文档/AI_RTS_当前产品策划基线_2026-09-25.md` as the canonical product baseline derived from the current `main` implementation.
- Added `docs/策划文档/策划变更日志.md` to track changes in product rules, AI responsibilities, priorities, and delivery assumptions separately from code-level history.
- Documented the implemented RTS foundation, traditional rule AI, AI adjutant, procedural map tooling, growth system, multiplayer demo, campaign/outcome capabilities, local model runtime, and current delivery modes.

### Changed

- Updated the AI adjutant canonical entry from the 2026-09-14 single-model description to the current hybrid runtime: Laya System 1, local MiniCPM5-2B System 2, rule baseline, authoritative validation, and deterministic behavior execution.
- Reframed four-column Task Patch as an internal execution format and established `SquadOrder` plus order leases as the next product-level command abstraction.
- Updated the AI adjutant handbook navigation and principles so historical “single decision model” statements no longer override the current implementation.
- Rewrote the technical integration chapter around the actual `task_patch`, `laya_provider`, state/generation/TTL, rules fallback, behavior tree, and Godot authority chain.
- Replaced the old handbook-only A/B evaluation plan with R0/R1/R2/R3 experiments that separate rule, MiniCPM5-2B, and Laya contributions using real match outcomes.
- Changed near-term product priority toward a winnable rule baseline, atomic squad orders, a reusable campaign Objective Runtime, result-linked model evaluation, and real natural-language command routing.
- Corrected the 2026-09-20 full-package assumptions: torch-free Python applies only to MiniCPM5-2B/Ollama-only delivery; a Laya-enabled package must include and validate Laya's actual ML dependencies.
- Updated `docs/README.md` so the 2026-09-25 product baseline and planning changelog are the primary planning navigation.

### Documented current implementation facts

- Player override, explicit release, per-unit control generations, TTL/stale-result rejection, and model-failure-safe task continuation are established hard constraints.
- The game can start/warm the local Ollama service while rule logic continues during cold start or model failure.
- Laya provider integration, health circuit breaking, self-play data collection/training infrastructure, and the MiniCPM5-2B fallback path are present in the main codebase.
- Growth progression already awards persistent points from match outcomes and applies data-driven upgrades; further growth breadth is deprioritized until the campaign objective loop is complete.
- Voice narration/output exists, while microphone/STT command input remains a planned capability rather than an implemented feature.

## [Unreleased - C# refactor]

### Added

- Added layered `AI_RTS` C# Domain, Application, and GodotAdapter architecture with a Godot-independent Core assembly.
- Added shared command, query, economy, construction, production, rally point, control group, match outcome, input, and strongly typed balance configuration services.
- Added public command/query boundaries for players and traditional rule AI while keeping the LLM officer integration frozen.
- Added 101 pure C# tests, 31 Godot automated scenes, a complete regression runner, architecture audits, and GitHub Actions gates.
- Added project structure, extension, interface review, manual acceptance, performance baseline, and deferred-work documentation.

### Changed

- Migrated the main RTS execution paths and traditional AI authority writes toward C# services while retaining audited Legacy GDScript adapters where migration is intentionally deferred.
- Updated the project baseline to Godot 4.7 Mono/.NET, `Godot.NET.Sdk/4.7.0`, and .NET 8.
- Separated the traditional RTS command HUD and control groups from the frozen Legacy AI officer interface.

### Fixed

- Fixed unit and structure runtime placement collapsing near the map origin.
- Fixed Stop cancellation, projectile post-launch damage ownership, helicopter command integration, construction damage notifications, match victory reporting, generated UID tracking, and Godot shutdown resource leaks.

### Deferred

- Navigation quality and large-unit optimization, advanced combat policies, formation/scatter/plan commands, campaign migration, detailed traditional AI design, and Python/LLM/database integration remain separate follow-up work.

## [main]

### New features
 - Added structure rally points

### Changed
 - Godot 4.1 support added instead of Godot 4.0 (4.0 support is still present on branch)

## [0.9.0]

### New features
 - Added 'loading page' translations
 - Added ability to use custom maps
 - Added 2 new maps
 - Added match setup page

### Changed
 - Performed various refactorings
 - Simplified turret's rotation algorithm
 - Removed redundant unit groups
 - Extracted generic `MouseClickAnimation`
 - Improved `assert()` calls
 - Renamed `buildings` to - more generic - `structures`
 - Made `SimpleClairvoyantAI` being able to attach units in runtime

## [0.8.1]

### New features
 - Added resource tooltips
 - Added unit production/construction tooltips
 - Added main menu background
 - Added match loading page
 - Added diagnostic FPS monitor

### Changed
 - Increased units HP by a factor of 2

## [0.8.0]

### New features
 - Added animated logo sequence on startup
 - Added basic main menu with options etc.
 - Added match with hardcoded map and features such as:
   - Settings
   - Isometric 3D camera
   - Fog of war
   - Terrain/Air navigation
   - Units & structures
   - Resources (blue/red crystals)
   - UI (unit selection mechanism)
   - HUD (resource counters, unit management panels)
   - Menu
   - Dynamically created human/AI players
   - Debug utilities (God mode etc.)
