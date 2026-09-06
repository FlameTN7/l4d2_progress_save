#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <l4d2_nativevote>
#include <multicolors>

#define PLUGIN_VERSION "1.0.0"
#define PLUGIN_NAME    "L4D2 Progress Save Load"
#define PLUGIN_AUTHOR  "l4d2 server"

#define MAX_SURVIVORS  8
#define SLOT_PRIMARY   0
#define SLOT_SECONDARY 1
#define SLOT_THROWABLE 2
#define SLOT_MEDKIT    3
#define SLOT_PILLS     4

// 存档数据目录: data/progress_save/<map>/save.txt
int g_iOldGiveType; // 备份 bots_give_type 供恢复临时禁用后还原
char g_sSaveRoot[] = "data/progress_save";
char g_sSaveFile[] = "save.txt";

ConVar g_cvEnable;
ConVar g_cvSaveInSafeAreaOnly;
ConVar g_cvAutoRestart;
ConVar g_cvRestoreDelay;
ConVar g_cvVoteTime;
ConVar g_cvAlignBotsLimit;
ConVar g_cvDebug;

bool g_bVoteActive = false;
bool g_bSaveActive = false; // 本图已读档激活,持续自动套用家底(含团灭重开)
char g_sPendingLoad[PLATFORM_MAX_PATH]; // 等待恢复的存档文件路径

// ============ 存档数据结构 ============
enum struct SurvivorSave
{
	char steamid[32];
	bool isHuman;
	int  character;        // 角色索引
	int  health;           // m_iHealth
	int  maxhealth;
	float temphealth;      // L4D_GetTempHealth
	int  incappedCount;    // m_currentReviveCount

	char primary[64];
	int  primaryClip;
	int  primaryReserve;
	char secondary[64];
	int  secondaryClip;
	int  secondaryReserve;
	char secondaryKind[32]; // 若是近战,存的近战kind名(e.g. machete)
	char throwable[64];
	int  throwableClip;
	char medkit[64];
	char pills[64];
}

int g_iSavedSurvivorCount;
SurvivorSave g_asaved[MAX_SURVIVORS];
char g_sSavedMap[64];
int g_iSavedBotsLimit;
char g_sSavedDifficulty[16];
char g_sSavedMode[32];
int giveNums[MAX_SURVIVORS]; // 弹药重套次数

// ============ Plugin ============
public Plugin myinfo =
{
	name = PLUGIN_NAME,
	author = PLUGIN_AUTHOR,
	description = "进度存读档:在某章map开局保存队伍家底,投票读档后EndScenario重启并恢复",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_cvEnable =           CreateConVar("l4d_progress_enable", "1", "存读档总开关", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvSaveInSafeAreaOnly= CreateConVar("l4d_progress_save_in_safearea_only", "1", "仅允许在出生安全区保存", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvAutoRestart =      CreateConVar("l4d_progress_auto_restart", "1", "读档后自动EndScenario重启本图", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvRestoreDelay =     CreateConVar("l4d_progress_restore_delay", "1.5", "round_start_post_nav后延迟套家底秒数(等bots铺队)", FCVAR_NOTIFY, true, 0.0, true, 10.0);
	g_cvVoteTime =         CreateConVar("l4d_progress_vote_time", "20", "读档投票时长(秒)", FCVAR_NOTIFY, true, 5.0, true, 60.0);
	g_cvAlignBotsLimit =   CreateConVar("l4d_progress_align_botslimit", "1", "读档时把bots_limit对齐到存档人数", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebug =            CreateConVar("l4d_progress_debug", "0", "调试日志", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	RegConsoleCmd("sm_progress", Command_Progress, "打开存读档菜单");
	RegConsoleCmd("sm_save", Command_Save, "保存当前进度");
	RegConsoleCmd("sm_load", Command_Load, "读档并重启");
	RegConsoleCmd("sm_progress_off", Command_Deactivate, "取消本图存档生效");

	HookEvent("round_start_post_nav", Event_RoundStartPostNav, EventHookMode_PostNoCopy);
	AutoExecConfig(true, "l4d_progress_save");
}

public void OnMapStart()
{
	g_bVoteActive = false;
}

public void OnMapEnd()
{
	g_bSaveActive = false;
}

// ============ 命令 ============
public Action Command_Progress(int client, int args)
{
	if (!IsValidClient(client))
		return Plugin_Handled;

	Menu menu = new Menu(Menu_ProgressHandler);
	menu.SetTitle("进度存读档");
	menu.AddItem("save", "保存当前进度");
	menu.AddItem("load", "读档并重启");
	menu.AddItem("deactivate", "取消本图存档生效");
	menu.AddItem("info", "查看当前存档信息");
	menu.ExitButton = true;
	menu.Display(client, 15);
	return Plugin_Handled;
}

public int Menu_ProgressHandler(Menu menu, MenuAction action, int client, int itemNum)
{
	if (action == MenuAction_Select)
	{
		char item[16];
		menu.GetItem(itemNum, item, sizeof(item));
		if (strcmp(item, "save") == 0)
			Command_Save(client, 0);
		else if (strcmp(item, "load") == 0)
			Command_Load(client, 0);
		else if (strcmp(item, "deactivate") == 0)
			Command_Deactivate(client, 0);
		else if (strcmp(item, "info") == 0)
			ShowSaveInfo(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

// 取消本图存档激活(团灭重开不再自动套家底)
public Action Command_Deactivate(int client, int args)
{
	if (g_bSaveActive)
	{
		g_bSaveActive = false;
		CPrintToChat(client, "{green}[进度]{default}已取消本图存档生效,后续重开不再自动套用家底.");
	}
	else
	{
		CPrintToChat(client, "{green}[进度]{default}当前本图没有启用的存档.");
	}
	return Plugin_Handled;
}

public Action Command_Save(int client, int args)
{
	if (!g_cvEnable.BoolValue)
		return Plugin_Handled;
	if (!IsValidClient(client))
		return Plugin_Handled;

	if (GetClientTeam(client) != 2)
	{
		CPrintToChat(client, "{green}[进度]{default}仅生还者可保存进度.");
		return Plugin_Handled;
	}

	// 仅安全区限制
	if (g_cvSaveInSafeAreaOnly.BoolValue)
	{
		float pos[3];
		GetClientAbsOrigin(client, pos);
		if (!L4D_IsPositionInFirstCheckpoint(pos))
		{
			CPrintToChat(client, "{green}[进度]{default}只能在出生安全区内保存进度(用于map开头的存档节点).");
			return Plugin_Handled;
		}
	}

	CPrintToChat(client, "{green}[进度]{default}正在保存进度...");
	SaveProgress();
	return Plugin_Handled;
}

public Action Command_Load(int client, int args)
{
	if (!g_cvEnable.BoolValue)
		return Plugin_Handled;
	if (!IsValidClient(client))
		return Plugin_Handled;
	if (g_bVoteActive)
	{
		CPrintToChat(client, "{green}[进度]{default}读档流程进行中,请稍候.");
		return Plugin_Handled;
	}

	// 读取存档,校验是否存在及同图
	char path[PLATFORM_MAX_PATH];
	char map[64];
	GetCurrentMap(map, sizeof(map));
	if (!BuildSaveFilePath(map, path, sizeof(path)))
	{
		CPrintToChat(client, "{green}[进度]{olive}当前地图 {olive}%s{default} 还没有存档.", map);
		return Plugin_Handled;
	}

	if (!FileExists(path))
	{
		CPrintToChat(client, "{green}[进度]{olive}当前地图 {olive}%s{default} 还没有存档.", map);
		return Plugin_Handled;
	}

	strcopy(g_sPendingLoad, sizeof(g_sPendingLoad), path);

	// 读档其余信息用于投票展示(不写入内存家底)
	char displayMap[64];
	ReadSaveMeta(path, displayMap, sizeof(displayMap));

	// 发起投票
	if (!L4D2NativeVote_IsAllowNewVote())
	{
		CPrintToChat(client, "{green}[进度]{default}当前已有投票进行中.");
		return Plugin_Handled;
	}

	L4D2NativeVote vote = L4D2NativeVote(Vote_LoadHandler);
	vote.SetDisplayText("读取存档 \"%s\" 并重启本图?", displayMap);
	vote.SetTitle("进度存读档");

	int[] clients = new int[MaxClients];
	int total = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			clients[total++] = i;
	}

	g_bVoteActive = true;
	vote.DisplayVote(clients, total, g_cvVoteTime.IntValue);
	return Plugin_Handled;
}

// ============ 投票回调 ============
public void Vote_LoadHandler(L4D2NativeVote vote, VoteAction action, int param1, int param2)
{
	switch (action)
	{
		case VoteAction_Start:
		{
			// 无操作
		}
		case VoteAction_End:
		{
			g_bVoteActive = false;
			if (vote.YesCount > vote.PlayerCount / 2)
			{
				vote.SetPass("正在读档...");
				// 读档在下一帧执行,避免在投票回调里做耗时操作
				RequestFrame(NextFrame_DoLoad);
			}
			else
			{
				vote.SetFail();
			}
		}
	}
}

public void NextFrame_DoLoad()
{
	DoLoad();
}

// ============ 执行读档 ============
void DoLoad()
{
	if (!g_cvEnable.BoolValue)
		return;

	char map[64];
	GetCurrentMap(map, sizeof(map));

	// 读取存档到内存
	if (!ReadSaveData(g_sPendingLoad))
	{
		CPrintToChatAll("{green}[进度]{olive}读档失败:存档文件损坏或不匹配.");
		g_sPendingLoad[0] = '\0';
		return;
	}

	// 校验同图
	if (strcmp(g_sSavedMap, map) != 0)
	{
		CPrintToChatAll("{green}[进度]{olive}存档属于 {olive}%s{default},当前地图是 {olive}%s{default},地图不匹配拒绝读档.", g_sSavedMap, map);
		g_sPendingLoad[0] = '\0';
		return;
	}

	// 读档成功且同图 => 本图激活存档,后续所有 round(含团灭重开)自动套用家底
	g_bSaveActive = true;

	// 对齐人数:把bots_limit设为存档时的人数
	int curLimit = GetBotsLimitCvar();
	if (g_cvAlignBotsLimit.BoolValue && g_iSavedBotsLimit > 0 && curLimit != g_iSavedBotsLimit)
	{
		SetBotsLimitCvar(g_iSavedBotsLimit);
		CPrintToChatAll("{green}[进度]{default}已将生还者数量对齐到存档人数 {olive}%d{default}.", g_iSavedBotsLimit);
	}

	if (!g_cvAutoRestart.BoolValue)
	{
		// 不自动重启:等待下一次 round 自动套用
		CPrintToChatAll("{green}[进度]{default}读档已激活,本图重开后自动恢复家底.");
		return;
	}

	// 自动重启:调用已有 sm_restart (l4d_restart_without_changelevel, EndScenario, coop用MissionLost)
	CPrintToChatAll("{green}[进度]{yellow}读档通过,正在重启本图并恢复家底...");
	ServerCommand("sm_restart");
}

// ============ round 恢复 ============
public void Event_RoundStartPostNav(Event event, const char[] name, bool dontBroadcast)
{
	// 本图激活的存档持续套用(读档后的首次重启 + 之后团灭重开都自动生效)
	if (!g_bSaveActive)
		return;
	if (!g_cvEnable.BoolValue)
		return;

	// 校验当前图与存档同图
	char map[64];
	GetCurrentMap(map, sizeof(map));
	if (strcmp(g_sSavedMap, map) != 0)
		return; // 换图了,让 OnMapEnd 清理

	float delay = g_cvRestoreDelay.FloatValue;
	CreateTimer(delay, Timer_RestoreSurvivors);
}

public Action Timer_RestoreSurvivors(Handle timer)
{
	RestoreSurvivors();
	return Plugin_Stop;
}

void RestoreSurvivors()
{
	if (!g_cvEnable.BoolValue)
		return;

	// 临时禁用 bots.sp 的 GiveDefaultItems 干预,避免其覆盖存档装备
	ConVar cGiveType = FindConVar("bots_give_type");
	if (cGiveType != null)
	{
		g_iOldGiveType = cGiveType.IntValue;
		if (g_iOldGiveType != 0)
			cGiveType.SetInt(0);
	}
	// 3.5s 后恢复 bots.sp 给装备逻辑(此时存档装备已完全套好)
	CreateTimer(3.5, Timer_RestoreBotsGive);

	// 1) 真人按 SteamID 精确匹配存档槽位
	bool humansMatched[MAXPLAYERS + 1];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != 2)
			continue;
		char steam[32];
		if (!GetClientAuthId(i, AuthId_Steam2, steam, sizeof(steam)))
			continue;
		for (int s = 0; s < g_iSavedSurvivorCount; s++)
		{
			if (!g_asaved[s].isHuman)
				continue;
			if (strcmp(g_asaved[s].steamid, steam) == 0)
			{
				ApplySaveToClient(i, s);
				humansMatched[i] = true;
				break;
			}
		}
	}

	// 2) 未匹配的玩家按槽位铺剩余家底(跳过已由真人占用的真人槽)
	int slotCounter = 0;
	for (int i = 1; i <= MaxClients && slotCounter < MAX_SURVIVORS; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 2)
			continue;
		if (humansMatched[i])
			continue; // 已由SteamID配过
		while (slotCounter < g_iSavedSurvivorCount && SlotTakenByHuman(slotCounter))
			slotCounter++; // 该槽是真人槽且已被匹配走
		if (slotCounter >= g_iSavedSurvivorCount)
			break;
		ApplySaveToClient(i, slotCounter);
		slotCounter++;
	}

	CPrintToChatAll("{green}[进度]{olive}读档完成,{olive}%d{default}人队伍从 {olive}%s{default} 安全区继续.", g_iSavedBotsLimit, g_sSavedMap);
	g_sPendingLoad[0] = '\0';
}

// 恢复 bots.sp 的给装备逻辑(存档装备已完全套好后)
public Action Timer_RestoreBotsGive(Handle timer)
{
	if (g_iOldGiveType != 0)
	{
		ConVar cGiveType = FindConVar("bots_give_type");
		if (cGiveType != null)
			cGiveType.SetInt(g_iOldGiveType);
		g_iOldGiveType = 0;
	}
	return Plugin_Stop;
}

// 该槽位是否已由 "存档中的真人" 分配给人
bool SlotTakenByHuman(int slot)
{
	if (slot < 0 || slot >= g_iSavedSurvivorCount)
		return false;
	return g_asaved[slot].isHuman;
}

void ApplySaveToClient(int client, int slot)
{
	if (!IsClientInGame(client))
		return;
	if (slot < 0 || slot >= g_iSavedSurvivorCount)
		return;

	SurvivorSave save;
	save = g_asaved[slot];

	// 血量
	SetEntProp(client, Prop_Send, "m_iHealth", save.health);
	SetEntProp(client, Prop_Send, "m_iMaxHealth", save.maxhealth > 0 ? save.maxhealth : 100);
	L4D_SetTempHealth(client, save.temphealth);
	SetEntProp(client, Prop_Send, "m_currentReviveCount", save.incappedCount);

	// 装备:移除全部再重建,下一帧设置弹药(等待GivePlayerItem生成)
	L4D_RemoveAllWeapons(client);

	DataPack pack;
	CreateDataTimer(0.2, Timer_GiveWeapons, pack, TIMER_FLAG_NO_MAPCHANGE);
	pack.WriteCell(client);
	pack.WriteCell(slot);
}

int g_slotClient[MAX_SURVIVORS]; // 读档后 slot -> client 映射

public Action Timer_GiveWeapons(Handle timer, DataPack pack)
{
	pack.Reset();
	int client = pack.ReadCell();
	int slot = pack.ReadCell();

	if (!IsClientInGame(client) || GetClientTeam(client) != 2)
		return Plugin_Stop;

	SurvivorSave save;
	save = g_asaved[slot];
	g_slotClient[slot] = client;

	GiveSurveyorWeapons(client, save);

	// bots.sp 的 GiveDefaultItems detour 可能在稍后重置装备,分阶段多次重设弹药兜底
	giveNums[slot] = 0;
	RequestFrame(NextFrame_ReapplyAmmo, slot);
	CreateTimer(0.4, Timer_ReapplyAmmo, slot);
	CreateTimer(1.0, Timer_ReapplyAmmo, slot);
	CreateTimer(2.5, Timer_ReapplyAmmo, slot);

	if (g_cvDebug.BoolValue)
		PrintToServer("[progress-save] slot=%d client=%d 主:%s clip=%d reserve=%d 副:%s clip=%d reserve=%d kind=%s 投掷:%s clip=%d",
			slot, client, save.primary, save.primaryClip, save.primaryReserve,
			save.secondary, save.secondaryClip, save.secondaryReserve, save.secondaryKind,
			save.throwable, save.throwableClip);

	return Plugin_Stop;
}

// 一次性给目标玩家存档中的全部装备(主/副/投掷/医疗/药)
void GiveSurveyorWeapons(int client, const SurvivorSave save)
{
	// 主武器
	if (save.primary[0])
		GivePlayerItem(client, save.primary);

	// 副武器(近战/枪)
	if (save.secondary[0])
	{
		if (StrEqual(save.secondary, "weapon_melee", false))
		{
			// 近战:直接给 kind 名重建(如 machete/baseball_bat),与 survivor_chat_select 做法一致
			if (save.secondaryKind[0])
				GivePlayerItem(client, save.secondaryKind);
			else
				GivePlayerItem(client, "weapon_melee"); // 兜底
		}
		else if (StrEqual(save.secondary, "weapon_pistol", false) && save.secondaryClip == 0 && save.secondaryReserve == 0)
		{
			// 双持小手枪(副武器空弹夹常表示双持)
			GivePlayerItem(client, "weapon_pistol");
			GivePlayerItem(client, "weapon_pistol");
		}
		else
		{
			GivePlayerItem(client, save.secondary);
		}
	}
	// 投掷物
	if (save.throwable[0])
		GivePlayerItem(client, save.throwable);
	// 医疗包
	if (save.medkit[0])
		GivePlayerItem(client, save.medkit);
	// 药
	if (save.pills[0])
		GivePlayerItem(client, save.pills);
}

// 重新应用主副武器弹药(弹夹+备弹),跨帧/定时多次兜底
public void NextFrame_ReapplyAmmo(int slot) { ReapplyAmmo(slot); }
public Action Timer_ReapplyAmmo(Handle timer, int slot)
{
	ReapplyAmmo(slot);
	return Plugin_Stop;
}
void ReapplyAmmo(int slot)
{
	if (slot < 0 || slot >= MAX_SURVIVORS)
		return;
	if (++giveNums[slot] > 4) // 最多重试几次,避免无限
		return;

	int client = g_slotClient[slot];
	if (!IsClientInGame(client) || GetClientTeam(client) != 2)
		return;

	SurvivorSave save;
	save = g_asaved[slot];

	// 主武器弹药
	if (save.primary[0])
	{
		int ent = GetPlayerWeaponSlot(client, SLOT_PRIMARY);
		if (ent > MaxClients)
		{
			SetEntProp(ent, Prop_Send, "m_iClip1", save.primaryClip);
			if (save.primaryReserve >= 0)
				SetPlayerAmmoByType(client, ent, save.primaryReserve);
		}
	}
	// 副武器弹药(非近战)
	if (save.secondary[0] && !StrEqual(save.secondary, "weapon_melee", false))
	{
		int ent = GetPlayerWeaponSlot(client, SLOT_SECONDARY);
		if (ent > MaxClients)
		{
			if (save.secondaryClip >= 0)
				SetEntProp(ent, Prop_Send, "m_iClip1", save.secondaryClip);
			if (save.secondaryReserve >= 0)
				SetPlayerAmmoByType(client, ent, save.secondaryReserve);
		}
	}
	// 投掷物弹药
	if (save.throwable[0])
	{
		int ent = GetPlayerWeaponSlot(client, SLOT_THROWABLE);
		if (ent > MaxClients && save.throwableClip >= 0)
			SetEntProp(ent, Prop_Send, "m_iClip1", save.throwableClip);
	}

	// 最终恢复后打印实际状态供诊断
	if (g_cvDebug.BoolValue && giveNums[slot] >= 4)
	{
		char prim[64], sec[64];
		int pe = GetPlayerWeaponSlot(client, SLOT_PRIMARY);
		int se = GetPlayerWeaponSlot(client, SLOT_SECONDARY);
		if (pe > MaxClients)
		{
			GetEdictClassname(pe, prim, sizeof(prim));
			PrintToServer("[progress-save] final slot=%d 实际主:%s clip=%d reserve=%d",
				slot, prim, GetEntProp(pe, Prop_Send, "m_iClip1"), L4D_GetReserveAmmo(client, pe));
		}
		if (se > MaxClients)
		{
			GetEdictClassname(se, sec, sizeof(sec));
			PrintToServer("[progress-save] final slot=%d 实际副:%s clip=%d", slot, sec, GetEntProp(se, Prop_Send, "m_iClip1"));
		}
	}
}

// 通过 m_iPrimaryAmmoType 设置玩家备弹(与 l4d_drop 一致,覆盖整个 leave safe 补弹机制)
void SetPlayerAmmoByType(int client, int weapon, int ammo)
{
	int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	if (ammoType >= 0)
	{
		SetEntProp(client, Prop_Send, "m_iAmmo", ammo, _, ammoType);
		ChangeEdictState(client, FindDataMapInfo(client, "m_iAmmo"));
	}
}

// ============ 存档(异步读取武器) ============
// 一次存档的客户端队列
ArrayList g_saveClients;
int g_savePhase[MAXPLAYERS + 1]; // 当前读取槽位:0主 1副 2投掷 3完成
char g_savePath[PLATFORM_MAX_PATH];
int g_saveSlotIdx[MAXPLAYERS + 1];

bool SaveProgress()
{
	char map[64];
	GetCurrentMap(map, sizeof(map));

	int botsLimit = GetBotsLimitCvar();

	// 构建目录
	char rootDir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, rootDir, sizeof(rootDir), "%s", g_sSaveRoot);
	if (!DirExists(rootDir))
		CreateDirectory(rootDir, 0755);

	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "%s/%s", g_sSaveRoot, map);
	if (!DirExists(dir))
		CreateDirectory(dir, 0755);

	Format(g_savePath, sizeof(g_savePath), "%s/%s", dir, g_sSaveFile);

	g_iSavedBotsLimit = botsLimit;
	strcopy(g_sSavedMap, sizeof(g_sSavedMap), map);

	char difficulty[16], mode[32];
	ConVar cDifficulty = FindConVar("z_difficulty");
	ConVar cMode = FindConVar("mp_gamemode");
	if (cDifficulty != null)
		GetConVarString(cDifficulty, difficulty, sizeof(difficulty));
	if (cMode != null)
		GetConVarString(cMode, mode, sizeof(mode));
	strcopy(g_sSavedDifficulty, sizeof(g_sSavedDifficulty), difficulty);
	strcopy(g_sSavedMode, sizeof(g_sSavedMode), mode);

	// 收集队伍client,记录槽位
	if (g_saveClients == null)
		Save_Clear();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 2)
			continue;
		g_saveClients.Push(i);
		g_savePhase[i] = 0; // 从主武器开始
		if (g_saveClients.Length <= MAX_SURVIVORS)
			g_saveSlotIdx[i] = g_saveClients.Length - 1;
	}

	// 立即读取各client静止项(血量/医疗/药等), 武器弹药走异步
	Save_CollectStatic();

	// 启动异步读取第一把武器
	Save_ReadNextWeapon();

	// 通知在异步完成回调 Save_WriteFile 里
	return true;
}

void Save_Clear()
{
	if (g_saveClients == null)
		g_saveClients = new ArrayList();
	for (int i = 0; i < g_saveClients.Length; i++)
	{
		int c = g_saveClients.Get(i);
		g_savePhase[c] = 3;
	}
	g_saveClients.Clear();
}

// 收集不需要切武器的字段
void Save_CollectStatic()
{
	for (int i = 0; i < g_saveClients.Length; i++)
	{
		int c = g_saveClients.Get(i);
		int idx = g_saveSlotIdx[c];
		SurvivorSave save;
		save.isHuman = !IsFakeClient(c);
		if (save.isHuman)
			GetClientAuthId(c, AuthId_Steam2, save.steamid, sizeof(save.steamid));
		save.character = GetEntProp(c, Prop_Send, "m_zombieClass");
		save.health = GetEntProp(c, Prop_Send, "m_iHealth");
		save.maxhealth = GetEntProp(c, Prop_Send, "m_iMaxHealth");
		save.temphealth = L4D_GetTempHealth(c);
		save.incappedCount = GetEntProp(c, Prop_Send, "m_currentReviveCount");
		ReadSlot(c, SLOT_MEDKIT, save.medkit, sizeof(save.medkit));
		ReadSlot(c, SLOT_PILLS,  save.pills, sizeof(save.pills));
		g_asaved[idx] = save;
		g_saveClients.Set(i, c); // 无操作保持
		// 仍要记录c在列表
	}
	g_iSavedSurvivorCount = g_saveClients.Length;
}

// 读取下一个需要切武器看的槽位(主/副/投掷),通过 use 让武器active后下帧读
void Save_ReadNextWeapon()
{
	for (int i = 0; i < g_saveClients.Length; i++)
	{
		int c = g_saveClients.Get(i);
		if (g_savePhase[c] > 2)
			continue;
		int slot = g_savePhase[c]; // 0主 1副 2投掷
		int ent = GetPlayerWeaponSlot(c, slot);
		if (ent <= MaxClients)
		{
			// 该槽无武器,跳过
			g_savePhase[c]++;
			if (slot == 1)
			{
				// 也记录近战kind(可能无)
				Save_ReadMeleeKindIf(c);
			}
			Save_ReadNextWeapon(); // 递归处理下一个(同client或下一client)
			return;
		}
		char cls[64];
		GetEdictClassname(ent, cls, sizeof(cls));

		if (IsFakeClient(c))
		{
			// bot 不能 use 命令切换,直接读(尽力而为)
			Save_CollectWeaponAmmo(c);
			Save_ReadNextWeapon(); // 递归处理下一槽/下一client
			return;
		}

		FakeClientCommand(c, "use %s", cls);
		// 稍后读取(给切换武器留时间)
		CreateTimer(0.1, Save_TimerReadClip, c, TIMER_FLAG_NO_MAPCHANGE);
		return; // 一次只处理一个,其余下轮
	}
	// 全部完成,写文件
	Save_WriteFile();
}

public Action Save_TimerReadClip(Handle timer, int c)
{
	if (!IsClientInGame(c))
	{
		Save_Clear();
		return Plugin_Stop;
	}
	Save_CollectWeaponAmmo(c);
	Save_ReadNextWeapon();
	return Plugin_Stop;
}

// 读完当前 active 武器弹药后存入,然后推进
void Save_CollectWeaponAmmo(int c)
{
	int slot = g_savePhase[c];
	if (slot > 2)
		return;
	int idx = g_saveSlotIdx[c];
	int ent = GetPlayerWeaponSlot(c, slot);
	SurvivorSave save;
		save = g_asaved[idx];

	switch (slot)
	{
		case 0:
		{
			if (ent > MaxClients)
				GetEdictClassname(ent, save.primary, sizeof(save.primary));
			save.primaryClip = ent > MaxClients ? GetEntProp(ent, Prop_Send, "m_iClip1") : -1;
			save.primaryReserve = Save_GetReserve(c, ent);
		}
		case 1:
		{
			if (ent > MaxClients)
				GetEdictClassname(ent, save.secondary, sizeof(save.secondary));
			save.secondaryClip = ent > MaxClients ? GetEntProp(ent, Prop_Send, "m_iClip1") : -1;
			save.secondaryReserve = Save_GetReserve(c, ent);
			if (StrEqual(save.secondary, "weapon_melee", false))
				Save_ReadMeleeKind(c, save.secondaryKind, sizeof(save.secondaryKind));
		}
		case 2:
		{
			if (ent > MaxClients)
				GetEdictClassname(ent, save.throwable, sizeof(save.throwable));
			save.throwableClip = ent > MaxClients && GetEntProp(ent, Prop_Send, "m_iClip1") ? GetEntProp(ent, Prop_Send, "m_iClip1") : -1;
		}
	}
	g_asaved[idx] = save;
	g_savePhase[c] = slot + 1;
}

int Save_GetReserve(int client, int weapon)
{
	int ammotype = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	if (ammotype >= 0)
		return GetEntProp(client, Prop_Send, "m_iAmmo", _, ammotype);
	return 0;
}

void Save_ReadMeleeKindIf(int c)
{
	int idx = g_saveSlotIdx[c];
	int ent = GetPlayerWeaponSlot(c, SLOT_SECONDARY);
	if (ent > MaxClients && StrEqual(g_asaved[idx].secondary, "weapon_melee", false))
		Save_ReadMeleeKind(c, g_asaved[idx].secondaryKind, sizeof(g_asaved[idx].secondaryKind));
}

void Save_ReadMeleeKind(int client, char[] kind, int maxlen)
{
	int ent = GetPlayerWeaponSlot(client, SLOT_SECONDARY);
	if (ent == -1)
	{
		kind[0] = '\0';
		return;
	}
	GetEntPropString(ent, Prop_Data, "m_strMapSetScriptName", kind, maxlen);
	if (kind[0] == '\0')
	{
		char model[128];
		GetEntPropString(ent, Prop_Data, "m_ModelName", model, sizeof(model));
		if (StrContains(model, "v_tonfa.mdl", false) != -1)
			strcopy(kind, maxlen, "tonfa");
	}
}

void Save_WriteFile()
{
	if (g_cvDebug.BoolValue)
	{
		for (int i = 0; i < g_iSavedSurvivorCount; i++)
			PrintToServer("[progress-save] 存: slot=%d 主:%s clip=%d reserve=%d 副:%s clip=%d reserve=%d kind=%s 投掷:%s",
				i, g_asaved[i].primary, g_asaved[i].primaryClip, g_asaved[i].primaryReserve,
				g_asaved[i].secondary, g_asaved[i].secondaryClip, g_asaved[i].secondaryReserve, g_asaved[i].secondaryKind,
				g_asaved[i].throwable);
	}

	// 记录save metadata
	char path[PLATFORM_MAX_PATH];
	strcopy(path, sizeof(path), g_savePath);
	char map[64];
	strcopy(map, sizeof(map), g_sSavedMap);

	int count = g_saveClients.Length;
	int botsLimit = g_iSavedBotsLimit;

	// 写建档
	char tmp[PLATFORM_MAX_PATH];
	Format(tmp, sizeof(tmp), "%s.tmp", path);

	KeyValues kv = new KeyValues("ProgressSave");
	kv.SetString("map", map);
	kv.SetNum("bots_limit", botsLimit);
	kv.SetString("difficulty", g_sSavedDifficulty);
	kv.SetString("mode", g_sSavedMode);
	kv.SetNum("survivors", count);
	kv.SetString("save_time", "0");
	kv.SetString("saved_by", "");

	for (int i = 0; i < count; i++)
	{
		char section[16];
		Format(section, sizeof(section), "Slot%d", i);
		kv.JumpToKey(section, true);
		SurvivorSave save;
			save = g_asaved[i];
		kv.SetString("steamid", save.steamid);
		kv.SetNum("is_human", save.isHuman ? 1 : 0);
		kv.SetNum("character", save.character);
		kv.SetNum("health", save.health);
		kv.SetNum("maxhealth", save.maxhealth);
		kv.SetFloat("temphealth", save.temphealth);
		kv.SetNum("incapped", save.incappedCount);
		kv.SetString("primary", save.primary);
		kv.SetNum("primary_clip", save.primaryClip);
		kv.SetNum("primary_reserve", save.primaryReserve);
		kv.SetString("secondary", save.secondary);
		kv.SetNum("secondary_clip", save.secondaryClip);
		kv.SetNum("secondary_reserve", save.secondaryReserve);
		kv.SetString("secondary_kind", save.secondaryKind);
		kv.SetString("throwable", save.throwable);
		kv.SetNum("throwable_clip", save.throwableClip);
		kv.SetString("medkit", save.medkit);
		kv.SetString("pills", save.pills);
		kv.GoBack();
	}

	kv.ExportToFile(tmp);
	kv.Rewind();
	delete kv;

	bool ok = FileExists(tmp);
	if (ok)
		RenameFile(path, tmp);

	Save_Clear();

	if (ok)
		CPrintToChatAll("{green}[进度]{olive}%s{default}已保存进度到 {olive}%s{default} (人数:{olive}%d{default}).", g_sSavedMap, map, botsLimit);
	else
		CPrintToChatAll("{green}[进度]{olive}保存失败,请查看控制台日志.");
}

// 读取某个槽位的武器信息
void ReadSlot(int client, int slot, char[] classname, int maxlen, int &clip = 0, int &reserve = 0)
{
	int ent = GetPlayerWeaponSlot(client, slot);
	if (ent == -1)
	{
		classname[0] = '\0';
		return;
	}
	GetEdictClassname(ent, classname, maxlen);
}

// ============ 存档读取 ============
bool ReadSaveMeta(const char[] path, char[] map, int maxlen)
{
	KeyValues kv = new KeyValues("ProgressSave");
	if (!kv.ImportFromFile(path))
	{
		delete kv;
		return false;
	}
	map[0] = '\0';
	kv.GetString("map", map, maxlen);
	bool ok = (map[0] != '\0');
	delete kv;
	return ok;
}

bool ReadSaveData(const char[] path)
{
	KeyValues kv = new KeyValues("ProgressSave");
	if (!kv.ImportFromFile(path))
	{
		delete kv;
		return false;
	}

	kv.GetString("map", g_sSavedMap, sizeof(g_sSavedMap));
	g_iSavedBotsLimit = kv.GetNum("bots_limit", 0);
	kv.GetString("difficulty", g_sSavedDifficulty, sizeof(g_sSavedDifficulty));
	kv.GetString("mode", g_sSavedMode, sizeof(g_sSavedMode));
	g_iSavedSurvivorCount = kv.GetNum("survivors", 0);
	if (g_iSavedSurvivorCount > MAX_SURVIVORS)
		g_iSavedSurvivorCount = MAX_SURVIVORS;

	for (int i = 0; i < g_iSavedSurvivorCount; i++)
	{
		char section[16];
		Format(section, sizeof(section), "Slot%d", i);
		if (!kv.JumpToKey(section))
			continue;
		kv.GetString("steamid", g_asaved[i].steamid, sizeof(g_asaved[i].steamid));
		g_asaved[i].isHuman = kv.GetNum("is_human", 0) != 0;
		g_asaved[i].character = kv.GetNum("character", 0);
		g_asaved[i].health = kv.GetNum("health", 100);
		g_asaved[i].maxhealth = kv.GetNum("maxhealth", 100);
		g_asaved[i].temphealth = kv.GetFloat("temphealth", 0.0);
		g_asaved[i].incappedCount = kv.GetNum("incapped", 0);
		kv.GetString("primary", g_asaved[i].primary, sizeof(g_asaved[i].primary));
		g_asaved[i].primaryClip = kv.GetNum("primary_clip", 0);
		g_asaved[i].primaryReserve = kv.GetNum("primary_reserve", 0);
		kv.GetString("secondary", g_asaved[i].secondary, sizeof(g_asaved[i].secondary));
		g_asaved[i].secondaryClip = kv.GetNum("secondary_clip", 0);
		g_asaved[i].secondaryReserve = kv.GetNum("secondary_reserve", 0);
		kv.GetString("secondary_kind", g_asaved[i].secondaryKind, sizeof(g_asaved[i].secondaryKind));
		kv.GetString("throwable", g_asaved[i].throwable, sizeof(g_asaved[i].throwable));
		g_asaved[i].throwableClip = kv.GetNum("throwable_clip", 0);
		kv.GetString("medkit", g_asaved[i].medkit, sizeof(g_asaved[i].medkit));
		kv.GetString("pills", g_asaved[i].pills, sizeof(g_asaved[i].pills));
		kv.GoBack();
	}

	delete kv;
	return true;
}

// ============ 展示 ============
void ShowSaveInfo(int client)
{
	char map[64];
	GetCurrentMap(map, sizeof(map));
	char path[PLATFORM_MAX_PATH];
	if (!BuildSaveFilePath(map, path, sizeof(path)) || !FileExists(path))
	{
		CPrintToChat(client, "{green}[进度]{olive}当前地图 {olive}%s{default} 暂无存档.", map);
		return;
	}
	KeyValues kv = new KeyValues("ProgressSave");
	if (kv.ImportFromFile(path))
	{
		char savedMap[64], diff[16], mode[16];
		kv.GetString("map", savedMap, sizeof(savedMap));
		kv.GetString("difficulty", diff, sizeof(diff));
		kv.GetString("mode", mode, sizeof(mode));
		int limit = kv.GetNum("bots_limit", 0);
		int surv = kv.GetNum("survivors", 0);
		CPrintToChat(client, "{green}[进度]{default}存档信息: 地图{olive}%s{default}/难度{olive}%s{default}/模式{olive}%s{default}/人数{olive}%d{default}/生还{olive}%d{default}.",
			savedMap, diff, mode, limit, surv);
		delete kv;
	}
	else
	{
		CPrintToChat(client, "{green}[进度]{olive}存档文件读取失败.");
		delete kv;
	}
}

// ============ 工具 ============
int GetBotsLimitCvar()
{
	ConVar cvar = FindConVar("bots_limit");
	if (cvar == null)
		return 0;
	return cvar.IntValue;
}

void SetBotsLimitCvar(int value)
{
	ConVar cvar = FindConVar("bots_limit");
	if (cvar != null)
		cvar.SetInt(value);
}

bool BuildSaveFilePath(const char[] map, char[] buffer, int maxlen)
{
	if (!map[0])
		return false;
	BuildPath(Path_SM, buffer, maxlen, "%s/%s/%s", g_sSaveRoot, map, g_sSaveFile);
	return true;
}

bool IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}