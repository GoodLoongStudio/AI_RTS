# 桥与坡道素材研究

日期：2026-09-07。范围：`G:/AIRTS/AI_RTS/初选素材包` 的工程模型和分类预览图。结论是桥、坡道不能直接放一个单件模型；应按模块组合，并由视觉接口对齐权威桥端点、宽度和高度。

## 推荐先试的组合

### 首选：4006 科幻世界桥组件套件

这套不是单个桥模型，而是目前初选包里组件最完整的一组：

- `SM_Bld_Bridge_01.fbx`：主桥面模块
- `SM_Bld_Bridge_End_01.fbx`：两端收口
- `SM_Bld_Bridge_Rail_01.fbx`：连续栏杆
- `SM_Bld_Bridge_Rail_End_01.fbx`、`SM_Bld_Bridge_Rail_Half_01.fbx`：栏杆端部和半段
- `SM_Bld_Bridge_Rail_Pillar_01.fbx`：栏杆立柱
- `SM_Bld_Bridge_Strut_01.fbx`：桥下支撑
- `SM_Bld_Bridge_Platform_01.fbx`：必要时作为桥头平台

逐件预览确认后，这组最适合先拼出可识别的完整桥。它的科幻建筑材质可能需要通过视觉 profile 调色，不能与木桥组件混搭。桥面模块的长度、宽度和原点必须用 AABB 实测后再决定重复数量。

### 备选 A：4019 战争地图，木质/战地桥

- `4019_战争地图/PolygonWarMap/Models/SM_Prop_Trench_Bridge_01.fbx`
- `4019_战争地图/PolygonWarMap/Models/SM_Prop_Trench_Bridge_02.fbx`
- 配合同包的短桥端、木梁/支撑和坡口接头素材（以实际预览和 AABB 为准）。

用途：当前河宽较窄、需要一眼看出“跨河设施”的简易木板桥。两件预览显示它们主要是桥面变体，不是完整桥套件；端部、支撑和栏杆需要另找同风格组件，不能直接当首轮完整桥。

### 方案 B：4041 西部土著，木桥 + 土坡过渡

- `4041_西部土著/PolygonWesternFrontier/Models/SM_Env_Bridge_01.fbx`
- `4041_西部土著/PolygonWesternFrontier/Models/SM_Env_Mound_Ramp_01.fbx`
- `4041_西部土著/PolygonWesternFrontier/Models/SM_Env_Quarry_Wall_Ramp_01.fbx`
- `4041_西部土著/PolygonWesternFrontier/Models/SM_Env_Road_Straight_01.fbx`、`SM_Env_Road_Round_01.fbx` 仅作岸边接触过渡候选。

用途：桥头与暖土、岩岸的融合。不能把整条坡道铺成道路贴片；坡道中段仍要露出真实连续坡面。

### 方案 C：463 末日废墟，模块化工业桥

- `463_末日废墟/PolygonApocalypse/Models/SM_Env_Bridge_Clean_01.fbx`、`02.fbx`、`03.fbx`
- `SM_Env_Bridge_Support_01.fbx`
- `SM_Env_Motorway_Bridge_Middle_01.fbx` / `02.fbx`
- `SM_Env_Motorway_Bridge_Edge_01.fbx` / `02.fbx`
- `SM_Env_Motorway_Ramp_Middle_01.fbx` / `02.fbx`
- `SM_Env_Motorway_Ramp_Edge_01.fbx` / `02.fbx`

用途：如果最终视觉采用工业废墟主题，可用中段、边段、支撑和坡道边段拼成完整跨越。必须整套同风格使用，不与 4019 木桥混搭。

## 暂不采用

- 4006 的 `SM_Bld_Bridge_01.fbx` 单件不能直接作为成桥；但与同组端件、栏杆、立柱、支撑组合后，是当前最完整的桥组件候选。科幻建筑色彩可能与当前自然暖土地图冲突，需要统一调色。
- `SM_Env_Detail_Bridge_01.fbx` 尺寸很大，不能按文件名直接缩放使用，必须先核对原点、AABB 和材质。
- 4006 的 Pod/Portal Ramp 多为建筑入口坡道，不适合直接替代自然台地坡面。
- 任何道路贴片、台阶或护栏都不能覆盖真实坡口、桥头、资源区或改变导航。

## 组合验收

每个桥套件至少包含：可见中段、两端收口、必要支撑/栏杆、岸边或坡道接触件。模型只负责视觉；桥面碰撞、桥下水床、坡道高度场和导航继续使用 Qwen 的权威数据。必须在同一镜头检查：桥面不悬空、不穿水，端部不出现矩形切口，单位能从两岸真实通过，桥下水体连续。

素材接入前记录源路径、AABB、原点、材质图集、允许缩放范围和依赖哈希。没有这些数据的候选只列入研究，不得进入最终 G4。
