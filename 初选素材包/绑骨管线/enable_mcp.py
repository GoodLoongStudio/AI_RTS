import bpy
bpy.ops.preferences.addon_enable(module="blender_mcp")
bpy.ops.wm.save_userpref()
bpy.ops.blendermcp.start_server()
print("MCP_SERVER_STARTED")
