namespace AI_RTS.Domain.Combat;

/// <summary>定义单位自主发现目标后允许采取的移动与追击策略。</summary>
public enum EngagementStance
{
    /// <summary>主动搜索并追击感知范围内的敌方目标，但仍受最大追击范围约束。</summary>
    Aggressive,

    /// <summary>在岗位范围内迎击目标，并在脱离后返回 GuardAnchor。</summary>
    Guard,

    /// <summary>不主动移动或追击，只攻击已经进入武器射程的目标。</summary>
    HoldGround
}

/// <summary>定义单位是否允许自主开火；显式 ForceAttack 可获得订单级临时授权。</summary>
public enum FirePolicy
{
    /// <summary>允许单位按照 EngagementStance 自主选择并攻击目标。</summary>
    FireAtWill,

    /// <summary>禁止自主开火，但不阻止具有临时授权的显式 ForceAttack。</summary>
    HoldFire
}

/// <summary>表示武器和目标所在的导航/攻击空间。</summary>
public enum CombatDomain
{
    /// <summary>地面单位、建筑和地表目标。</summary>
    Terrain,

    /// <summary>飞行单位和空中目标。</summary>
    Air
}
