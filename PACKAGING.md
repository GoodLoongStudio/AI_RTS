# 打包与运行（Windows 可执行包）

本文面向「拿到本仓库链接、想自己打出一个可直接玩的 Windows 包」的人。
作者本机的实际打包记录见 `.workbuddy/memory/2026-09-20.md`。

## 0. 结论速览

- **产物**：单文件 exe（约 500MB）。双击即玩，**玩家侧不需要装 Godot、不需要装 .NET**（运行时已打进包）。
- **玩家侧要求**：Windows 10/11 x64 + 独立显卡（项目用 Forward+ 渲染）。
- **打包机需要**：Git + Git LFS、.NET SDK 8、Godot 4.7.1 .NET(Mono) 编辑器、**4.7.1.stable.mono 导出模板**（最容易卡的一步，见 §1.2）。
- **一键脚本**：`tools/build_windows.ps1`（自动做检查 + 导入 + 导出，见 §8）。

## 1. 打包机环境准备

| 组件 | 要求 | 说明 |
|---|---|---|
| Git + **Git LFS** | 较新版即可 | ⚠ **必须装 git-lfs**。仓库里的模型/贴图/音频由 LFS 存储，未装 LFS 时 clone 出来是一行 `version https://git-lfs...` 指针文本，游戏资源会全缺 |
| .NET SDK | **8.0**（含 8.0.100） | 仓库 `global.json` 钉了 8.0.100；导出时要编译 C# |
| Godot | **4.7.1 .NET (Mono)** | 安装包名含 `_mono_`；版本须与 `project.godot` 的 4.7 匹配 |
| 导出模板 | **4.7.1.stable.mono** | 约 1.2GB，见 §1.2 |
| 磁盘 | ≥ 10GB 空闲 | clone 后工作区约 2GB，另需导入产物与导出中间物 |

### 1.2 导出模板下载（最容易卡住的一步）

1. 官方归档页下载 `.NET` 版模板：
   <https://godotengine.org/download/archive/4.7.1-stable/> → `mono_export_templates.tpz`
2. 或直链公式（302 跳转，需跟随跳到对象存储）：
   ```
   https://downloads.godotengine.org/?version=4.7.1&flavor=stable&slug=mono_export_templates.tpz
   ```
   命令行取真实地址：`curl -I -L "<上面的 URL>"` 看最后一个 `Location`。
3. **已知坑**：清华 / TuxFamily 等镜像**没有** 4.7.1 的 mono 模板，必须走官方直链。
4. **解压很慢**：1.2GB、文件数极多，作者本机实测约 1.5 小时。解开后是一个 `templates/` 目录。
5. 安装位置（目录名必须是版本字符串 `4.7.1.stable.mono`）：
   ```
   %APPDATA%\Godot\export_templates\4.7.1.stable.mono\
   ```
   即 `C:\Users\<你>\AppData\Roaming\Godot\export_templates\4.7.1.stable.mono\`；
   若你自定义了 Godot 用户数据目录（如 self-contained 模式），放到对应目录的 `export_templates\4.7.1.stable.mono\`。
   也可以在编辑器里：`编辑器/Editor → 管理导出模板 → 从文件安装`。

## 2. 拉取代码

```shell
git lfs install
git clone https://github.com/GoodLoongStudio/AI_RTS.git
cd AI_RTS
git lfs pull
```

**自检 LFS 是否生效**：随便打开一个 `assets/models/scifi-worlds/*.fbx`——
正常应是二进制乱码；如果只看到 `version https://git-lfs.github.com/spec/v1` 一行字，
说明 LFS 没生效，重装 git-lfs 后执行 `git lfs pull`。

## 3. 首次导入（必须做一次）

用 **Godot 4.7.1 .NET 编辑器**打开仓库目录，等右下角导入/扫描进度跑完，再关闭。

命令行等价写法：

```shell
"<Godot_v4.7.1-stable_mono_win64_console.exe>" --headless --path "<仓库目录>" --import
```

> 为什么必须：`.godot/` 导入缓存不入库。不导入直接导出，会得到缺资源/黑屏的包
> （导入产物缺失时 Godot 的 `load()` 静默返回 null，不报错）。

## 4. 导出

命令行（推荐）：

```shell
"<Godot_v4.7.1-stable_mono_win64_console.exe>" --headless --path "<仓库目录>" ^
  --export-release "Windows Desktop" "build/Open RTS.exe"
```

或编辑器 GUI：`项目 → 导出 → 选 "Windows Desktop" → 导出项目`。

- 预设已开启 `embed_pck`，产出**单文件** exe（约 500MB）。
- 控制台版（`*_console.exe`）会打印导出日志，排错用它。

## 5. 验证与分发

- 双击 exe：能进主菜单 → 开局 → 造兵 → 放塔，即打包成功。
- 分发：把 exe 直接发给玩家即可（自带 .NET 运行时，玩家不需要装任何东西）。
- 需要「安装向导」（开始菜单/桌面快捷方式）时要额外用 Inno Setup 等工具封装，本仓库不含该流程。

## 6. 已知事项（先读，避免误判）

- **导出包里没有 AI 副官功能**：副官需要 Python 环境 + 本地 Ollama 模型 + 仓库目录布局（§7）。
  导出版里「副官」面板会显示“尚未启动”，属预期，不影响正常玩法。
- **联机页默认服务器地址指向作者的云服**（`source/net/NetSession.gd` 的 `DEFAULT_HOST`）。
  单机玩不受影响；要给他人联机请自行改地址或自建服。
- **商用素材源包已移出仓库**：`初选素材包/`（2.8GB 商用 FBX 源包）不在仓库里，
  游戏运行与打包都不需要它（已被采用的素材在 `assets/models/**`）。
- **导出预设仍是上游默认品牌**：产品名 `Open RTS`、公司 `Lampe Games`、无自定义图标；
  要改成自己的，改 `项目 → 导出 → Windows Desktop` 的图标与元数据（或直接改 `export_presets.cfg`）。

## 7. （可选）AI 副官本地环境

> 只有「在源码目录里用 Godot 运行游戏」时才可能启用；导出给玩家的 exe 用不了。
> 没配也能玩，游戏会走规则中台兜底。

1. **Python 3.11+ 虚拟环境**
   ```
   python -m venv <你的 venv 路径>
   <venv>\Scripts\python -m pip install -r source/adjutant_coordinator/requirements-graph.txt
   ```
   （细节以 `source/adjutant_coordinator/README.md` 为准。）
2. **Ollama（本地推理）**
   - 副官使用的模型标签：`minicpm5-adj-16k`（MiniCPM5-2B，Q8_0，`num_ctx=16384`，约 2.7GB）。
   - 该标签是**本地自建**的（基础 MiniCPM5-2B 以本地 GGUF 创建，不是 registry 官方名）。
     重建等价 Modelfile：
     ```
     FROM <你的 MiniCPM5-2B GGUF 路径 或 已有基础标签>
     TEMPLATE {{ .Prompt }}
     PARAMETER num_ctx 16384
     PARAMETER num_predict 512
     PARAMETER temperature 0
     PARAMETER top_p 0.95
     ```
     `ollama create minicpm5-adj-16k -f Modelfile`
   - 模型**不随仓库分发**（Ollama 有自己的模型管理；2.7GB 的 blob 不适合进 git）。
     离线分发的办法是整体拷贝 Ollama 的模型目录（`OLLAMA_MODELS` 指向的目录）。
3. **配置**：`source/adjutant_coordinator/.env.local`（默认端点 `http://127.0.0.1:11434/v1`）。
4. 游戏内：`副官 → 接管` 启动；本机需能找到 python（仓库约定布局或
   `user://adjutant_local.cfg` 指定）。

## 8. 一键脚本

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1
powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1 -Godot "D:\Godot\Godot_v4.7.1-stable_mono_win64_console.exe"
```

脚本依次检查：git-lfs → .NET SDK → Godot 版本 → 导出模板，然后执行首次导入与导出，
最后打印产物路径与大小。任一步不满足会给出明确提示并停止。
