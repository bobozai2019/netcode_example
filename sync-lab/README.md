# Godot 双客户端同步试验场

把 Godot 4.6.1 Windows x64 的两个 exe 放入 `runtime/godot-4.6.1/`，然后双击 [launch.bat](launch.bat) 打开左右两个玩家窗口。工程已附 Netcode 插件和 TCP 模块。默认选择 128 对象，由 A 开 Netcode 房，B 经 TCP 加入。运行 Fusion 模式前需安装原版 Photon SDK，两端按项目设置的 Cloud 或 Local 模式加入同一个 Shared Authority 房间。

界面和按钮连线保存在 [主场景](lab.tscn)。开房或加入时实例化所选的 [Netcode 会话场景](netcode_session.tscn) 或 [Fusion 会话场景](fusion_session.tscn)，退出时释放该会话。两个 Spawner 的生成位置和三个模板都在场景里配置，小球由 Spawner 按房间人数和所选对象数生成。

Netcode 的三个模板使用 [同一字段配置](netcode_orb_config.tres) 和 `orb.gd`。在 Godot 选中模板的 Sync，即可在 **Netcode 同步属性** 面板修改字段。两个后端各自在本端订阅用户键，由房间属性告诉客端应选择的组。

`-DemoCheck -Trace` 下，A 等待 B 核对全部字段，再依次切换全量、键 1、键 2 和全量。B 核对对象编号，128 档依次可见 128、76、76、128，512 档依次可见 512、268、268、512。从示例仓库根目录可用 `python -B tools/verify_sync_lab.py 128 --sdk sync-lab/addons/netcode` 运行同一用例的双进程断言版。`--sdk` 也接受 SDK ZIP。安装 Fusion 后可追加 `--backend Fusion --cloud` 运行对照。

| 启动方式 | 操作 |
| --- | --- |
| Netcode 双开 | `.\launch.bat` |
| Fusion 双开，读取当前项目设置 | `.\launch.bat -Backend Fusion` |
| Fusion Local 独立 exe 双开 | `.\launch_fusion_local.bat -Objects 128` |
| 双开后手动选择后端 | `.\launch.bat -Manual` |
| 用项目自带的 4.6.1 打开编辑器 | `.\launch.bat -Editor` |
| 指定对象数和 TCP 端口 | `.\launch.bat -Objects 128 -Port 43232` |

在窗口顶部选择 **Netcode** 或 **Fusion**。Netcode 输入房主的地址和端口，Fusion 输入两端一致的房间名。手动开房时先让 A 开房，再让 B 加入，两端选择相同对象数。切换后端前让两个窗口退出当前房间。

Fusion Preview 555 从项目设置 **Fusion → Connection** 读取 App ID、模式、区域和 App Version。当前项目模式为 Local，地址为 `127.0.0.1:5055`。双开脚本默认生成独立的 Photon 房间名，也可通过 `-Room` 指定。需要安装插件时，在本目录运行 `python -B prepare_fusion.py`，或用 `NETCODE_FUSION_ADDON` 指定原版 SDK 的 `addons/fusion`。Netcode 的已安装插件会复用，也可用 `NETCODE_BENCH_SDK` 指定 Windows SDK ZIP。可用 `NETCODE_GODOT_EXE` 为双开脚本指定其他引擎路径。

运行 Fusion 前，在本目录新建由 Git 忽略的 `override.cfg`，填入自己的 App ID。[Godot 项目设置](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html)

```ini
[fusion]
connection/app_id="YOUR_PHOTON_APP_ID"
```

Fusion 在确认仿真时钟启动后分批生成对象，客端收齐初始对象后开始持续写入。Photon 在入房前返回 `1040` 时自动重试一次，结果显示在窗口顶部。打开 4.6.1 编辑器前，先关闭正在使用同一项目的其他 Godot 编辑器。

独立 Local 版位于 `../out/packages/sync-lab-fusion-local-win-x64/current/`。`SyncLabFusionLocal.exe` 已内嵌场景和 Local 设置，运行时从同目录加载 DLL。Local 版需要 `127.0.0.1:5055` 上运行带 Fusion 3 插件的 Photon Server。对比 Netcode 时可用 `.\launch.bat -Backend Netcode -Objects 128` 跑同一档。独立 Release 版的 `-Trace` 记录 A、B 的应用日志，编辑器运行版还会采集 Fusion 调试器字节率。

## 共同负载

在任一玩家窗口按 **WASD** 或方向键移动自己的圆环。两种后端使用同一份场景、八个属性和 32／64／128／512／1024 对象档。玩家各自每秒写入 10 次。开局约 5 秒后，房主按每个小球 10 Hz 分帧轮转写入。512 档一圈约 0.1 秒，目标总写入速率约 5,100 次/秒。客端实际接收频率见 `-Trace` 日志。浮点及向量输入统一使用 0.01 步长。房主可以暂停负载，或在全部、AOI 1 和 AOI 2 间切换客人可见范围。32、64、512 档的客端切到单组时，分别显示 28、44、268 个对象，包含全局对象。

顶部显示当前后端的可见副本数、FPS、固定步率、RTT 和状态年龄 P95。Netcode 还显示 TCP 队列字节。跨机器比较状态年龄需要两端对齐系统时钟。Netcode 默认走本机 TCP。Fusion 工程默认使用 Local，显式选择 Cloud 才经由 Photon Cloud。比较同步处理成本时应同时记录后端、引擎版本、对象数及链路设置。

日常双开默认用 128 档。此前限速配置的 Windows 双端验证覆盖八字段、AOI 切换及持续更新。Fusion Cloud 的 512 档在高负载下曾发生批量更新滞后。加上 `-DemoCheck -CaptureDir <目录>` 可记录双端画面、校验日志和更新年龄。

在示例仓库根目录运行以下命令，可用真实窗口验证 Netcode 的 512 档。输出包含全量负载期间双端的帧率、P95 帧间隔、绘制调用数，以及八字段和 AOI 断言结果。

三个 Netcode 小球模板共用的 `netcode_orb_config.tres` 已启用 `apply_proxy_changes_only`。客端按已接收的网络状态回写变化字段。`--require-proxy-changes` 会检查实际绑定的模板采用了该路径。把资源选项改为 `false` 后，用省略该参数的命令对照逐步采样和本地纠偏模式。

```powershell
python -B tools/verify_sync_lab.py 512 --sdk sync-lab/addons/netcode --seconds 42 --windowed --require-proxy-changes
```

## 同步日志

用 `launch.bat -Backend Fusion -Objects 512 -Trace` 双开并记录。启动终端会显示日志目录，也可通过 `-CaptureDir` 指定。

- `host.log` 和 `guest.log` 的 `SYNC_LAB_TRACE` 行约每秒记录一次。`fps` 和 `frame_p95_ms` 取自同一采样窗内相邻处理帧的墙钟间隔，`draw_calls` 为采样时的 Godot 绘制调用监视值。`load_writes` 是本端批量写入次数，`remote_groups.*.advanced` 是这一间隔内版本推进的已有对象数，`new_instances` 单独记录新出现的实例。
- Netcode 的 `proxy_changes_only` 来自当前实际绑定的小球模板。`true` 表示已启用，`false` 表示关闭。`null` 表示模板尚未绑定或 SDK 缺少模式查询。
- `host-fusion.jsonl` 和 `guest-fusion.jsonl` 记录 Fusion 调试器报告的对象发送、接收字节率，按所有者汇总，并按对象编号保留若干样本。两类日志的 `unix_ms` 可用于同机对时。Fusion 的队列深度未在这份调试输出中提供，因此应用日志里的 `queued_bytes` 为 `null`。
