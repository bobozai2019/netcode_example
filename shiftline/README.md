# Shiftline

Shiftline 是一个 Windows x64 局域网团队 FPS。Tide 和 Ember 在同一座双层装卸仓库交战，每队至多四人。先到 30 分获胜，结算后在原房开启下一局。

## 开一局

1. 解压 Windows 包，双击 `Shiftline.exe`。输入昵称，选择同网段的主机 IPv4，使用默认端口 `42520` 或指定一个端口，点 **Host**。房主独自即可进图。
2. 客人在同一局域网上输入房主顶栏显示的 IPv4 和端口，点 **Join**。本机双开时，在 Host 的网卡选择中用 `127.0.0.1`，Join 也填 `127.0.0.1`。
3. 如系统询问 Windows 防火墙权限，房主选择允许专用网络上的访问。所有玩家保留解压后 `Shiftline.exe` 和随包 DLL 的相对位置。房主退出时，客人回到大厅。

| 按键 | 操作 |
| --- | --- |
| WASD、鼠标 | 移动、转向。对准梯子按前进或后退可上下 |
| Shift、Space | 蹲伏、跳跃 |
| 鼠标左键、R | 开火、换弹 |
| G、E | 投掷手榴弹、领取附近补给 |
| Tab、F1、Esc | 切换人员表、切换整套界面、打开或关闭房间菜单 |

青色底座是弹药，绿色底座是手榴弹。木箱可以打碎，蓝色集装箱是固定掩体。玩家阵亡后 3 秒复活；同队不受伤害。

## 源码工程

Windows x64 可用 Godot 4.7.1 打开 `shiftline/project.godot`，使用随工程提交的 Netcode 插件按 F5 运行。要从 [SDK 锁文件](../sdk-lock.json) 指定的 Godot ZIP 刷新插件，可在仓库根运行以下命令。脚本校验 ZIP 后安装并导入工程，可用 `--godot-exe` 或 `NETCODE_GODOT_EXE` 指定 Godot。

```powershell
python -B tools/prepare_godot_fps.py
```

可从仓库根复跑以下入口。打包需要对应版本的 Windows x64 导出模板。

```powershell
python -B tools/verify_godot_fps.py
python -B tools/verify_godot_fps.py --suite gameplay --visible
python -B tools/package_godot_fps.py
```

验收脚本用独立 Godot 进程按大厅控件和输入事件驱动正式入口。指定位置与 29 分边界由验收探针设置，击败、结算、补给和复活走房主的正式规则。探针仅复制到隔离验收工程。Windows 包写入 `out/packages/godot-fps-win-x64/current/`，旁边有 SHA-256 清单。

## 场景位置

| 目录 | 在 Godot 中编辑 |
| --- | --- |
| `app/`、`net/` | `main.tscn` 是 F5 入口。`match.tscn` 组合仓库、玩家槽和对局同步节点。 |
| `arena/` | `warehouse.tscn` 摆放地图区块、出生点、木箱和补给。`structure/` 和 `props/` 存放可复用的子场景。 |
| `actors/`、`effects/` | 第三人称人物、第一人称手臂和相机、飞行手榴弹，以及枪口火光、曳光和爆炸。 |
| `ui/` | `lobby/` 存放大厅和仓库示意图，`hud/` 存放对局界面和人员表行。 |

角色、道具和第一人称手臂分别来自 Quaternius 的 Toon Shooter Game Kit 和 wwwriks 的 WRAD ARMS，使用 CC0 1.0。源码的 `assets/sources.json` 及包内的 `asset-sources.json` 保存原始链接和哈希。许可随包提供。

`actors/viewmodel/sleeves.mesh` 是从 WRAD ARMS 手臂网格保存的 Godot 资源，顶点颜色记录袖口与皮肤的过渡。对应蒙皮和材质在 `viewmodel.tscn`。
