from pathlib import Path

p = Path(r"G:\AIRTS\AI_RTS\source\net\DebugControlServer.gd")
text = p.read_text(encoding="utf-8")
old = (
    '\t\t"nav_ms": snappedf(Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0, 0.01),\n'
    '\t\t"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),'
)
new = (
    '\t\t"nav_ms": snappedf(Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0, 0.01),\n'
    '\t\t"nav_static_obstacles": _nav_static_obstacle_count(match_node),\n'
    '\t\t"gpu": RenderingServer.get_video_adapter_name(),\n'
    '\t\t"gpu_vendor": RenderingServer.get_video_adapter_vendor(),\n'
    '\t\t"cpu_threads": OS.get_processor_count(),\n'
    '\t\t"physics_ticks": Engine.physics_ticks_per_second,\n'
    '\t\t"max_physics_steps": Engine.max_physics_steps_per_frame,\n'
    '\t\t"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),'
)
if old not in text:
    raise SystemExit("old block not found")
p.write_text(text.replace(old, new, 1), encoding="utf-8")
print("patched op=perf")
