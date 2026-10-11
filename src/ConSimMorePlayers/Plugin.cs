using System;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Logging;
using BepInEx.Unity.IL2CPP;
using HarmonyLib;
using Wb.Multiplayer;
using Wb.UI;

namespace ConSimMorePlayers
{
    [BepInPlugin(Guid, "ConSim More Players", "1.0.0")]
    public class Plugin : BasePlugin
    {
        public const string Guid = "com.dsh.consim.moreplayers";

        internal static ManualLogSource LogSource;

        internal static ConfigEntry<int> MaxPlayersEntry;
        internal static ConfigEntry<bool> VerboseLogEntry;
        internal static ConfigEntry<bool> UnlockMultiplayer;

        /// <summary>Photon RoomOptions.MaxPlayers is a byte; the game's own slot array is built from this value.</summary>
        internal const int HardCap = 32;

        internal static int Target
        {
            get
            {
                int v = MaxPlayersEntry != null ? MaxPlayersEntry.Value : 8;
                if (v < 1) v = 1;
                if (v > HardCap) v = HardCap;
                return v;
            }
        }

        internal static bool Verbose
        {
            get { return VerboseLogEntry == null || VerboseLogEntry.Value; }
        }

        /// <summary>必须走 BepInEx 的 ManualLogSource，Console.WriteLine 在 redirect_output_log=false 时不进日志。</summary>
        internal static void LogInfo(string msg)
        {
            if (!Verbose) return;
            LogAlways(msg);
        }

        /// <summary>绕过 Verbose 开关，用于补丁是否生效这类关键诊断。</summary>
        internal static void LogAlways(string msg)
        {
            if (LogSource != null) LogSource.LogInfo(msg);
        }

        public override void Load()
        {
            LogSource = Log;

            MaxPlayersEntry = Config.Bind(
                "General",
                "MaxPlayers",
                8,
                "房间最大玩家数 (vanilla = 4)。范围 1-" + HardCap + "。所有联机成员都需要安装本插件。");

            VerboseLogEntry = Config.Bind(
                "General",
                "VerboseLog",
                true,
                "输出详细日志，排查问题时可开启。");

            UnlockMultiplayer = Config.Bind(
                "General",
                "UnlockMultiplayer",
                false,
                "绕过「必须先通关开局战役」的限制，让「创建多人游戏」按钮直接可用。"
                + "默认 false（保持游戏原版行为，挂锁与提示都保留）。");

            var harmony = new Harmony(Guid);

            LogAlways("ConSim More Players 已加载，目标房间人数 = " + Target
                + "，解锁联机建房 = " + UnlockMultiplayer.Value);

            try
            {
                Patches.Initialize(harmony);
            }
            catch (Exception e)
            {
                LogAlways("补丁注册失败: " + e);
            }
        }
    }
}
