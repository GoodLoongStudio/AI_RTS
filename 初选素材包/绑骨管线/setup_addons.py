import bpy
import addon_utils

# 禁用与 Blender 5.0 不兼容、每次启动刷屏的 HOps
try:
    addon_utils.disable("HOps", default_set=True)
    print("HOps disabled")
except Exception as e:
    print("HOps disable failed:", e)

# 启用 blender_mcp
try:
    addon_utils.enable("blender_mcp", default_set=True)
    print("blender_mcp enabled")
except Exception as e:
    print("blender_mcp enable failed:", e)

bpy.ops.wm.save_userpref()
mods = [a.module for a in bpy.context.preferences.addons]
print("ADDON_STATE_MCP:", [m for m in mods if "mcp" in m.lower()])
print("ADDON_STATE_HOPS:", [m for m in mods if "hops" in m.lower()])
