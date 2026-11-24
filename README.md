# Netcode 示例

本仓库集中维护 Netcode 游戏示例、Godot 教学项目和验收工具。四个 SDK 的源码、安装与发布说明见 [Netcode 框架仓库](https://github.com/bobozai2019/photon_fusion_copy)。

| 路径 | 用途 |
| --- | --- |
| [yard/shared](yard/shared) | 三端共用的车场规则、布局、信标和轻量客人 |
| [yard/cocos2dx](yard/cocos2dx) | Cocos 界面、桌面应用和专用服务器入口 |
| [yard/godot](yard/godot)、[yard/godot-native](yard/godot-native) | Godot 驾驶与车场工程、独立车场扩展 |
| [yard/unity](yard/unity)、[yard/unity-native](yard/unity-native) | Unity 玩法、编辑器构建入口与车场专用 DLL |
| [puzzle](puzzle) | 机关、写权交接、刚体以及字段和 RPC 验证 |
| [shiftline](shiftline) | 可在 Godot 编辑器中运行的局域网 FPS |
| [sync-lab](sync-lab) | 两个可操作的 Godot 客户端，用正常 TCP 房间观察属性同步和 AOI 切换 |
| [position-replicator](position-replicator) | Godot C++ 属性采样、差量复制和丢包重传演示 |
| [sdk-lock.json](sdk-lock.json) | 此版示例实测的四个 Release 包及 SHA-256 |

Photon 原版对照项目可从官方渠道获取。[Racing Starter Kit](https://doc.photonengine.com/fusion-godot/v3-shared-authority/game-samples/racing-starter-kit)

## 本地运行

若从 GitHub 新建工作区，可将两个仓库克隆到同一父目录。

```powershell
git clone https://github.com/bobozai2019/photon_fusion_copy.git netcode
git clone https://github.com/bobozai2019/netcode_example.git examples
cd examples
```

Shiftline、Godot 车场、Sync Lab 和属性采样示例已附各自的 Windows x64 插件。Shiftline 和车场可在 Godot 打开对应的 `project.godot`。Sync Lab 首次运行使用 [启动脚本](sync-lab/launch.bat)，它会登记原生扩展。Photon 对照模式需另行安装 Fusion SDK。

以下构建、刷新插件和验收命令在示例仓库根目录执行。默认使用同级框架的 `out/install/win-x64-msvc-mt/<配置>/<产品>`。传入 `--sdk-root` 可以改用其他安装位置。单独取得本仓库时，也可以把 SDK 解压为这套布局，Unity 的 tgz 解到 `unity/` 时去掉内部的 `package/` 前缀。生成的游戏交付包位于本地 `out/packages/`。

```powershell
python -B tools/prepare_godot_fps.py
python -B tools/verify_godot_fps.py
python -B tools/build.py --godot --unity
python -B tools/prepare_godot_yard.py
python -B tools/verify_godot_racing.py
```

FPS 准备脚本默认用锁文件校验插件包。可通过 `NETCODE_PACKAGES` 指向保存四个发布包的目录。开发时可以显式指定 `--addon <本地插件ZIP>`。打开 [Shiftline](shiftline/project.godot) 或[赛车项目](yard/godot/project.godot) 后按 F5。

Cocos 构建可单独启用 `--cocos`。完整物理用例需要 `--chipmunk-root` 和 `--bullet-root`，并使用与这两个物理开关匹配的 Cocos SDK。可用 `--deps-cache` 或 `NETCODE_DEPS_CACHE` 指定共享依赖目录，已有工作区可以复用旧 Release 构建树中的下载和 vcpkg 安装。三种引擎一同构建时，在一次命令中列出所需引擎。随后执行 `python -B tools/verify_gameplay_components.py` 检查三组联机。

## 外部接入复验

```powershell
python -B tools/verify_sdk_install.py godot
python -B tools/verify_sdk_install.py unity
python -B tools/verify_cocos_install.py
```

前两条命令在系统临时目录内生成项目，安装锁定的 ZIP 或 UPM 包，导出 Windows Player，冷启动两个玩家。Cocos 命令复用本机已有的引擎库和第三方依赖，重新解压 Core、Cocos SDK 并编译外部客户端。三项均检查实际加载的构建标识、八个字段、客人分数 42 和双向 RPC。Cocos 首次复验前须完成启用两种物理的车场构建。
