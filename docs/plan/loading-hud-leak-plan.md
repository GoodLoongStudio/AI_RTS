# 加载页提前露出对局 HUD Implementation Plan

## Overview
等副官挂上时 Match 已经进树，HUD 是 CanvasLayer，加载页只是普通 Control，对局界面会盖在加载字上面。

## Current State Analysis
`Loading.gd` 先 `add_child(Match)` 再等副官。Match 的 `HUD`/`UI` 是 CanvasLayer，加载页没有更高图层，副官面板和侧栏会提前出现。

## Implementation Strategy
加载页改成高层 CanvasLayer 并铺实底；等副官期间关掉 Match 的 HUD/UI，离开加载页再打开。

## Implementation Steps
1. 本计划
2. Loading 盖住全屏
3. 等副官期间隐藏对局 HUD

## Timeline
本轮只修加载露出，不改副官预热时机。

## Risk Assessment
必须先把 Match 挂上副官才能等挂上；只遮画面，不推迟 `add_child`。

## Success Criteria
加载结束前看不到副官面板、侧栏、小地图。

## Progress Tracking
- ✅ 计划
- ✅ 遮罩
- ✅ 藏 HUD

## Related Files
- `source/main-menu/Loading.tscn`
- `source/main-menu/Loading.gd`
- `source/match/Match.gd`
