# 第三方组件声明

本仓库的插件源码（`src/`）与安装脚本（`installer/scripts/`）为本项目原创。
`installer/payload/` 下是**第三方组件**，版权归各自作者，此处仅为「让使用者一次下载即可用」而原样收录。

## BepInEx 6（IL2CPP, win-x64）

- 文件：`installer/payload/BepInEx6-win-x64.zip`
- 版本：`6.0.0-be.788`（构建号 `5b766a3b7f6c164d4798924a93f3acf4db769d06`）
- 来源：<https://builds.bepinex.dev/projects/bepinex_be>
- 许可：LGPL-2.1
- 用途：Unity IL2CPP 游戏的插件加载器，本插件的运行宿主。

> 该压缩包为官方原始文件，未做任何修改。若需要自行核验，可从上述来源重新下载比对。

## Unity 基础库

- 文件：`installer/payload/unity-libs/2020.3.49.zip`
- 来源：<https://unity.bepinex.dev/libraries/2020.3.49.zip>
- 说明：这是 BepInEx 首次启动时会自动下载的 Unity 基础程序集（对应 Unity 2020.3.49）。
  预先放进安装包只是为了**让网速慢的机器不必卡在下载那一步**，内容与官方完全一致。
- SHA256：`D9EEE0DB5802E491112402692CBFC70E0CA5BB6A107682D5292259575CD8D6EA`

BepInEx 的行为是：`unity-libs` 目录下若已存在与目标 URL 同名的 `.zip`，就直接使用本地文件、完全不发起网络请求。
（依据其配置项 `UnityBaseLibrariesSource` 的官方说明，以及 `Il2CppInteropManager.DownloadUnityAssemblies()` 中的
`if (!File.Exists(text2))` 判断。）

## 未收录的内容

以下内容**没有**放进本仓库，因为它们要么体积过大，要么属于游戏厂商的专有代码：

- `BepInEx/interop/`：由 BepInEx 在**每台机器首次启动游戏时本地生成**的 IL2CPP 代理程序集（约 100 MB）。
- 反编译产物（`dump.cs`、Cpp2IL 伪代码等）：由本仓库的使用者自行从游戏文件生成。

因此本仓库**不包含任何《建筑模拟器》的游戏代码或资源**。
