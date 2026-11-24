# Racing 3.0.0 的属性怎样从 Godot 进入 Fusion

当 A 的车移动时，Godot 节点持有当前位置。Fusion 的运行时缓存负责再次找到这个节点和属性。出站采集取得一个临时值，并把编码结果写入网络对象的状态缓冲区。这三者有各自的生命周期。

## 本地 SDK 可读到的实现

以下地址来自 Racing 自带的 `addons/fusion/bin/libfusion.linux.editor.x86_64.release.so`，使用 ELF 虚拟地址。SHA-256 为 `3BCBEC5F76344BB98F82F4F65448AFDF65206400B4268E28A1D4B95D38EBF61B`。函数用途依据调用、Godot 方法绑定名称及签名、传参和内存读写判定。表中的中文名称描述其行为。

| 环节 | 本地二进制证据 |
| --- | --- |
| 刚体自动属性 | `0x19a390` 构建自动路径。前两个路径由 `0x1a50e0` 和 `0x1a5110` 按坐标模式选择，本地为 `:position`、`:rotation`，全局为 `:global_position`、`:global_rotation`。刚体分支继续加入 `:linear_velocity` 和 `:angular_velocity`。赛车场景另外配置了三个脚本浮点属性。 |
| 找到目标节点 | 建缓存的路径中，`0x19ca57` 调用 Godot 的 `get_node_or_null`，`0x19ca9d` 保存节点指针，`0x19caaa` 调用 `get_instance_id`，`0x19cab2` 保存 ID。 |
| 槽的内存布局 | 在这份 64 位库里，相邻缓存项的跨度为 `0xa0`，即 160 字节。槽内 `+0x00` 为目标节点指针，`+0x08` 为实例 ID，`+0x10` 为传给 Godot 的属性名。普通字段路径从 `+0x20` 取类型、从 `+0x24` 取 word 偏移、从 `+0x28` 取 word 数。可在 `0x19dcc9` 看到工作寄存器已前移 16 字节，阅读后续指令时应计入这个偏移。160 字节是该构建的绑定记录跨度，与属性的网络状态大小分别计算。 |
| 复用缓存 | `0x19dc68–0x19dc95` 遍历槽，按实例 ID 取得对象，与缓存指针比较。缓存可用时跳过重建，失效时进入 `0x19c610` 重建。 |
| 槽里也有路径 | 配置资源按行保存 `NodePath`。创建运行时槽时，扩展在槽的 `+0x10` 构造属性名，在 `+0x18` 复制该条绑定的 `NodePath`。两条填槽路径分别见 `0x19cb89/0x19cb98` 和 `0x19d0ab/0x19d0bc`。两处路径复制都进入 `0x275e70`，调用以 Godot 类型 22（NodePath）、构造器 1（复制构造）注册的函数。普通属性采集直接使用节点与属性名。以截图的 `underside:rotation` 为例，绑定有效时，一个槽同时记录目标节点、属性名 `rotation` 和这条路径。 |
| 读取并编码 | 在普通字段分支，`0x19dd60–0x19dd6a` 把目标节点和属性名传给 `Object::get`。该包装在 `0x434ad5` 引用方法名 `get`，在 `0x434afc` 使用 Godot 方法签名哈希 `2760726917`。`0x19dd7f–0x19dd97` 以 `word_base + 4 × word_offset` 计算目的地址，调用编码函数。FLOAT 分支 `0x19a318` 写一个 word，VECTOR3 分支 `0x19a230` 按 x、y、z 写三个相邻 word。 |
| 何时发生 | 对象遍历在 `0x12b538–0x12b56d` 做条件判断，符合条件的实例经 `0x1a6cd0 → 0x19db30` 进入采集。这条路径能证明循环发生在 SDK 一侧。由此还不能给出任意一辆车在某个物理步的 getter 次数。 |

例如只改变 A 的 `position.x`，Godot 的 getter 仍返回完整的 Vector3。采集写入三个分量后，发送端在 word 层比较当前值和 `Shadow`。如果只有 x 的编码发生变化，先前变化也均已确认，本次只需传 x 所在 word 的变化。其他两个分量继续保存在对象状态里。[Photon Core 的发送扫描](https://doc.photonengine.com/fusion-core/v3/manual/objects#shadow-buffer)

## C++ 对照实现

[racing_replicator.cpp](racing_replicator.cpp) 接收真正的 Godot 刚体。按以下顺序阅读即可跟踪一个值。

1. `configure` 加入四个自动属性，再追加赛场配置中的三条自定义路径。`build_slots` 按照路径找到目标，保存节点指针、实例 ID、属性名、类型、偏移和长度。
2. `capture` 校验目标，调用 `slot.target->get(slot.property)`，按槽偏移写入 `words`。脚本可以在两次采集之间多次赋值。演示显式调用采集，以便观察赋值前后的两个存储位置。
3. `scan` 在发送 tick 比较 `words` 和 `shadow`，保留每个 word 最后发生变化的 tick，并重新发送尚未确认的变化。首次扫描生成完整的演示快照。
4. `receive` 合并收到的 word，把有变化的属性写到 B 的车辆。`acknowledge` 接收演示链路的确认。真实 Racing 的根刚体在远端还使用 Forecast 平滑。

本实现只保存这七个属性的 15 个业务 word。数组中的偏移、首包格式、进程内传递的整数对以及直接写回远端刚体，都是为了观察数据流所作的选择。原生 Windows 扩展在同型刚体上测得 AUTO 加 0、1、2、3 个自定义属性的 `compute_word_count` 返回 15、16、17、18。该接口给出布局大小，线上包长度还取决于实际变化。

本实现统一使用两位小数定点编码。Linux 库在 `0x1888fa–0x188958` 读取项目的 `float_compression`，设置值 0 映射到精度表下标 2。`0x1e43c0` 的默认精度分支用该下标取得乘数 100，乘积按符号舍入到整数。实际 SDK 还有字段专用分支，如旋转在满足条件时可用不同精度。演示以 `position.x = 4.0` 和 `net_input_x = 0.75` 为例，观察到两个整数 400 和 75。

## 运行和复查

在示例仓库根目录运行以下命令。第一条运行[附带的 Windows x64 C++ 扩展](README.md#运行)，模拟 A 写入、丢包、B 接收和 ACK。第二条加载官方 Racing Starter Kit 随附的 Photon 扩展，逐项调用其布局 API。把 `$racing` 改为本地 Racing 项目目录。两条都可离线运行。[Racing Starter Kit](https://doc.photonengine.com/fusion-godot/v3-shared-authority/game-samples/racing-starter-kit)

```powershell
$godot = 'godot'
$racing = 'C:/path/to/photon-fusion-godot-starter-kit-racing_3.0.0'
$demo = (Resolve-Path './position-replicator').Path
& $godot --headless --path $demo --script res://run_racing.gd
& $godot --headless --path $racing --script "$demo/run_racing.gd" -- --sdk
```

用以下命令可在本机对照表中的“读取并编码”一行。其他地址可用同一工具改变起止范围查看。

```powershell
$so = "$racing/addons/fusion/bin/libfusion.linux.editor.x86_64.release.so"
Get-FileHash -Algorithm SHA256 -LiteralPath $so
& 'D:/godot/emsdk/upstream/bin/llvm-objdump.exe' -d --no-show-raw-insn --start-address=0x19dd59 --stop-address=0x19dd9c $so
```
