
# Breakwater · Horde Survivors 3D

Windows x64 上的双人 Godot 3D 生存战。两名玩家开一间原生 Netcode TCP 房，每人用固定方位正交相机跟随自己的角色。活过前两波并击败第 5 分钟登场的 Boss。全员倒地或 Boss 活到 6:00 时本局失败。倒地者切到幸存队友的视角。

## 启动

需要 Windows x64、Python 3.11 或以上版本以及 Godot 4.6.1。在本目录运行以下命令。

```powershell
python -B launch.py --pair
```

启动脚本默认使用本项目 `addons/netcode` 随附的 Windows x64 原生插件，并导入项目内的资源。士兵模型和 CC0 许可位于 `assets/quaternius`。首次使用编辑器时，可先运行启动脚本并传入 `--prepare-only` 登记插件和导入资源，再打开 `project.godot` 并按 F5。脚本可用 `--godot-exe` 或环境变量 `NETCODE_GODOT_EXE` 指定 Godot，用 `--sdk` 安装指定的 Windows SDK。

随附插件构建标识为 `e05fe3808b391a05/3d0774b7693ff74d`，包含原生 Godot 扩展和 TCP 模块。[对应的 Netcode 源码](https://github.com/bobozai2019/photon_fusion_copy/commit/791c1efaff926337593478765cad2a100316268c)

左边窗口选 B 档、点击 **Host room**。右边使用 **Join room**，同机地址为 `127.0.0.1:43391`。局域网两台机器分别启动一个窗口，客机填写房主的 LAN 地址和房间端口。双方入房并取得角色战斗写权后自动开局。

房主在大厅的 **Play mode** 选择玩法。**Survival** 是普通六分钟生存战。**Stress test** 让双方无敌，开局分批刷怪至 1024 只，击杀后自动补刷，对局持续到玩家离开。1024 是当前压测的最高目标档。界面显示活怪数与目标，A/B/C 仍决定角色和怪物的写权。

- **WASD** 移动，武器自动瞄准并攻击。队色为青色与琥珀色。
- 贴近经验石可拾取。团队升级时选 **1**、**2** 或 **3**，也可点击选项。
- 看到橙色范围时及时离开。**F3** 显示写权数量、RTT、帧间隔 P95、远端怪物更新间隔、单帧位移和停帧比例。

| 模式 | 角色移动 | 普通怪 |
| --- | --- | --- |
| A | 房主推进两人的移动，客机发送输入 | 房主模拟 |
| B | 每位玩家推进自己的移动 | 房主模拟 |
| C | 每位玩家推进自己的移动 | 出生时按批分给两端，失联后房主收回 |

三档均由攻击者确认本地命中目标、玩家确认自己的受击。房主统一保存怪物伤害版本、死亡、掉落、经验和局末结果。Boss、冲锋精英及对局时限均由房主推进。

## 在编辑器中调整场景

| 内容 | 编辑入口 |
| --- | --- |
| 地图、障碍碰撞、边界和出生点 | [地图场景](arena/map.tscn)。成组移动 `Cover` 下的障碍时，移动碰撞和出生避障会读取各组的 `Collision` |
| 士兵、脚圈、护甲材质和简化外观 | [士兵基场景](actors/soldier.tscn)、[Tide](actors/soldier_tide.tscn) 和 [Ember](actors/soldier_ember.tscn) |
| 怪物外观、批次数量、血量、速度、半径和掉落 | [怪物模型](actors/enemy_models.tscn)、[模型批次](actors/batches.tscn) 和 [怪物类型](actors/enemy_types.tscn)。在批次节点的 MultiMesh 资源上调整实例容量 |
| 相机、灯光、菜单、战斗界面和特效模板 | [呈现场景](arena/presentation.tscn)、[界面场景](ui/interface.tscn) 和 [特效场景](effects/mesh_effect.tscn) |

## 复现

```powershell
python -B benchmark/run.py --cases rules --delay 0 64 --label combat
python -B benchmark/run.py --skip-prepare --cases before after --modes C --label handoff
python -B benchmark/run.py --skip-prepare --cases win down timeout natural --label outcomes
python -B benchmark/run.py --skip-prepare --cases capacity --modes A B C --sizes 128 256 512 1024 --scenes split merge burst --windowed --label matrix
```

回放从真实 TCP 入口双进程运行。验证器将 JSON、逐帧 CSV、TCP 流计数和日志写入示例仓的 `out/horde-survivors-3d/<label>/`。`--delay` 配置 relay 附加的总 RTT，实际 RTT 以客机 SDK 采样为准。`--windowed --simple` 保留显示并减少渲染开销。无窗口运行测量逻辑层。`--capture <局内模拟步>` 可与 `--windowed` 一起保存画面。

远端怪物默认按快照间隔插值。复查画面顿感时，可用 `--raw-enemies` 对照直接绘制，或用 `--netcode-smoothing` 测量 SDK 的 `smooth_properties`。原生模式将平滑配置应用到怪物位置和方向，两端使用相同参数。回放加 `--debug` 会自动打开游戏内诊断栏。每次使用独立的输出标签。

分机容量回放使用相同的 Godot、SDK 和项目文件。下面的 IPv4 是示例，运行时填两台机器的实际 LAN 地址。房主先启动，客机随后连接。协调端口为 TCP 43400，游戏 relay 为 TCP 43401。

```powershell
# 房主机器
python -B benchmark/lan.py host --bind 192.168.3.10 --peer 192.168.3.20 --label first-host

# 客机机器
python -B benchmark/lan.py guest --connect 192.168.3.10 --label first-host
```

默认运行 A/B/C、四档密度和三种场景，每格预热 10 秒、采样 30 秒、重复三次。用 `--sizes 128 --delay 40` 可单跑附加延迟组，按客机实测总 RTT 调整 `--delay`。交换主客后用新标签复跑。房主本地归档机器配置、双端逐帧文件、游戏 TCP 流量和对账结果。仅用于协调器复查的同机回放标为 `loopback-smoke`。

把两轮房主输出放到同一处后，用以下命令生成对照表。传入第二个目录时，脚本核对两台 Windows 安装的标识、构建和交换后的角色，并列出两轮覆盖的共同用例与单侧用例数量。容量表保留短测结果。某档至少三轮独立回放均达预算、每轮预热至少 10 秒并采样至少 30 秒时，才列入重复达标档。

```powershell
python -B benchmark/report_lan.py ../out/horde-survivors-3d/lan-first-host-host ../out/horde-survivors-3d/lan-swapped-host
```

- [任务与验收](../task/horde-survivors-3d/执行状态.md)
- [士兵来源与许可](assets/sources.json)
