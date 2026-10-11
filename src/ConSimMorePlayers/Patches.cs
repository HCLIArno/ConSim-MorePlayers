using System;
using System.Collections.Generic;
using System.Reflection;
using HarmonyLib;
using UnityEngine;
using Photon.Pun;
using Photon.Realtime;
using Il2CppInterop.Runtime.InteropTypes.Arrays;
using Wb.Multiplayer;
using Wb.UI;
using Wb.Serialization;

namespace ConSimMorePlayers
{
    internal static class Patches
    {
        private static readonly HashSet<string> Fired = new HashSet<string>();

        /// <summary>每个补丁第一次执行时打一条日志，用来确认补丁是否真的生效。</summary>
        internal static void MarkFired(string name)
        {
            lock (Fired)
            {
                if (Fired.Contains(name)) return;
                Fired.Add(name);
            }
            Plugin.LogAlways("[补丁生效] " + name);
        }

        // ------------------------------------------------------------------
        // 显式注册所有补丁。
        // 不用 harmony.PatchAll(typeof(Patches))：实测在 BepInEx 6 / HarmonyX 下
        // 它没有处理嵌套类里的 [HarmonyPatch]，也没有报错，导致全部补丁静默失效。
        // ------------------------------------------------------------------
        internal static void Initialize(Harmony harmony)
        {
            Register(harmony, "WbUIScreenContentGameTypeSelection.SetupMPCreationCard",
                AccessTools.Method(typeof(WbUIScreenContentGameTypeSelection), "SetupMPCreationCard"),
                null, "Postfix_GameType");

            Register(harmony, "WbUIScreenContentGameTypeSelection.ShowScreenContent",
                AccessTools.Method(typeof(WbUIScreenContentGameTypeSelection), "ShowScreenContent"),
                null, "Postfix_GameType");

            Register(harmony, "WbUIScreenContentGameTypeSelection.OnUserNetworkAvailabilityChecked",
                AccessTools.Method(typeof(WbUIScreenContentGameTypeSelection), "OnUserNetworkAvailabilityChecked"),
                null, "Postfix_GameType");

            Register(harmony, "WbUIScreenContentGameTypeSelection..ctor",
                AccessTools.Method(typeof(WbUIScreenContentGameTypeSelection), ".ctor"),
                null, "Postfix_GameTypeCtor");

            Register(harmony, "WbCompanyPersistenceMetaData.get_HasFinishedStartCampaign",
                AccessTools.Method(typeof(WbCompanyPersistenceMetaData), "get_HasFinishedStartCampaign"),
                null, "Postfix_HasFinished");

            Register(harmony, "WbNetworkManager._CreateRoomCoroutine_d__222.MoveNext",
                AccessTools.Method(typeof(WbNetworkManager._CreateRoomCoroutine_d__222), "MoveNext"),
                "Prefix_CreateRoomMoveNext", null);

            // Photon 层兜底：上面那条协程补丁依赖 _CreateRoomCoroutine_d__222 这个编译器生成的
            // 状态机类名。游戏一更新，类名后缀（d__222）就可能变，补丁会静默失效。
            // 这里直接在真正的出口 PhotonNetwork.CreateRoom 上兜底：只在 MaxPlayers 越界
            // （不在 [2, Target] 内）时才纠正，玩家选好的合法值原样放行。
            // CreateRoom 在 dump.cs 里只有这一个重载
            // （466055；466052 是 JoinRandomOrCreateRoom、466058 是 JoinOrCreateRoom，别 patch 错）。
            Register(harmony, "Photon.Pun.PhotonNetwork.CreateRoom",
                AccessTools.Method(typeof(PhotonNetwork), "CreateRoom"),
                "Prefix_PhotonCreateRoom", null);

            Register(harmony, "WbUIScreenContentMultiplayerGameCreationGeneral.ShowScreenContent",
                AccessTools.Method(typeof(WbUIScreenContentMultiplayerGameCreationGeneral), "ShowScreenContent"),
                null, "Postfix_CreationGeneral");

            Register(harmony, "WbUIScreenContentMultiplayerGameCreationGeneral.PrepareRoom",
                AccessTools.Method(typeof(WbUIScreenContentMultiplayerGameCreationGeneral), "PrepareRoom"),
                "Prefix_CreationGeneral", null);

            Register(harmony, "WbUISettingEntryInteger.Awake",
                AccessTools.Method(typeof(WbUISettingEntryInteger), "Awake"),
                null, "Postfix_SettingAwake");

            // 玩家点箭头前先把上限抬高，否则原版 IncreaseValue 会在 maxValue=4 处夹紧；
            // 注意：这里只动 maxValue，绝不覆写 filterValue，否则玩家点不动数字。
            Register(harmony, "WbUISettingEntryInteger.IncreaseValue",
                AccessTools.Method(typeof(WbUISettingEntryInteger), "IncreaseValue"),
                "Prefix_EnsureMaxRaised", null);

            Register(harmony, "WbUISettingEntryInteger.DecreaseValue",
                AccessTools.Method(typeof(WbUISettingEntryInteger), "DecreaseValue"),
                "Prefix_EnsureMaxRaised", null);

            // 大厅筛选器：maxPlayerFilter 的上限序列化值是 4，
            // 一旦筛选器生效（LESS_OR_EQUAL_TO 语义下 8 <= 4 不成立），
            // 别人的客户端就会把我们的 8 人房间整个过滤掉 → “朋友看不见房间”。
            Register(harmony, "WbUIMultiplayerLobbyFilter.Awake",
                AccessTools.Method(typeof(WbUIMultiplayerLobbyFilter), "Awake"),
                null, "Postfix_LobbyFilter");

            Register(harmony, "WbUIMultiplayerLobbyFilter.OnEnable",
                AccessTools.Method(typeof(WbUIMultiplayerLobbyFilter), "OnEnable"),
                null, "Postfix_LobbyFilter");
        }

        private static void Register(Harmony harmony, string label, MethodBase target,
                                     string prefixName, string postfixName)
        {
            try
            {
                if (target == null)
                {
                    Plugin.LogAlways("[注册失败] " + label + "：找不到目标方法");
                    return;
                }

                MethodInfo prefix = prefixName == null
                    ? null
                    : AccessTools.Method(typeof(Patches), prefixName);
                MethodInfo postfix = postfixName == null
                    ? null
                    : AccessTools.Method(typeof(Patches), postfixName);

                if ((prefixName != null && prefix == null) || (postfixName != null && postfix == null))
                {
                    Plugin.LogAlways("[注册失败] " + label + "：找不到补丁方法 "
                                     + (prefix == null ? prefixName : postfixName));
                    return;
                }

                harmony.Patch(
                    target,
                    prefix == null ? null : new HarmonyMethod(prefix),
                    postfix == null ? null : new HarmonyMethod(postfix));
                Plugin.LogAlways("[注册成功] " + label);
            }
            catch (Exception e)
            {
                Plugin.LogAlways("[注册失败] " + label + "：" + e);
            }
        }

        // ------------------------------------------------------------------
        // 第一部分：解锁联机建房
        //
        // 原版逻辑（WbUIScreenContentGameTypeSelection.SetupMPCreationCard）：
        //     createMultiplayerGameButton.interactable = metaData.hasFinishedStartCampaign;
        // 也就是说，只有「通关开局战役」的存档才能点「创建多人游戏」。
        // ------------------------------------------------------------------

        private static void UnlockMultiplayerButtons(WbUIScreenContentGameTypeSelection screen)
        {
            if (Plugin.UnlockMultiplayer != null && !Plugin.UnlockMultiplayer.Value) return;
            try
            {
                if (screen == null) return;

                if (screen.createMultiplayerGameButton != null)
                {
                    screen.createMultiplayerGameButton.SetInteractable(true);
                }
                if (screen.joinMultiplayerGameButton != null)
                {
                    screen.joinMultiplayerGameButton.SetInteractable(true);
                }
                if (screen.notification != null && screen.notification.activeSelf)
                {
                    screen.notification.SetActive(false);
                }
                if (screen.lockIcon != null && screen.lockIcon.enabled)
                {
                    screen.lockIcon.enabled = false;
                }

                MarkFired("UnlockMultiplayerButtons(执行)");
                if (Plugin.Verbose)
                {
                    string createState = screen.createMultiplayerGameButton == null
                        ? "null"
                        : screen.createMultiplayerGameButton.IsInteractable().ToString();
                    string lockState = screen.lockIcon == null ? "null" : screen.lockIcon.enabled.ToString();
                    string noteState = screen.notification == null ? "null" : screen.notification.activeSelf.ToString();
                    Plugin.LogAlways("解锁状态: create=" + createState + " lockIcon=" + lockState + " notification=" + noteState);
                }
            }
            catch (Exception e)
            {
                Plugin.LogAlways("解锁联机按钮失败: " + e);
            }
        }

        private static void Postfix_GameType(WbUIScreenContentGameTypeSelection __instance)
        {
            MarkFired("GameTypeSelection.方法被调用");
            UnlockMultiplayerButtons(__instance);
        }

        private static void Postfix_GameTypeCtor(WbUIScreenContentGameTypeSelection __instance)
        {
            MarkFired("GameTypeSelection..ctor");
            UnlockMultiplayerButtons(__instance);
        }

        private static void Postfix_HasFinished(ref bool __result)
        {
            if (Plugin.UnlockMultiplayer != null && Plugin.UnlockMultiplayer.Value)
            {
                MarkFired("WbCompanyPersistenceMetaData.get_HasFinishedStartCampaign");
                __result = true;
            }
        }

        // ------------------------------------------------------------------
        // 第二部分：尊重玩家的房间人数选择
        //
        // 这里两个 hook 都只做「防御性夹紧」，绝不把玩家选好的值往 Target 抬：
        // 玩家在 [2, Plugin.Target] 区间内的选择一律原样放行（选 7 就是 7）。
        // 只有超界（<下限 或 >Target）才纠正，用来兜住「退回原版 4」之类的异常。
        // ------------------------------------------------------------------

        // 上一次打过日志的房间容量，避免协程每次 resume 都重复刷同一条日志。
        // 只用来抑制信息行，不影响越界纠正日志与 MarkFired。
        private static int _lastMoveNextCapacity = int.MinValue;
        private static int _lastPhotonCapacity = int.MinValue;

        private static void Prefix_CreateRoomMoveNext(WbNetworkManager._CreateRoomCoroutine_d__222 __instance)
        {
            try
            {
                MarkFired("WbNetworkManager._CreateRoomCoroutine_d__222.MoveNext");
                WbLobbyController.WbRoomData roomData = __instance.roomData;
                if (roomData == null) return;

                // 玩家选的值原样放行，只在越界时才动它。
                int selected = roomData.maxPlayers;
                int lo = 2;
                int hi = Plugin.Target;
                if (hi < lo) hi = lo;      // Target 被配成 <2 时避免合法区间倒挂

                int adopted = selected;
                if (selected < lo) adopted = lo;
                else if (selected > hi) adopted = hi;

                if (adopted != selected)
                {
                    Plugin.LogAlways("房间人数上限越界 " + selected + " -> " + adopted
                                     + "（合法区间 " + lo + ".." + hi + "）");
                    roomData.maxPlayers = adopted;
                }

                if (_lastMoveNextCapacity != adopted)
                {
                    _lastMoveNextCapacity = adopted;
                    Plugin.LogAlways("房间人数上限 = " + adopted);
                }
            }
            catch (Exception e)
            {
                Plugin.LogAlways("MoveNext 修正失败: " + e);
            }
        }

        // ------------------------------------------------------------------
        // 第二部分之二：Photon 层兜底（房间人数上限）
        //
        // 调用链：
        //   WbRoomData.maxPlayers
        //     -> WbNetworkManager._CreateRoomCoroutine_d__222.MoveNext 循环生成
        //        RPPlayerInfo00/01/... 属性槽位
        //     -> RoomOptions.MaxPlayers
        //     -> PhotonNetwork.CreateRoom(roomName, roomOptions, typedLobby, expectedUsers)
        //
        // 上面的 MoveNext 前缀改写的是链路中段，且目标类名是编译器生成的
        // （_CreateRoomCoroutine_d__222），游戏更新后可能改名 → 补丁静默失效。
        // 这里在链路末端、真正决定房间容量的地方再兜一次。
        //
        // 兜底 = 只夹紧超界值，不抬升玩家的合法选择：
        //   玩家选 7，而 RoomOptions.MaxPlayers 已经是 7 → 原样放行（房间就是 7 人）。
        //   只有 MaxPlayers 超出 [2, Plugin.Target]（例如退回原版 4 或被人改成 0/255）才纠正。
        // 之前写成「< Target 就抬到 Target」是错的，那会把玩家选的 7 顶成 8。
        //
        // 注意：PhotonNetwork.CreateRoom 是 static，没有 __instance；
        // roomOptions 是引用类型，直接改它的字段即可写回调用方。
        // expectedUsers 在 IL2CPP interop 里不是 string[] 而是 Il2CppStringArray
        // （ilspycmd 确认：CreateRoom(string, RoomOptions, TypedLobby, Il2CppStringArray)）。
        // 参数类型必须逐字对齐，否则 Harmony 匹配不上、补丁静默不生效。
        // ------------------------------------------------------------------
        private static void Prefix_PhotonCreateRoom(string roomName, RoomOptions roomOptions,
                                                    TypedLobby typedLobby, Il2CppStringArray expectedUsers)
        {
            try
            {
                if (roomOptions == null) return;

                // RoomOptions.MaxPlayers 是 byte（dump.cs:391681 // 0x12）。
                // 先取到 int 再比较，避免 byte 与 int 比较/赋值时的溢出与截断问题。
                int selected = roomOptions.MaxPlayers;
                int lo = 2;
                int hi = Plugin.Target;
                if (hi < lo) hi = lo;      // Target 被配成 <2 时避免合法区间倒挂

                int adopted = selected;
                if (selected < lo) adopted = lo;
                else if (selected > hi) adopted = hi;

                if (adopted != selected)
                {
                    // hi 上限受 Plugin.HardCap(32) 约束，必然落在 byte 范围内，转换安全。
                    roomOptions.MaxPlayers = (byte)adopted;
                    Plugin.LogAlways("PhotonNetwork.CreateRoom 房间容量越界 " + selected + " -> " + adopted
                                     + "（房间名=" + roomName + "，合法区间 " + lo + ".." + hi + "）");
                }

                if (_lastPhotonCapacity != adopted)
                {
                    _lastPhotonCapacity = adopted;
                    Plugin.LogAlways("[补丁生效] PhotonNetwork.CreateRoom 房间容量 = " + adopted
                                     + "（房间名=" + roomName + "）");
                }

                MarkFired("PhotonNetwork.CreateRoom 容量兜底");
            }
            catch (Exception e)
            {
                Plugin.LogAlways("PhotonNetwork.CreateRoom 容量修正失败: " + e);
            }
        }

        /// <summary>
        /// 只在界面刚打开时调用：把上限抬到 Target，并让默认值从原版的 4 变成 Target。
        /// 之后玩家用箭头自由调整（2..Target），插件不再干预。
        /// </summary>
        internal static void BoostSetting(WbUIScreenContentMultiplayerGameCreationGeneral screen)
        {
            try
            {
                if (screen == null) return;
                WbUISettingEntryInteger setting = screen.maxPlayerSetting;
                if (setting == null) return;

                // 缓存真实引用，供 Prefix_EnsureMaxRaised 精确认人
                _maxPlayerSetting = setting;

                MarkFired("BoostSetting(执行)");

                int vanilla = setting.maxValue;   // 原版是 4
                bool changed = false;

                if (setting.maxValue < Plugin.Target)
                {
                    Plugin.LogAlways("界面最大玩家数上限 " + setting.maxValue + " -> " + Plugin.Target);
                    setting.maxValue = Plugin.Target;
                    changed = true;
                }

                // 只有还停在原版默认值时才改默认值，避免覆盖玩家打开界面后的选择
                if (setting.filterValue == vanilla && setting.filterValue != Plugin.Target)
                {
                    Plugin.LogAlways("界面当前玩家数 " + setting.filterValue + " -> " + Plugin.Target);
                    setting.filterValue = Plugin.Target;
                    changed = true;
                }
                else if (setting.filterValue > setting.maxValue)
                {
                    setting.filterValue = setting.maxValue;
                    changed = true;
                }

                if (changed) RefreshSettingUI(setting);
            }
            catch (Exception e)
            {
                Plugin.LogAlways("界面修正失败: " + e);
            }
        }

        /// <summary>点「创建游戏」前只补上限，不动玩家选好的人数。</summary>
        internal static void EnsureMaxRaised(WbUIScreenContentMultiplayerGameCreationGeneral screen)
        {
            try
            {
                if (screen == null) return;
                WbUISettingEntryInteger setting = screen.maxPlayerSetting;
                if (setting == null) return;

                if (setting.maxValue < Plugin.Target)
                {
                    Plugin.LogAlways("建房前抬高上限 " + setting.maxValue + " -> " + Plugin.Target);
                    setting.maxValue = Plugin.Target;
                    RefreshSettingUI(setting);
                }
                Plugin.LogAlways("建房人数 = " + setting.filterValue);
            }
            catch (Exception e)
            {
                Plugin.LogAlways("建房前修正失败: " + e);
            }
        }

        /// <summary>
        /// WbUISettingEntryInteger 只改 filterValue / maxValue 字段不会刷新界面：
        /// 原版是在 DecreaseValue / IncreaseValue 里手动更新文本和箭头按钮。
        /// 这里照抄那条路径，否则界面仍显示旧数字、箭头仍是灰的。
        /// </summary>
        internal static void RefreshSettingUI(WbUISettingEntryInteger setting)
        {
            try
            {
                if (setting.settingValue != null)
                {
                    setting.settingValue.text = setting.filterValue.ToString("00");
                }
                if (setting.increaseButton != null)
                {
                    setting.increaseButton.SetInteractable(setting.filterValue < setting.maxValue);
                }
                if (setting.decreaseButton != null)
                {
                    setting.decreaseButton.SetInteractable(setting.filterValue > setting.minValue);
                }
                Plugin.LogAlways("界面已刷新: 显示=" + setting.filterValue.ToString("00")
                    + " max=" + setting.maxValue + " min=" + setting.minValue);
            }
            catch (Exception e)
            {
                Plugin.LogAlways("刷新界面失败: " + e);
            }
        }

        /// <summary>
        /// 当前「最大玩家数」设置项的实例引用。
        /// 不再用 minValue == 2 这种猜数值的方式认人：WbUISettingEntryInteger 是通用控件，
        /// 一旦改版换了默认 min，判定就会失效（而且可能误伤别的设置项）。
        /// 改成在 ShowScreenContent 时缓存 screen.maxPlayerSetting 这个真实引用。
        /// </summary>
        private static WbUISettingEntryInteger _maxPlayerSetting;

        /// <summary>玩家点箭头前先把上限抬高，否则原版 IncreaseValue 会在 maxValue=4 处夹紧。
        /// 只动 maxValue，绝不覆写 filterValue —— 覆写会让玩家怎么点都弹回原值。</summary>
        private static void Prefix_EnsureMaxRaised(WbUISettingEntryInteger __instance)
        {
            try
            {
                if (__instance == null) return;

                // 优先用缓存下来的真实引用；缓存尚未建立时，退回到旧的数值判据兜底。
                if (_maxPlayerSetting != null)
                {
                    if (!ReferenceEquals(__instance, _maxPlayerSetting)) return;
                }
                else if (__instance.minValue != 2 || __instance.maxValue < 2 || __instance.maxValue > 64)
                {
                    return;
                }

                if (__instance.maxValue >= Plugin.Target) return;

                Plugin.LogAlways("抬高上限 " + __instance.maxValue + " -> " + Plugin.Target);
                __instance.maxValue = Plugin.Target;
            }
            catch (Exception) { }
        }

        private static void Postfix_CreationGeneral(WbUIScreenContentMultiplayerGameCreationGeneral __instance)
        {
            MarkFired("GameCreationGeneral.ShowScreenContent");
            BoostSetting(__instance);
        }

        /// <summary>点「创建游戏」时只把上限补上，绝不改写玩家已经选好的人数。</summary>
        private static void Prefix_CreationGeneral(WbUIScreenContentMultiplayerGameCreationGeneral __instance)
        {
            MarkFired("GameCreationGeneral.PrepareRoom");
            EnsureMaxRaised(__instance);
        }

        // ------------------------------------------------------------------
        // 第三部分：放大「多人游戏大厅筛选器」的最大玩家数上限
        //
        // 原版 WbUIFilterIntEntry 的 maxPlayerFilter 序列化值是
        //   setting = LESS_OR_EQUAL_TO(4), filterValue = 4, maxValue = 4, minValue = 1
        // PassFilter(value) 对 LESS_OR_EQUAL_TO 判定 value <= filterValue，
        // 于是 8 人的房间被 8 <= 4 判为不合格 → 别人的大厅列表里直接看不到我们。
        // 这里把上限和当前值一起抬到 Target。
        // ------------------------------------------------------------------
        internal static void BoostLobbyFilter(WbUIMultiplayerLobbyFilter filter)
        {
            try
            {
                if (filter == null) return;

                WbUIFilterIntEntry entry = filter.maxPlayerFilter;
                if (entry == null) return;

                MarkFired("BoostLobbyFilter(执行)");

                bool changed = false;
                if (entry.maxValue < Plugin.Target)
                {
                    Plugin.LogAlways("大厅筛选器最大玩家数上限 " + entry.maxValue + " -> " + Plugin.Target);
                    entry.maxValue = Plugin.Target;
                    changed = true;
                }
                if (entry.filterValue < Plugin.Target)
                {
                    Plugin.LogAlways("大厅筛选器当前玩家数 " + entry.filterValue + " -> " + Plugin.Target);
                    entry.filterValue = Plugin.Target;
                    changed = true;
                }

                if (changed)
                {
                    if (entry.settingValue != null)
                    {
                        entry.settingValue.text = entry.filterValue.ToString("00");
                    }
                    // 绝对不要 Invoke() 这个事件！
                    // 它在 WbUIMultiplayerLobbyFilter.Awake() 里被绑到 AnyValueChanged()，
                    // 而 AnyValueChanged() 的第一件事是：
                    //     if (this.isFilterActive == False) this.Activate();
                    // 而 Awake() 的结尾本来是 this.Deactivate()。
                    // 我们是 Postfix，跑在 Deactivate() 之后，一旦 Invoke 就等于把
                    // 本来关闭的筛选器强行打开，连带启用等级 / ping / 跨平台等条件，
                    // 反而会把原本可见的房间过滤掉。
                    // 列表刷新由大厅自己的 _UpdateRoomList 协程负责，无需我们触发。
                    Plugin.LogAlways("大厅筛选器已刷新: 显示=" + entry.filterValue.ToString("00")
                        + " max=" + entry.maxValue + " min=" + entry.minValue
                        + " setting=" + entry.setting
                        + " isFilterActive=" + filter.isFilterActive);
                }
            }
            catch (Exception e)
            {
                Plugin.LogAlways("大厅筛选器修正失败: " + e);
            }
        }

        private static void Postfix_LobbyFilter(WbUIMultiplayerLobbyFilter __instance)
        {
            BoostLobbyFilter(__instance);
        }

        private static void Postfix_SettingAwake(WbUISettingEntryInteger __instance)
        {
            try
            {
                if (__instance == null) return;
                MarkFired("WbUISettingEntryInteger.Awake");
                if (Plugin.Verbose)
                {
                    Plugin.LogAlways("设置项 max=" + __instance.maxValue + " min=" + __instance.minValue
                                     + " 值=" + __instance.filterValue);
                }
            }
            catch (Exception)
            {
            }
        }
    }
}
