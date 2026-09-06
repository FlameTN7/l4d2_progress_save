# Left 4 Dead 2 进度存读档插件 (Progress Save / Load)

![SourceMod](https://img.shields.io/badge/SourceMod-1.12-orange) ![License](https://img.shields.io/badge/License-MIT-green)

用于 SourceMod 的 L4D2 插件：在`战役模式下`某一章地图开局（安全区）记录**队伍从前面章节带过来的状态**（弹药、枪械、近战、道具、血量），之后通过**投票读档**恢复。

主要为解决长图打不完想保存状态的问题提供一个方案。

## 依赖

运行本插件需要 SourceMod 及其他组件以实现完整功能：

| 依赖 | 作用 | 获取地址 |
|---|---|---|
| left4dhooks | 提供 L4D2 专属 API（回血/弹药/NavArea 等） |  https://forums.alliedmods.net/showthread.php?t=321696 （GPL v3） |
| l4d2_nativevote | 原生投票函数库 |  https://github.com/fdxx/l4d2_nativevote |
| l4d_restart_without_changelevel | 提供 `sm_restart`，用 `EndScenario` 同图重启（读档核心） |  https://forums.alliedmods.net/showthread.php?t=334009 |
| multicolors | 聊天着色 | https://github.com/popoklopsi/Stamm 的 stamm-colors.inc |

> 这些均为其他作者的开源组件，请自行从上述渠道获取对应版本安装，再启用本插件，不保证非完整情况下的可用性。


## 命令

| 命令 | 说明 |
|---|---|
| `sm_progress/!progress` | 打开存读档菜单 |
| `sm_save` /`!save`| 保存当前进度（限安全区、生还者） |
| `sm_load` /`!load`| 投票读档并重启本图 |
| `sm_progress_off` /`!progress_off`| 取消当前map读档状态 |

## ConVar
| ConVar | 默认 | 说明 |
|---|---|---|
| `l4d_progress_enable` | `1` | 总开关 |
| `l4d_progress_save_in_safearea_only` | `1` | 是否仅允许在出生安全区保存 |
| `l4d_progress_auto_restart` | `1` | 读档后是否自动重启本图 |
| `l4d_progress_restore_delay` | `1.5` | 为了防止其他插件冲突的延迟读档秒数 |
| `l4d_progress_vote_time` | `20` | 读档投票时长（秒） |
| `l4d_progress_align_botslimit` | `1` | 读档时是否把 `bots_limit` 对齐到存档人数 |
| `l4d_progress_debug` | `0` | 调试日志 |

## 存档位置

```
addons/sourcemod/data/progress_save/<map>/save.txt
```

每map仅保留最新一份存档






## 构建

```bash
cd addons/sourcemod/scripting
./spcomp64 l4d2_progress_save.sp -o l4d2_progress_save.smx
```

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
