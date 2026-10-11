# ConSim More Players

**《建筑模拟器》(Construction Simulator) 多人房间人数上限解锁 —— 4 人 → 最高 32 人（默认 8）**

[![Game](https://img.shields.io/badge/game-Construction%20Simulator%201273400-blue)](https://store.steampowered.com/app/1273400/)
[![Engine](https://img.shields.io/badge/engine-Unity%202020.3.49f1%20IL2CPP-lightgrey)]()
[![Loader](https://img.shields.io/badge/BepInEx-6.0.0--be.788-orange)]()
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

游戏官方把联机人数**写死在 4 人**（官方 FAQ 原文：*"Cooperative online multiplayer mode for up to 4 players"*），
且**没有任何公开的设置项或 MOD 接口**能改。本插件通过在运行时挂接游戏自己的代码路径，把上限抬到可配置的 8 人（可调 1–32）。

**功能已在实机验证**：房主建房容量 8 人，朋友在多人游戏大厅能正常看到房间并加入。
本仓库里的 `installer/` 是给普通玩家用的一键安装包，`src/` 是插件源码。

> ⚠️ **所有要一起联机的人都要装**。没装的一方仍走游戏原版逻辑，在大厅里看不到 8 人房，看到了也进不去。

---

## 给玩家：怎么装

1. **完全退出游戏**（Steam 里点「停止」，不要只关窗口）
2. 从 [Releases](https://github.com/HCLIArno/ConSim-MorePlayers/releases) 下载最新的一键安装包，解压到任意位置
3. 双击 **`一键安装.bat`**
4. 装完从 Steam 正常启动游戏

安装脚本会自动定位游戏目录（按 Steam AppID `1273400` 遍历所有库，支持游戏装在非系统盘），
**安装前会完整备份**到游戏目录下的 `_ConSimMorePlayers_备份\`，**永不删除任何原文件**。
想恢复原版，双击 `一键卸载.bat` 即可。

### 首次启动会「准备」比较久，然后报一次错 —— 这是正常的

首次启动时 BepInEx 需要：

1. 准备 Unity 基础库（**本安装包已预置，无需联网下载**，见 `NOTICE.md`）
2. 用 Cpp2IL 把游戏代码反编译一遍，生成 170 个辅助程序集到 `<游戏目录>\BepInEx\interop\`（约 100 MB，约 10 秒到几分钟）

做完后日志里会冒出红色报错：

```
[Fatal] Unable to execute IL2CPP chainloader, no plugins will be loaded
[Error] System.InvalidOperationException: Sequence contains more than one element
        at Il2CppInterop...GenericMethod_GetMethod_Hook.FindTargetMethod()
```

**这不算失败，插件没坏。** 上面两步是在「本次这个进程」里现做的，BepInEx 紧接着在同一进程初始化会撞上
[Il2CppInterop issue #183](https://github.com/BepInEx/Il2CppInterop/issues/183)（官方标记 *Not planned*）。
**把游戏完全关掉、重新启动一次即可**，此时 interop 已生成，不再走那条路径。

> 顺带一提：那个黑色日志窗口**只点「最小化」，千万不要点右上角的 ✕** —— 那会连着游戏一起关掉。

### 怎么确认装好了

打开 `<游戏目录>\BepInEx\LogOutput.log`，能看到这些行就对了：

```
ConSim More Players 已加载，目标房间人数 = 8，解锁联机建房 = False
[注册成功] WbUISettingEntryInteger.IncreaseValue
[注册成功] Photon.Pun.PhotonNetwork.CreateRoom
...
[补丁生效] BoostSetting(执行)
界面最大玩家数上限 4 -> 8
```

### 常见问题

**Q：`说明.txt` 里提到杀软件/Defender 报毒？**
A：`winhttp.dll` 是 doorstop（BepInEx 的注入入口）的文件名，几乎所有 Unity 插件加载器都用它，
被启发式规则误报很常见。加白名单即可，或者自行从 [BepInEx 官方构建站](https://builds.bepinex.dev/projects/bepinex_be) 下载比对。

**Q：Steam 提示「文件完整性验证」/ 更新后插件失效？**
A：不要用 Steam 的「验证游戏文件完整性」，它会把 `winhttp.dll` 等文件删掉。
游戏更新后 IL2CPP 偏移会变，需要重新生成 interop，插件也可能需要更新。

**Q：能超过 8 人吗？**
A：改 `BepInEx\config\com.dsh.consim.moreplayers.cfg` 里的 `MaxPlayers`（上限 32）。
但**建议先测 5–6 人**，游戏本身没在这个规模下测试过，人数越多同步问题越明显。

---

## 给开发者

### 目录结构

```
.
├── src\ConSimMorePlayers\
│   ├── Plugin.cs                 BepInEx 入口、Config、日志出口
│   ├── Patches.cs                全部 Harmony 补丁 + 显式注册表
│   └── ConSimMorePlayers.csproj  引用来自游戏目录的 interop 程序集
├── installer\
│   ├── 一键安装.bat / 一键卸载.bat
│   ├── scripts\install.ps1       安装/卸载/预演（含 -DryRun）
│   ├── payload\                  分发载荷（含第三方组件，见 NOTICE.md）
│   └── 说明.txt                   面向玩家的说明
└── docs\
    ├── 开发者说明.md              详细开发笔记、13 个补丁清单、日志断言方法
    └── 外部审查回应.md            对一份第三方独立审查的逐条核对结果
```

**详细的开发笔记（工程结构、构建、每个补丁干什么、踩过的坑）在 [`docs/开发者说明.md`](docs/开发者说明.md)。**

### 构建

需要 .NET SDK 8+（插件目标框架是 `net6.0`）。先让游戏**至少用 BepInEx 启动过一次**，
这样 `<游戏目录>\BepInEx\interop\` 里的代理程序集才会存在 —— 它们无法随源码分发。

```powershell
dotnet build src\ConSimMorePlayers\ConSimMorePlayers.csproj -c Release `
  -p:GameDir="D:\Steam\steamapps\common\Construction Simulator"
```

也可以用环境变量 `CONSIM_DIR`，或在仓库根放一个 `Directory.Build.props`
（已在 `.gitignore` 里）。**不指定游戏目录会直接报错**，不会产出一个跑不起来的 DLL。

产物：`src\ConSimMorePlayers\bin\Release\ConSimMorePlayers.dll`。
把它覆盖到 `<游戏目录>\BepInEx\plugins\ConSimMorePlayers.dll` 即可。

### 人数上限的三个层次

改人数不是改一个数就够了。Photon 房间容量这条链路上有三个地方，**任意一层做「强制覆写」都会让玩家的选择失效**：

| # | 位置 | 作用 |
|---|---|---|
| 1 | `WbUISettingEntryInteger.filterValue` | 建房界面「最大玩家数」的**当前值**（`maxValue` 只管上限） |
| 2 | `WbNetworkManager._CreateRoomCoroutine_d__222.MoveNext` 里的 `roomData.maxPlayers` | 决定生成几个 `RPPlayerInfo%02d` 玩家属性槽 |
| 3 | `Photon.Pun.PhotonNetwork.CreateRoom` 的 `roomOptions.MaxPlayers` | 最终写到 Photon 服务器的容量 |

**正确做法是只夹紧越界值**（合法区间 `[2, 目标值]` 内原样放行），而不是「不等于目标值就改写」。
本项目第一版就踩了这个坑：玩家选 7，被强行改写成 8，界面上箭头怎么点都没反应。

### 两个会「静默失效」的坑

**① 参数类型必须是 interop 类型。**
`dump.cs` 里字面显示的 `string[]`，在 interop 程序集里的真实类型是
`Il2CppInterop.Runtime.InteropTypes.Arrays.Il2CppStringArray`。
写成 `string[]` **能编译通过，但 Harmony 匹配不上，补丁静默失效且不报任何错**。

**② 不要用 `PatchAll`。**
实测在 BepInEx 6 / HarmonyX 下，`harmony.PatchAll(typeof(Patches))` 不会处理嵌套类里的 `[HarmonyPatch]`，
**同样不报错**。本工程一律用显式的 `Register(...)` 逐个注册，并且每条都会往日志里打
`[注册成功]` 或 `[注册失败]`。

### 断言补丁生效

**唯一可信的依据是 `<游戏目录>\BepInEx\LogOutput.log`，不要凭界面推断。**
界面看起来对，不能证明补丁挂上了；界面看起来不对，也不能证明补丁没挂上。

---

## 已知边界与免责

- 只保证在 **Construction Simulator `1.0.0.4349.173243` / Unity 2020.3.49f1 (IL2CPP)** 上验证过。
  游戏更新后 IL2CPP 偏移会变，补丁可能失效，需要重新生成 interop 并检查目标方法。
- 游戏本身没有在 4 人以上测试过。**人数越多，同步问题越明显**，建议先从小规模试起。
- 本插件**只改房间容量**，不改存档、不解锁被锁内容、不做任何内存注入式作弊。
  安装/卸载都是纯文件操作且有完整备份。
- 本项目与 weltenbauer. Software Entwicklung、astragon Entertainment 无任何关联。
  《Construction Simulator》及相关商标归其各自所有者所有。
- 请自行评估在联机游戏中使用 MOD 的风险。

---

## English

A BepInEx 6 (IL2CPP) plugin that raises **Construction Simulator**'s hard-coded 4-player
co-op limit to a configurable value (default 8, max 32). Verified in-game: a host can create
an 8-slot room and other players can see and join it from the multiplayer lobby.

**Everyone who joins must install it** — an unmodded client still filters out rooms with more
than 4 players and will not see the host's room.

Download the one-click installer from [Releases](https://github.com/HCLIArno/ConSim-MorePlayers/releases), extract, and run `一键安装.bat`
(the script is Chinese-only). It auto-detects the game directory via Steam AppID `1273400`,
backs up everything before writing, and never deletes original files.

On first launch, BepInEx downloads/builds its IL2CPP interop assemblies and **then throws
`Sequence contains more than one element`** — this is a known
[Il2CppInterop issue #183](https://github.com/BepInEx/Il2CppInterop/issues/183) and is expected.
**Just restart the game once.** (The Unity base libraries are pre-bundled here, so no download
is needed for those.)

Build from source with `dotnet build src\ConSimMorePlayers\ConSimMorePlayers.csproj -c Release -p:GameDir="<game dir>"`.
See [`docs/开发者说明.md`](docs/开发者说明.md) for the full developer notes (Chinese).

## License

MIT for our own code (see [LICENSE](LICENSE)).
Bundled third-party components are listed in [NOTICE.md](NOTICE.md).
No game code or assets are included in this repository.
