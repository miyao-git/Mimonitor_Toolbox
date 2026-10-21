# 精密控光 HDR/SDR 记忆守护（显示器端）

让显示器**自己**记住"HDR 时精密控光=高、SDR 时精密控光=关"，不再依赖 Mac/PC 常驻。
Mac 用 SDR、Switch 2 用 HDR 这种组合，显示器一收到 HDR 信号就自己把控光切过去。

## 为什么要在显示器里做

实测（Redmi G Pro 27U 2026 / OS3.0.120.0，本次抓到的固件日志）：

- 固件**自己会**在 HDR 信号到来时切画面模式，HDR10 走 `70 → 22`：
  ```
  [MWIF2-VDP] _VdpHDRTYPEChangedNotify u1HDRTYPE=1 u1HdrGameSignal:0
  [SCC_VID_HDR_EVT e_nfy_cond:0, HDR Type:1, e_vid_hdr_type:1]
  [SCC_VID_HDR_EVT set picture mode:22.cur game mode:0,pc mode:0 freesync:0]
  ```
  → 所以"当前是 HDR 还是 SDR"这个判据，显示器自己就有，不需要主机告诉它。
- 但固件**不会**跟着切精密控光：精密控光在它那儿是**全局值**，不属于按模式存储的那套 PQ 参数。
  实测在模式 22 里把控光写成 2，切回模式 70 后读寄存器仍是 2；同一次切换里背光 `31`、
  色温 `2`、色域 `6`、色调映射 `0` 都按模式各自恢复了 —— 只有控光没恢复。
- MTK 工厂 API 里其实有 `IMtkTvFApiDisplayBase.setLocalDimingHdrType(int)`，
  小米自己也有一条 `SystemControlManager.setLocalDimming()`（写 `picture_local_dimming`）的路径，
  只是固件没把"HDR 类型"接进控光记忆 —— 这也是给官方提需求时最该引用的两处。

官方不修的情况下，只能在显示器内部补一个守护：脚本常驻，盯 `picture_mode`，在 HDR/SDR 之间
来回切时把记忆值写回去。写入通道与桌面端完全一致（`TvService.runSystemCommand` →
`app_process` → `MtkDirectTool.jar` 写 PQ 寄存器）。

## 工作原理

```
每 1s: 读 picture_mode ──► HDR 模式集合内? ──► 桶 = hdr / sdr
        读两个控光 settings 键 ──► 值变了且不是自己写的 ──► 学进当前桶（state 文件）
        桶变了 ──► 读 g_video__vid_local_dimming，与记忆值不同就写回（JNI + settings）
每 30s: 硬件值与 settings 值不一致才修（不会覆盖用户刚改的值）
```

- **记忆**存 `dimming_memory.state`（脚本自己维护），默认值来自 `dimming_memory.conf`
  （默认 `SDR_LEVEL=0`、`HDR_LEVEL=3`，即 SDR 关、HDR 高）。
- **学习**：你在 OSD / 遥控器 / 桌面端把精密控光改成别的值，守护会记进当前那一侧，
  下次切换就用新值。固件会把 OSD 的写入镜像到另一个键（实测延迟约 5s），
  脚本按"同一动作只学一次"去重，避免把镜像学进错误的一侧。
- **判据**：`picture_mode` 落在 `HDR_MODES` 里就算 HDR。实测本机 HDR10 → 22，
  切回 SDR → 70。Dolby Vision 的模式（11/12/13/18/19…）也在默认集合里。

## 使用

```bash
cd tools/dimming_memory
./install.sh deploy            # 推脚本 + 生成配置（默认 192.168.31.15:5555）
./install.sh start             # 启动（adb 方式：shell uid，能同时写 settings 键）
./install.sh status            # 进程 / 当前模式与控光 / 记忆 / 最近日志
./install.sh log
./install.sh stop
```

换显示器 IP：`./install.sh start 192.168.1.50:5555`（或 `ADB_SERIAL=...`）。
adb 不在 PATH 时：`ADB=/path/to/adb ./install.sh start`。

### 两种启动方式

| | `start`（默认，adb 起） | `start --tunnel`（TvService 通道起） |
| --- | --- | --- |
| 进程 uid | `shell`(2000) | `system_app`(1000) |
| 写 MTK 寄存器 | ✅ | ✅ |
| 写 `picture_local_dimming` / `tv_picture_video_local_dimming` | ✅ | ❌（`settings put` 会被 AppOps 拒，实测 NPE） |
| 启动时主机必须在场 | 需要（之后就自由了） | 不需要 |
| 适用 | 日常 | 想完全脱离主机、能接受 OSD 键值滞后 |

`--tunnel` 走的是 `service call TvService 3 s16 "sh -c eval\${IFS}sh\${IFS}/sdcard/.../dimming_memory.sh"`，
和桌面端写寄存器同一条路，起来后主机拔掉也活着。

### 持久性

脚本是显示器里的普通进程：**ADB 断开 / Mac 关机都无影响**，但显示器重启（断电）后会没。
要开机自启，两条路：

1. **已接进桌面端**：工具页的「显示器端分区控光记忆」开关打开后，每次连接显示器都会检测守护是否在跑，
   没跑就自动补拉（脚本打包在 `assets/runtime/dimming_memory.sh`，与 `tools/` 下这份保持同步；
   Windows/Python 与 macOS/Swift 两端都实现了）。这样显示器断电重启后打开 App 就能恢复，
   平时关掉 App / 关机都不影响守护运行。
2. **真正的原生做法**：把这段逻辑搬进 `adb_guardian`（源码在 `/home/hq/mitv/adb_guardian`）：
   - `ContentObserver` 监听 `Settings.Global` 的 `picture_mode`、`picture_preset_scenario`、
     `picture_local_dimming`、`tv_picture_video_local_dimming`（比 1s 轮询更实时、零 CPU）；
   - 判据同本脚本：`picture_mode ∈ HDR 模式集合`；
   - 写入复用它现成的 TvService 事务通道（`mitv.internal.ITvService` +
     `TRANSACTION_RUN_SYSTEM_COMMAND`，跑 `app_process ... MtkDirectTool set ...`）；
   - 记忆放 `SharedPreferences`，配 `BOOT_COMPLETED` + 前台服务，就是永久生效的"显示器原生记忆"。

## 已知限制

- 只处理"HDR 信号切换"这一个维度；切信号源、切模式不触发联动（也不需要）。
- 依赖 `MtkDirectTool.jar`（桌面端连一次就会自动部署到 `/data/data/mitv.service/cache/`）。
- 桌面端 App 里的「HDR/SDR 分区控光记忆」建议**关掉**，否则两边都在写同一个值，
  虽然目前默认值一致不会打架，但语义上重复了。
- `--tunnel` 模式下 OSD 里显示的控光档位可能滞后（硬件是对的）；用默认 adb 方式则同步。

## 实测记录（2026-10-17）

```
00:24:41 首次同步 -> SDR（picture_mode 70）：硬件是 1，写回 0（记忆 SDR=0 HDR=3）
00:24:52 状态切换 -> HDR（picture_mode 22）：硬件是 0，写回 3（记忆 SDR=0 HDR=3）
00:24:55 学习：HDR 记忆更新为 1（来源 tv_picture_video_local_dimming）
00:25:09 状态切换 -> SDR（picture_mode 70）：硬件是 1，写回 0（记忆 SDR=0 HDR=1）
00:25:15 状态切换 -> HDR（picture_mode 22）：硬件是 0，写回 1（记忆 SDR=0 HDR=1）
```

（用 `settings put global picture_mode 22/70` 模拟 HDR/SDR 切换；真实 HDR 信号下
固件的 `SCC_VID_HDR_EVT` 路径会自己做出同样的模式切换。）
