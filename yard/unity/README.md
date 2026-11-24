# Unity 联机车场

通用玩法接入可从控制台示例开始。完成相应引擎和物理依赖构建后，从仓库根目录执行 `python -B tools/verify_gameplay_components.py --engine unity`，启动两个本引擎进程验证字段、RPC 和写权交接。[玩法代码](Assets/GameplayComponents.cs) · [构建与预期结果](../../../netcode/task/gameplay-components/验收/本机.md#复现)


Unity 版沿用 Cocos 车场的声明式字段、车辆与闸门规则，以及 `beacon.obj` 三维网格。Unity 创建本地节点，驱动输入和显示插值。房间、模拟、RPC、对象版本和重连由共用的 C++ 运行时处理。

## Windows x64 构建

需要 Unity 6.4（实测 `6000.4.0f1`）、Windows Standalone Support 和项目现有的 Visual Studio C++ 工具链。可通过 `--unity-exe` 或 `NETCODE_UNITY_EXE` 指定编辑器。

```powershell
python -B tools/build.py --unity
```

脚本生成可在编辑器打开的 `out/build/win-x64/Release/unity-project`，并构建 `out/build/win-x64/Release/bin/Release/unity/netcode-unity.exe`。跨引擎测试时可在同一次构建追加 `--cocos` 或 `--godot`。使用 `--steam-sdk` 构建时也会把 Steam 运行时复制到 Unity 插件目录。

## 运行

双击 `netcode-unity.exe` 打开联机页。房主可选随机空闲端口，也可以手填，点击 **Host**。客人输入房主 IPv4 和端口后点击 **Join**。等待页提供房间信息、玩家名单和聊天。房主可点击 **Start game** 或 **Kick**，被踢的客人可以重新加入。

也可以从仓库根目录的两个 PowerShell 窗口直接启动 Unity 房主和客人。

```powershell
.\out\build\win-x64\Release\bin\Release\unity\netcode-unity.exe -- --host --port 43263
.\out\build\win-x64\Release\bin\Release\unity\netcode-unity.exe -- --join 127.0.0.1 --port 43263
```

房主等第二个席位到达后按 F2 开局。WASD 或箭头驾驶，E 开闸门，B 放路障，X 移除，H 鸣笛。客人按 F4 断开，按 R 在同一进程接回原车。车场右侧显示共享 `model` 子节点的 3D 信标。

## 第一阶段真实进程验收

用两个 Unity Windows Player 运行同一车场，核对 TCP/UDP 联机、属性、RPC、对象创建销毁和重连恢复。两端必须正常退出，最终场景状态摘要一致。Unity 还检查实际 GameObject 的信标位置、旋转与缩放。

```powershell
python -B tools/verify_yard.py play --platform unity --port 43263 --capture
python -B tools/verify_yard.py play --platform unity --port 43264 --fault
```

日志、指标和可选截图保存到 `out/runs/last-pass`。[实测报告](../../../netcode/task/unity-platform/验收/验收.md)

## 跨引擎扩展复现

加上 `--guest-platform` 可切换客人的引擎，复跑此前的兼容性验证。

```powershell
python -B tools/verify_yard.py play --platform unity --guest-platform cocos2dx --port 43261 --fault
python -B tools/verify_yard.py stress --platform unity --guest-platform cocos2dx --port 43262 --seconds 10 --fault
python -B tools/verify_yard.py play --platform cocos2dx --guest-platform unity --port 43260 --capture
```
