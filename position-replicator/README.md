# Godot C++ 多属性采样示例

对照 Photon Racing 3.0.0 原生 SDK 的实现见 [Racing 属性同步实现](Racing属性同步实现.md)。文中给出二进制地址、C++ 采集与差量代码以及运行命令。以下保留最初的字典采样示例。

这个教学组件在进入场景树时把父节点 `Vehicle` 绑定为根。一个 replicator 可配置多条相对于根的属性路径。本例用 `Dictionary` 保存一轮采样的值，Photon Fusion 的网络对象则会将采集结果编码进 `Words`。

| 场景配置 `property_paths` | 节点 | 读取的属性 | 类型 |
| --- | --- | --- | --- |
| `.:position` | `Vehicle` | `position` | `Vector3` |
| `.:steering` | `Vehicle` | `steering`（脚本导出变量） | `float` |
| `Headlight:visible` | `Vehicle/Headlight` | `visible` | `bool` |

`set_property_paths()` 将每条配置拆成节点路径和属性名。每个物理步，组件从根按路径找到节点，用 `get(property)` 读取当时的值。全部读完后才替换 `sampled_values`。例如添加 `.:rotation`，下次采样就能在字典中按相同键取到旋转。支持同一节点或子节点上的直接属性，默认配置为 `.:position`。[场景配置](demo.tscn) · [绑定与采集代码](position_replicator.cpp)

## 运行

按下方步骤编译扩展后，在本目录用 Godot 4.7.1 运行以下命令。启动脚本直接加载扩展和演示场景。

```powershell
godot --headless --script res://run_demo.gd
```

终端依次输出已写入的现场值、采集前的旧快照和采集后的新快照。演示检查三个字段都从 `(3,0,0)、0.0、false` 更新成 `(4,0,0)、0.75、true`，校验通过后退出。[演示逻辑](demo.gd)

## 重新编译

构建使用 SCons 和 Godot 官方 `godot-cpp` 4.5-stable。安装目标平台的 C++ 编译器和 SCons，设置 `GODOT_CPP_PATH` 指向一份可构建的 `godot-cpp` 源码。在 Windows x64 的 Visual Studio 开发者终端进入本示例目录后执行以下命令，生成的扩展位于 `bin`。

```powershell
scons platform=windows target=template_release arch=x86_64 build_profile=build_profile.json
```
