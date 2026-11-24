# Godot 4 联机车场

工程已附 Windows x64 的 Netcode 插件和车场桥接。用 Godot 4.7.1 打开 `project.godot`，按 F5 进入[双人驾驶示例](racing/main.tscn)。在两个 Godot 实例中选择车型，一个点 **创建房间**，另一个用同一地址和端口点 **加入房间**。同机默认地址为 `127.0.0.1`。用 WASD 或方向键驾驶，倒车时尾灯亮起。任意玩家可以中途加入。

[主场景](racing/main.gd)只负责连接按钮、选车和出生位置。[车辆脚本](racing/vehicle.gd)负责驾驶与尾灯。新增车型时，把车辆场景加进 **Spawner → Spawnable Scenes**。场景根下的 **Sync** 管理运动和选中的属性。标准车和跑车共用同一份驾驶脚本。

打开 [sync_panel.tscn](sync/sync_panel.tscn)，在场景树展开 **Panel → Network**，单击 **Sync**。编辑器底部会展开 **Netcode 同步属性**，列出分数、灯光可见性和标记位置。点击 **添加同步属性…**，在左侧选节点，在右侧双击属性。这个 Sync 的 **Root Path** 为 `../..`，可以选择整个控制台里的节点。[插件接入手册](../../../netcode/docs/specs/godot-scene-sync.md)

打开 [sync_preview.tscn](sync/sync_preview.tscn) 按 F6，房主和玩家各自实例化这一个场景。点击 **写者加 1 分** 或 **切换指示灯** 查看两端状态；**玩家申请写权** 后由玩家提交所选字段。**玩家广播 RPC** 会在两端各执行一次。

通用玩法接入可从控制台示例开始。完成相应引擎和物理依赖构建后，从仓库根目录执行 `python -B tools/verify_gameplay_components.py --engine godot`，启动两个本引擎进程验证字段、RPC 和写权交接。[玩法代码](../../puzzle/godot/components/components.gd) · [构建与预期结果](../../../netcode/task/gameplay-components/验收/本机.md#复现)

### 工程目录

- `racing/` 双人驾驶入口及车型。
- `yard/` 完整车场及复制逻辑，`yard/lobby/` 放大厅，`yard/objects/` 放车辆和道具模板。
- `sync/` 属性同步预览、共享面板和示例脚本。
- `addons/netcode/` Netcode 插件及编辑器工具，`compat/` 工程内的兼容脚本。
- Godot 专项验证源码按功能放在 [puzzle/godot](../../puzzle/godot)，构建时复制到 Godot 工程的 `verification/`。


### 完整车场与既有验收

在新入口点 **完整车场**，或在编辑器直接运行 [yard.tscn](yard/yard.tscn)，可以体验大厅、闸门和路障。房主选择随机空闲端口或手动输入，点击 **Host**。客人输入房主 IPv4 和端口，点击 **Join**。同机测试可以使用 `127.0.0.1`。

等待页显示房间和玩家信息。玩家可聊天，房主可点击 **Start game** 开局或 **Kick** 移除客人，被移除的客人可以直接重进。

从包目录运行以下命令可直接进入房间，主客机使用同一端口。

```powershell
.\netcode-godot.exe -- --host --port 43240
.\netcode-godot.exe -- --join 127.0.0.1 --port 43240
```

在房主窗口等待 `2/4 seats` 后按 F2。两个窗口各自的绿车为本地玩家。方向键或 WASD 驾驶，E 请求开闸门，B 放路障，X 移除路障，H 鸣笛。客人按 F4 断线，按 R 回原局、接回原车。房主按 F3 结束本局并返回房间，按 Q 结束房间。房主可用 `--bind` 指定 IPv4 监听地址。

车场、复制节点和输入界面运行在 Godot。房间、模拟、状态复制、RPC 与 Winsock 直连来自两个引擎共用的 C++ 目标。

包内四人测试在两个 Godot 命令的用户参数中追加 `--scenario stress --seconds 10`，再启动两次下列命令。四端可同时追加 `--fault`，自动验证 UDP 丢包、重复和乱序后的收敛。

```powershell
.\netcode-guest.exe --join 127.0.0.1 --port 43240 --scenario stress --seconds 10
```

## 从仓库构建和验收

需要 Visual Studio 2026 的 x64 C++ 工具、Python 3.11+ 及 Godot 4.7.1 Windows 版。构建脚本校验并提取固定版本的 godot-cpp。可用 `--godot-exe` 或 `NETCODE_GODOT_EXE` 指定 Godot 图形程序。

```powershell
python -B tools/build.py --godot
python -B tools/verify_yard.py play --platform godot --port 43240 --capture
python -B tools/verify_yard.py stress --platform godot --port 43241 --seconds 10
python -B tools/verify_yard.py stress --platform godot --port 43242 --seconds 10 --fault
```

两种引擎可以用 `python -B tools/build.py --godot --cocos` 一次构建。`verify_yard.py` 的 `--platform` 选房主，`--guest-platform` 可单独选客人引擎。轻量客人使用共用的 `netcode-guest.exe`。

开发启动时，把 `--path out/build/win-x64/Release/bin/Release/godot` 放在 Godot 的 `--` 之前。打包使用 `python -B tools/package_godot.py --verify-play`，需要安装同版 Windows x64 导出模板。ZIP、依赖和运行日志写到本地 `out/`。
