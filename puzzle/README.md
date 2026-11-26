# 拼图与通用玩法示例

## 三进程拼图

Windows x64 默认构建使用 Debug Core SDK。先在同级 `netcode` 仓运行 `python -B tools/build.py core --config Debug`，再在 `examples` 仓根目录运行以下命令。

```powershell
python -B tools/build.py
python -B tools/verify_puzzle.py --port 43270
```

验证工具启动一个房主和两个客人，使用同一 TCP／UDP 端口，通过标准输入驱动各端。输出包括本地落子与公开值、最后接纳序号、授权代次、交接时间和每端流量。原始证据随其他联机运行一起轮换。

手动运行时用三个独立终端，两位客人按 B、C 的顺序连接：

```powershell
.\out\build\win-x64\Debug\puzzle\Debug\netcode-puzzle.exe host 43270
.\out\build\win-x64\Debug\puzzle\Debug\netcode-puzzle.exe join 43270
.\out\build\win-x64\Debug\puzzle\Debug\netcode-puzzle.exe join 43270
```

| 终端 | 输入 | 结果 |
| --- | --- | --- |
| A | `status`，看到三席后输入 `start` | 创建 X（对象 1）和 Y（对象 2）。 |
| B、C | `show 1` | 读取基线，X 位于格 2。 |
| A | `grant 1 2`、`grant 2 3` | 分别授予 B、C。客人用 `show` 等待看到对应写入者。 |
| B | `move 1 5 1` | 将 X 放到格 5，朝向 1。 |
| C | `move 2 7` | 将 Y 放到格 7。 |
| A | `protect`、`grant 1 3` | 写入 X 的房主专属标志，然后转交 X。 |
| C | `move 1 9 3` | 将 X 放到格 9，朝向 3。 |
| A、B、C | `show 1`、`show 2` | 检查公开值和授权代次。 |
| A | `grant 1 1`、`end` | 收回 X 并结束房间。 |
| A、B、C | `quit` | 退出进程。 |

验证工具还用 `mute` / `unmute` 暂缓 B 处理公开快照和接纳确认，并用 `hold` / `release` 把 B 的一次上行延迟到转交后。

房主输入 `scene` 生成场景 20 的记分板，依赖棋子 2。用 `scope 2 10` 让玩家 2 离开，`award` 更新分数和队名，再用 `scope 2 20 2 3` 只订阅依赖及记分板。玩家 2 通过 `visible 3` 读到 16777219 和 South，玩家 3 始终可见。房主可用 `retire` 销毁记分板；自动化还核对了旧快照和隐藏记录的顺序。[三进程验证](../tools/verify_puzzle.py) · [乱序回归](../../netcode/tests/core/interest_test.cpp)

客端命令 `loading 20` 和 `loaded 20` 模拟本机场景资源异步加载。网络基线可以先到，记分板等场景和棋子都就绪后才出现在 `visible 3` 中。自动验收还包括玩家离开持权棋子的可见范围、房主收回写权、该玩家重新进入的过程。

## 通用玩法控制台

房主创建一个控制台和两个原生刚体。客人先检查控制台的八个成员、引用所指的二维刚体和三维刚体的位置，再申请控制台的写权。房主同意后，客人把分数从 7 改为 42 并发送 `Report(42, "ready", Vector2(2, -3))`。房主确认本地成员也变成 42 后向该客人发送 `Done()`。

| 玩法入口 | 属性接入 | 命名方法 |
|---|---|---|
| [Godot](godot/components/components.gd) | 给子节点配置属性路径，调用 `bind` | `bind_method` 登记 Callable |
| [Unity](../yard/unity/Assets/GameplayComponents.cs) | 给 `NetcodeReplica.Fields` 配置成员和字段号，调用 `Bind` | `BindCallable` 登记 C# 委托 |
| [Cocos2d-x](components_cocos.hpp) | `ReplicaComponent::attach` 绑定节点，按模板顺序登记成员 | `bind_callable` 登记 C++ 回调 |

两端先打开会话、按控制台模板 1 登记可写字段 `[1]`，再注册方法。房主开局并生成网络对象。样例按固定生成顺序预绑定对象 1、2、3；动态生成的玩法应使用实际对象号绑定本端场景实例。给组件绑定对象后，还需持续驱动会话：Godot 在 `_process` 调用 `game.advance()`，Unity 在 `Update` 调用 `game.Advance()`，Cocos2d-x 在挂有 `GameComponent` 的场景上调用 `scheduleUpdate()`，由组件的 `update` 推进。组件收到首次基线后，样例才写入初始玩法值。

申请写权成功发出后仍要等待授权。样例在 `writer` 指向本玩家时提交分数，在 `Unavailable` 时按自己的策略等待 250 ms 再申请。房主核对已复制的分数及 `Report` 回调后才回复，两者可按不同顺序到达。[GDScript 完整流程](godot/components/components.gd) · [会话与写权规格](../../netcode/docs/specs/game-session.md)

三端共用控制台、方法参数和刚体模板。先按说明构建含物理依赖的 Release 客户端，再从仓库根目录运行。默认依次双开 Godot、Unity、Cocos2d-x；单测使用 `--engine godot`、`--engine unity` 或 `--engine cocos`。[配置](components.cfg) · [构建依赖及预期结果](../../netcode/task/gameplay-components/验收/本机.md)

```powershell
python -B tools/verify_gameplay_components.py
```

## 合作机关示例

同一份 [plates.cfg](plates.cfg) 为每块机关声明格子、名称和倒计时截止毫秒。两名客人分别申请机关的状态写权。第一个把 Amber 放到格子 3，第二个把 Jade 放到格子 7。房主和双方都能看到结果。Godot、Unity 和 Cocos2d-x 各自使用自己的场景、脚本和节点。

`verify_plates.py` 是历史兼容性实验，每场各开一个 Godot、Unity、Cocos2d-x 进程，轮换房主。`--forecast` 选择各平台的原生二维刚体。同引擎字段、RPC 和写权验收使用上一节的 `verify_gameplay_components.py`。下列第三条是独立的 Core Debug 测试，使用三个 Core 进程验证房主退出后的接替。

```powershell
python -B tools/verify_plates.py --port 43470
python -B tools/verify_plates.py --forecast --port 43476
python -B tools/verify_migration.py --port 43490
```

[Godot 机关脚本](godot/plates/plates.gd) · [Unity 机关脚本](../yard/unity/Assets/PressurePlates.cs) · [Cocos2d-x 机关组件](cocos_main.cpp) · [构建依赖和验收数据](../../netcode/task/fusion-client-parity/验收/记录.md)

### 房主交接和成组回放

历史脚本 `tools/verify_script_handoff.py` 使用 Unity 和 Godot 交错组成三人房，记录首任房主退出及后续双人主动交接。独立 Core 进程的接替测试使用上一节的 `verify_migration.py`。

`python -B tools/verify_physics_island.py` 分别启动两份同引擎玩家程序。房主把第 45 步的完整物理组和第 70 步的权威位置传给客人。客人恢复堆叠箱体及带关节的刚体，重演相同输入并返回确认。默认分别验证三组同引擎配对，可用 `--engine godot`、`--engine unity` 或 `--engine cocos` 只跑一组。九种求解器配对的旧矩阵和权威重置误差另见历史实测。[组字段布局](island.cfg) · [实测数据](../../netcode/task/fusion-client-parity/余项验收.md)

## Godot 声明式控制台

[场景](godot/sync/scene_controls.tscn) · [对象脚本](godot/sync/switch_panel.gd) · [三玩家联机流程](godot/sync/scene_controls.gd) · [接入手册](../../netcode/docs/specs/godot-scene-sync.md)。Windows x64 上运行 `python -B tools/build.py --godot`，再运行 `python -B tools/verify_godot_scene.py`。
