"""presentation：G4 视觉扩展层（GLM 交接冻结接口）。

公开入口：
- build_visual_plan(context, profile, visual_seed) -> VisualPlan（dict）
- load_profile(name)：读取 rtsmap/data/visual_profiles/<name>.json
- build_zones(context)：语义掩码（forbidden/decorable），GLM 只能收紧
- plan_fingerprint(plan)：确定性指纹
- VisualPlanError：缺资源/不兼容必须抛出，不静默回退

详见 docs/plan/workbench-team/handoff/visual-api.md。
"""
from .visual import (VISUAL_API_VERSION, VisualPlanError, build_visual_plan,
                     build_zones, load_profile, plan_fingerprint)

__all__ = ["VISUAL_API_VERSION", "VisualPlanError", "build_visual_plan",
           "build_zones", "load_profile", "plan_fingerprint"]
