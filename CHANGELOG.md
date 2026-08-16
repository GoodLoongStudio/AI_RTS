# Changelog

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
