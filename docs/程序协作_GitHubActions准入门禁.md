# 程序协作：GitHub Actions准入门禁

> 文档状态：重构分支推送前CI基线
>
> 编写日期：2026-08-16
>
> 适用分支：`refactor/dev-20260811-008-repository`及后续Pull Request

## 1. 目的

本文记录当前GitHub Actions负责的自动检查、Godot/.NET版本口径和本地等价入口。CI用于阻止明显架构、构建和场景装配回归，不能替代完整本地回归及人工视觉验收。

## 2. 版本口径

- Godot：`4.7-stable Mono/.NET`；
- Godot C# SDK：`Godot.NET.Sdk/4.7.0`；
- 目标框架：`net8.0`；
- .NET SDK：由`global.json`选择8.0 feature band；
- CI二进制来源：Godot官方`godotengine/godot-builds`仓库的`Godot_v4.7-stable_mono_linux_x86_64.zip`。

本次不把CI单独升级到4.7.1。Godot或`Godot.NET.Sdk`维护版本升级应建立独立需求，统一修改开发机、项目SDK、CI下载、构建和回归记录。

## 3. `.NET 核心构建与测试`

文件：`.github/workflows/dotnet-core.yml`。

触发条件：向`main`提交Pull Request、推送`main`或手动触发。

Windows Runner按顺序执行：

1. 根据`global.json`安装.NET SDK；
2. 输出实际SDK版本；
3. 执行`tools/audit_core_engine_boundary.ps1`；
4. Debug构建`OpenRTS.csproj`；
5. Release构建`OpenRTS.csproj`；
6. 运行`tests/core/AI_RTS.Core.Tests.csproj`。

其中Core审计和Release构建是硬门禁：Domain/Application出现Godot依赖，或测试API发布边界导致Release无法构建时，PR不得合并。

## 4. `Legacy GDScript权威写入审计`

文件：`.github/workflows/legacy-authority-audit.yml`。

该工作流先验证审计器反例，再扫描生产GDScript。新增Action、HP、资源、生产、施工等权威旁路而未经过评审允许时会失败。修改允许清单必须在PR中说明保留原因和后续替换范围。

## 5. `战役模式回归`

文件：`.github/workflows/campaign-regression.yml`。

Ubuntu Runner会：

1. 按`global.json`安装.NET SDK；
2. 从Godot官方二进制仓库下载4.7 Mono Linux包；
3. 构建`OpenRTS.csproj` Debug程序集；
4. 无头导入项目并解析脚本；
5. 启动主菜单、Options、CampaignMenu；
6. 运行`CampaignSmokeTest.tscn`；
7. 无论成功失败都上传诊断日志。

必须使用Mono/.NET包。普通Godot二进制不能作为C#项目的有效场景装配门禁。

以下输出会导致失败：

- `SCRIPT ERROR`、`Parse Error`；
- `UNUSED_PARAMETER`、`SHADOWED_VARIABLE_BASE_CLASS`；
- source脚本或资源加载失败。

战役内容仍处于冻结/延期状态。该工作流只保证入口和现有灰盒场景不被重构破坏，不代表战役系统已经完成。

## 6. 本地完整回归仍是最终门槛

GitHub工作流没有运行全部31个Godot自动场景，因此推送重构分支或合并前仍要在Windows开发机执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\run_full_regression.ps1
```

`config/full_regression_suite.json`同样禁止`UNUSED_PARAMETER`和`SHADOWED_VARIABLE_BASE_CLASS`，并额外检查断言失败、RID/ObjectDB及资源退出残留。

最终交付还应单独确认Release构建0警告、0错误、`git diff --check`通过且工作区干净。

## 7. 后续维护规则

1. 新增公共自动场景时同时更新`config/full_regression_suite.json`；
2. 新增架构强约束时必须进入GitHub PR门禁，而不只写在文档或本地脚本中；
3. Action版本、下载地址和SDK升级不得使用浮动的`latest`游戏引擎版本；
4. CI不得写入密钥、导出证书或真实LLM凭据；
5. CI失败应修复根因，不得通过删除测试、取消禁止输出或添加宽泛忽略恢复绿色；
6. GitHub Runner与本地Godot存在平台差异时，保留两侧日志并按环境问题、Legacy缺陷或迁移回归分类。

## 8. 本次本地验证记录

2026-08-16完成以下推送前检查：

- 官方Godot 4.7 Mono Linux发行包URL经只读HEAD请求返回`200 OK`；
- Core引擎隔离审计通过：43个Domain/Application源文件无Godot依赖；
- `OpenRTS.csproj` Release构建通过：0警告、0错误；
- 启用新增warning门禁后的无跳过完整回归通过：35/35，0失败；
- 31个Godot场景均未输出`UNUSED_PARAMETER`或`SHADOWED_VARIABLE_BASE_CLASS`。

机器可读摘要位于本地`.test-results/full-regression/20260816-002441/summary.json`，该目录按规则不提交。GitHub YAML的实际Runner装配、下载和Linux场景执行仍须在分支推送后以Actions结果为最终证据。
