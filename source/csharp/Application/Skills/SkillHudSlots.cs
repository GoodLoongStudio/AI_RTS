using AI_RTS.Domain.Common;
using AI_RTS.Domain.Skills;

namespace AI_RTS.Application.Skills;

/// <summary>HUD 只读技能槽；冷却剩余按模拟毫秒计算。</summary>
public sealed record SkillHudSlot(
    SkillDefinitionId SkillId,
    SkillTargetKind Target,
    int CooldownRemainingMilliseconds,
    bool IsReady);
