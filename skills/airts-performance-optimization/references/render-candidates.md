# 保画质渲染与特效候选

审计日期：2026-10-07；本页各实现均为 `structural-candidate`，没有新 FPS 收益实测。GPU 不是热点时，先做 CPU 项。

## R1：同资源共享和按区域实例化

入口：`source/match/units/Unit.gd::_team_shader_material`、资产材质绑定、地图装饰。已有 team material cache 和大量 `meshes/generate_lods=true`，不是“完全没做优化”。运行时检查 mesh/material identity、surface 数、draw calls 和可见物体数。

先减少相同内容的资源复制/材质拆分。Forward+ 对相同 mesh/material 的不透明或 alpha-tested MeshInstance3D 有自动实例化；不能假设 Compatibility/Mobile 同样支持，实际后端从运行记录读。[Godot 3D 优化](https://docs.godotengine.org/en/stable/tutorials/performance/optimizing_3d_performance.html)

MultiMesh 优先用于相邻、同 mesh/material 的静态碎石/草/装饰或纯表现符号；按空间块、材质/mesh、必要 LOD 层组织，保留实例 ID 映射、选择/阵营/显隐分离。不要把普通多 mesh/骨骼的战斗单位整批替换后丢掉动画/选择/迷雾。

单个 MultiMesh 的实例无法逐个视锥剔除，必须控制 chunk AABB；全图一个批次可能让屏外几何全部绘制，反而变慢。池容量、可见实例和上传字节一起测。参考页有 4.7 未更新提示，实现需运行时核验。[MultiMesh 边界](https://docs.godotengine.org/en/stable/tutorials/performance/using_multimesh.html)

验证：同视点 draw calls/triangles/CPU render/GPU time；逐玩家 fog 隐藏、实例变色/选择/死亡/回收；不能只靠截图“看起来差不多”。

## R2：地形分块，先不减细节

入口：`source/match/maps/generated/GeneratedTerrain.gd::_build`。当前创建整图单个 ArrayMesh surface；513×513 的样例网格按代码为 263,169 顶点、524,288 三角形（计算值，不是所有地图运行测量）。相机只看一块，但该物体整图 AABB 相交，无法按局部块剔除。

第一候选是保持相同顶点/三角形/UV/法线/材质，按相邻空间 tile 构建和剔除；边界顶点一致，法线仍使用全局高度邻域以免接缝。chunk 大小不是越小越好，测新增 draw calls/对象维护和省下的 triangles，所有可见块也必须连续。

第二候选才是远处地形 LOD/误差受限简化，最近相机保留原网格；边界 stitching 或裙边不露缝，桥面/坡道/崖壁剪影不可消失。权威高度采样、禁行格、建造、导航、射线不改，不能把视觉网格简化当成物理简化。

地形 shader 当前采样多种纹理；只在 GPU fragment 热点证据下查重复纹理 fetch、分支和遮挡/overdraw。mipmap/纹理压缩要检查法线和掩码语义，不能统一低分辨率或把 sampler 数当成所有分支实际执行次数。

验证：最近/正常/最远缩放、相机横移、tile 交界、湖边/坡道/桥面、地图边界；像素/深度/剪影对照和性能同时成立，生产生成图与小平地图分开测。

## R3：实际生效的屏幕空间 LOD 和阴影代理

已有导入配置不证明运行网格有有效 LOD；检查导入产物、实际 viewport threshold、各 surface 的 LOD 和三角形变化。Godot 的自动 LOD 按屏幕空间误差选择；默认 1px 偏向视觉无损，先用它核验，不直接把阈值大幅提高。[Mesh LOD](https://docs.godotengine.org/en/stable/tutorials/3d/mesh_lod.html)

RTS 用正交相机，远近和缩放要以屏幕投影大小验证；只用 camera 世界距离裁单位/装饰可能不合理。保护步兵/坦克/重坦/矿车/建筑的轮廓、阵营色和炮管/炮塔方向；skinned LOD 需检查运动中的畸变。对 HLOD 切换使用合理滞回防跳变。

阴影优先考虑低复杂度、轮廓贴合的 shadow proxy 或只剔除投影无贡献的细节；保持近处移动单位/建筑的接地感和动态方向。统计 shadow pass draw calls/triangles，避免主网格与代理重复投影。不能一键关所有阴影/环境光遮蔽。

`PerformanceGovernor.gd` 动态画质默认关闭但锁 30 FPS，局部地图路径仍可能有另外的预算：GeneratedTerrain `_apply_g4_runtime_budget` 关部分地图灯光阴影，`_apply_g4_decoration_budget` 有固定距离剔除，Match/大型图配置也可能调整呈现。基线应记录实际最终参数，不以 dynamic_quality=false 证明画质全相同。

`Match.tscn` Fog/ScreenOverlay 的大 extra_cull_margin 用来覆盖屏幕，不能批量删掉当 culling 优化。先区分 overlay 和真正可剔除的世界网格。

## R4：粒子、透明 overdraw、池化与着色预热

入口：ShellExplosion、BloodMist、炮弹/火箭 Trail、采矿 SparklingAnimation、MouseClickAnimation、CommandVisualizer。当前主要是 GPUParticles3D，不能把“全部改成 GPU 粒子”当成新方案。

- 首选共享资源、预热复用、正确 visibility AABB、去掉纯表现节点无用 shadow/GI（以当前已有设置为准）、减少重复构建。测试高密度爆炸 instantiate 和首次 shader/pipeline stall，预热在加载阶段且可取消，不把卡顿换到无限加载。
- 透明烟/火/环/路径容易 overdraw。减少空白区域和重叠重复面、合并同材质路线是候选；透明 alpha 混合不能机械改 alpha scissor，否则烟雾外观/排序变坏。
- 相机外的纯视觉粒子可裁渲染或预算更新，但需考虑其尾迹/烟羽实际边界、能否投影到画面及重进镜头状态。保留音效/威胁/事件信息；绝不跳过权威 projectile ResolveImpact。
- 屏幕空间粒子 LOD/动态灯预算属于有限画质改变。首先保留命中首闪、爆炸核心与死亡反馈，再对难以辨别的烟雾末端/细碎粒子评估；移动点击和采矿反馈不能被低优先级限额吞没。距离、数量、覆盖面积、持续时间由测量选择，不统一固定倍率缩小特效。

验证：同随机种子及生命周期相位对照，多帧/视频检查；密集交火、采矿、连续右键、死亡与屏边切入；GPU 时间/overdraw/对象峰值、内存回落、效果触发数/丢弃数与命中伤害分开统计。

## 不默认使用

遮挡剔除在街道/密集建筑可能有效，但俯视开阔沙漠少遮挡，CPU 维护可能倒亏；先做 representative A/B，不为性能改变地图设计。烘焙光照可服务静态地图美术，但运行中建造/破坏的建筑和单位仍需动态光影，不作为本项目的一键替代方案。大规模 ECS/C++/RenderingServer 重写只有局部热点和成熟机制无法达标时才单独规划。
