namespace AI_RTS.Domain.Common;

/// <summary>表示不依赖 Godot 类型的世界三维坐标。</summary>
/// <param name="X">世界坐标 X 分量。</param>
/// <param name="Y">世界坐标 Y 分量。</param>
/// <param name="Z">世界坐标 Z 分量。</param>
public readonly record struct WorldPosition(float X, float Y, float Z);
