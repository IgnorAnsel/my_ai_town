class_name AgentGameMode
extends RefCounted
## 开局模式的 Agent 侧标识与提示词覆盖层选择。
##
## 模式是 Agent 的私有约定，不是 World 的公共属性：它不进入世界状态、
## 存档字段、公开契约或信号。默认模式 STANDARD 与历史行为完全一致——
## 覆盖层为空时提示词编译不会多加载任何文件。
##
## 提示词采用「基线 + 覆盖层」而不是替换根目录：决策契约、资料权威和
## 事实边界等规则必须始终生效，模式只允许在其后追加本模式的补充规则。


const STANDARD := "standard"
const WEREWOLF := "werewolf"
const SUPPORTED_MODES: Array[String] = [STANDARD, WEREWOLF]
const BASE_PROMPT_ROOT := "res://prompts"
const WEREWOLF_PROMPT_ROOT := "res://prompts/mode_werewolf"

const ROLE_DEALER := preload(
	"res://agent/mode/AgentWerewolfRoleDealer.gd"
)
const DIRECTOR := preload(
	"res://agent/mode/AgentWerewolfDirector.gd"
)


## 建立一局对局簿记。STANDARD 模式返回失败，不对局。
static func start_match(
	value: Variant,
	assignment: Dictionary,
	seed: int,
) -> Dictionary:
	return DIRECTOR.create(normalize(value), assignment, seed)


## 归一化外部传入的模式值；未知值与空值一律回落到 STANDARD，
## 保证旧调用方不传模式时行为不变。
static func normalize(value: Variant) -> String:
	if not value is String:
		return STANDARD
	var mode := (value as String).strip_edges()
	if mode.is_empty():
		return STANDARD
	return mode


## 校验模式是否受支持。返回空数组表示可用。
static func validate(value: Variant) -> Array[String]:
	var mode := normalize(value)
	if mode not in SUPPORTED_MODES:
		return ["不支持的开局模式：%s" % mode]
	return []


static func is_werewolf(value: Variant) -> bool:
	return normalize(value) == WEREWOLF


## 基线提示词根永远不变；模式只通过覆盖层追加规则。
static func prompt_root_for(_value: Variant) -> String:
	return BASE_PROMPT_ROOT


## 模式附加的提示词覆盖层根目录；STANDARD 返回空串表示不加载覆盖层。
static func prompt_overlay_root_for(value: Variant) -> String:
	if is_werewolf(value):
		return WEREWOLF_PROMPT_ROOT
	return ""


## 模式声明的覆盖层是否真的可加载。
##
## 覆盖层读取本身是宽松的（缺失目录不报错），所以这里在配置阶段显式检查，
## 避免狼人杀会话静默退化成普通模式却毫无提示。
static func validate_overlay(value: Variant) -> Array[String]:
	var overlay_root := prompt_overlay_root_for(value)
	if overlay_root.is_empty():
		return []
	if not DirAccess.dir_exists_absolute(overlay_root):
		return ["模式提示词覆盖层缺失：%s" % overlay_root]
	var rules_root := overlay_root.path_join("rules")
	if not DirAccess.dir_exists_absolute(rules_root):
		return ["模式提示词覆盖层缺少 rules 目录：%s" % rules_root]
	return []


## 从一份初始化资料反推开局模式。
##
## 模式本身刻意不写入存档字段，因此读档时必须靠 Agent 私有身份索引还原，
## 否则会出现「资料里是狼人身份、提示词却是普通模式」的错配。
## 初始化资料来自存档，所以这里只读不报错，识别不出就回落到 STANDARD。
static func detect_from_initialization(initialization: Variant) -> String:
	if not initialization is Dictionary:
		return STANDARD
	var me := (initialization as Dictionary).get("me", {}) as Dictionary
	var profile := me.get("soul_profile", {}) as Dictionary
	for value: Variant in profile.get("special_identities", []) as Array:
		if not value is Dictionary:
			continue
		var identity_id := String((value as Dictionary).get("identity_id", ""))
		if identity_id.begins_with(ROLE_DEALER.IDENTITY_PREFIX):
			return WEREWOLF
	return STANDARD


## 模式的模式化开局资料入口。STANDARD 不产生任何资料。
##
## 当前返回值直接符合 AgentSoulProfile 的资料结构与校验规则，
## 由开局编译方在需要时合并进 agentSoulProfiles。
static func synthesize_soul_profiles(
	value: Variant,
	resident_ids: Array,
	residents: Array,
	seed: int,
) -> Dictionary:
	if not is_werewolf(value):
		return {}
	return ROLE_DEALER.synthesize_soul_profiles(
		resident_ids,
		residents,
		seed,
	)


## 把模式身份合并进 SOUL_PROFILE.analyze_all 的既有结果并做契约校验。
##
## 返回可直接放进 openingConfig.agentSoulProfiles 的完整字典：
## STANDARD 原样返回 base；模式资料合并失败（例如名单为空）时同样回退到 base，
## 保证开局不会因为模式问题而失败。
static func merge_soul_profiles(
	value: Variant,
	base: Dictionary,
	resident_ids: Array,
	residents: Array,
	seed: int,
) -> Dictionary:
	if not is_werewolf(value):
		return base.duplicate(true)
	var overlay := synthesize_soul_profiles(
		value,
		resident_ids,
		residents,
		seed,
	)
	if overlay.is_empty():
		return base.duplicate(true)
	var merged := {}
	for resident_id: Variant in base:
		var key := String(resident_id)
		var overlay_profile := overlay.get(key, {}) as Dictionary
		var base_profile := base[resident_id] as Dictionary
		merged[key] = (
			ROLE_DEALER.merge_profile(base_profile, overlay_profile)
			if not overlay_profile.is_empty()
			else base_profile.duplicate(true)
		)
	# 模式身份必须覆盖到每名开局居民，否则该居民拿不到身份。
	for resident_id: Variant in overlay:
		var key := String(resident_id)
		if not merged.has(key):
			merged[key] = (overlay[resident_id] as Dictionary).duplicate(true)
	return merged


## 开局发牌种子。优先使用环境配置里已有的 randomSeed，
## 使同一份开局配置得到同一套身份；缺失时回落到 0（仍然确定，不是系统时间）。
static func opening_seed(opening_environment: Variant) -> int:
	if opening_environment is Dictionary:
		var value: Variant = (opening_environment as Dictionary).get("randomSeed", 0)
		if value is int or value is float:
			return int(value)
	return 0