# Windows x64 联机车场

通用玩法接入可从控制台示例开始。完成相应引擎和物理依赖构建后，从仓库根目录执行 `python -B tools/verify_gameplay_components.py --engine cocos`，启动两个本引擎进程验证字段、RPC 和写权交接。[玩法代码](../../puzzle/components_cocos.hpp) · [构建与预期结果](../../../netcode/task/gameplay-components/验收/本机.md#复现)


解压后双击 `netcode-yard.exe` 进入联机页。房主可选随机空闲端口，也可手填，再点击 **Host**。客人输入房间里显示的房主 IPv4 和端口并点击 **Join**。同机测试可以用 `127.0.0.1`。

等待页显示房间信息、玩家名单和聊天。房主可以点 **Start game** 或 **Kick**。被踢的客人可用同一端点重新加入。

也可以在两个 PowerShell 窗口运行以下命令，直接进入房间等待页。两端使用同一个端口。

```powershell
.\netcode-yard.exe --host --port 43210
```

```powershell
.\netcode-yard.exe --join 127.0.0.1 --port 43210
```

房主等待人数显示 `2/4 seats`，在 Host 窗口按 F2。绿色标记本机玩家拥有的车。默认由房主结算，自车在本地固定步立即响应。房主按 F5 至 F7 切换相应玩家对自己车辆的写权，按 F8 将房主的车依次交给已就绪的客人，再收回。借车期间方向键驱动借来的车，业务归属仍属于房主。点击需要操作的窗口，使用方向键或 WASD 驾驶。靠近闸门按 E 请求开门。按 B 在本车前放置路障，按 X 移除自己的路障，按 H 鸣笛。

Cocos2d-x 房主可以使用同一个 `netcode-yard.exe` 无窗口运行。房主与第一位客人都进入等待阶段后，房主沿用房间规则自动开局。客人沿用上面的 `--join` 命令。

```powershell
.\netcode-yard.exe --headless --host --port 43210
```

从仓库根目录运行 `python -B tools/verify_yard.py play --platform cocos2dx --host-headless --capture`，可验证无头房主与可见客人完成驾驶、开门、重连和退出。

客人在局中按 F4 断开。房主可继续驾驶和修改路障。客人在原窗口按 R，基线应用完成后继续操控原车。房主按 F3 回到同一房间的等待阶段，按 F2 再开一局，按 Q 结束房间。

在 Cocos2d-x、Godot 和 Unity 车场，房主可在局中按 F5、F6、F7，依本轮客人席位切换对应客人车辆的状态写权。客人获权后本地模拟车辆，房主与其他客人显示已接纳的位置。再次按同一键收回写权。客人断线期间由房主接管，仍启用委托的席位在重连并应用基线后取得新代次。命令行房主可传 `--client-authority 2` 为玩家 2 启用委托。

同机负载模式给两个车场命令都追加 `--scenario stress --seconds 10`，再启动两个轻量客人。四个进程使用相同的端口和时长。三位客人就绪后自动驾驶，房主冻结最终世界后各端输出摘要并退出。给各命令追加 `--fault` 可按固定规则注入 UDP 丢失、重复和乱序。

```powershell
.\netcode-guest.exe --join 127.0.0.1 --port 43210 --scenario stress --seconds 10
```

联机界面创建的房间监听所有本机 IPv4 接口。命令行默认监听回环地址，局域网配置时房主传入 `--bind` 和本机 IPv4，客人使用对应地址。

在两端追加 `--typed-profile` 可启用可复制玩家资料。玩家开门后，分数从 16777217 增至 16777219，名称变为“通关”，物品列表缩短，权重列表清空。三个引擎的验证器读取实际绑定值。房主、客人保持默认驾驶模式时验收自车预测与远车插值，加 `--authority` 验收客户端直接写入。见[可复现的联机验收](../../tools/verify_yard.py)。
