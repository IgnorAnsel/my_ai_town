class_name AgentWerewolfRoleDealer
extends RefCounted
## 狼人杀模式的确定性阵营分配与私有开局资料合成。
##
## 设计约束（与项目既有约定保持一致）：
## 1. 随机必须是纯函数种子，同一居民集合与同一 seed 得到同一分配，
##    不使用全局随机、系统时间或 ticks。这里复用条件运行时相同的
##    LCG 参数（modulus 2147483647 / multiplier 48271）。
## 2. 分配结果先按居民 ID 排序再洗牌，因此与传入顺序无关。
## 3. 产物是 Agent 私有资料，只写进初始化资料的 me.soul_profile，
##    不进入 World 公开状态、公共事件或存档区段。


# 与 TownResidentConditionRuntime 相同的确定性随机参数，
# 避免项目内出现第二种随机风格。
const RANDOM_MODULUS := 2147483647
const RANDOM_MULTIPLIER := 48271

const FACTION_WEREWOLF := "werewolf"
const FACTION_SEER := "seer"
const FACTION_WITCH := "witch"
const FACTION_HUNTER := "hunter"
const FACTION_VILLAGER := "villager"

const SPECIAL_FACTIONS: Array[String] = [
	FACTION_WEREWOLF,
	FACTION_SEER,
	FACTION_WITCH,
	FACTION_HUNTER,
]

const FACTION_LABELS := {
	FACTION_WEREWOLF: "狼人",
	FACTION_SEER: "预言家",
	FACTION_WITCH: "女巫",
	FACTION_HUNTER: "猎人",
	FACTION_VILLAGER: "村民",
}

## 最小可开局规模。低于该人数时只保留狼人与村民，无法构成完整回合。
const MIN_SEER_COUNT := 3
const MIN_WITCH_COUNT := 6
const MIN_HUNTER_COUNT := 8

## 版本号从权威定义处读取，避免本地重复定义在对方升版时静默失效。
const SOUL_PROFILE := preload("res://agent/soul/AgentSoulProfile.gd")
const MAX_SOURCE_LENGTH := 1200
const MAX_PACK_MEMBERS_IN_LABEL := 6

## 私有身份索引的编号前缀。模式本身不写入存档，读档时靠这个前缀
## 从初始化资料反推模式，因此 AgentGameMode 也引用同一常量。
const IDENTITY_PREFIX := "werewolf_faction_"


## 计算给定人数下的阵营配额。规则固定且可被测试预期。
static func faction_quota(count: int) -> Dictionary:
	var quota := {
		FACTION_WEREWOLF: maxi(1, int(count / 4)),
		FACTION_SEER: 0,
		FACTION_WITCH: 0,
		FACTION_HUNTER: 0,
	}
	if count >= MIN_SEER_COUNT:
		quota[FACTION_SEER] = 1
	if count >= MIN_WITCH_COUNT:
		quota[FACTION_WITCH] = 1
	if count >= MIN_HUNTER_COUNT:
		quota[FACTION_HUNTER] = 1
	# 狼人不得占满全部席位，至少留一个非狼人。
	quota[FACTION_WEREWOLF] = mini(int(quota[FACTION_WEREWOLF]), maxi(count - 1, 0))
	quota[FACTION_VILLAGER] = maxi(
		count
		- int(quota[FACTION_WEREWOLF])
		- int(quota[FACTION_SEER])
		- int(quota[FACTION_WITCH])
		- int(quota[FACTION_HUNTER]),
		0,
	)
	return quota


## 分配阵营。返回 {ok, assignment, quota, randomState, errors}。
## assignment 为 resident_id -> faction 的字典。
static func deal(resident_ids: Array, seed: int) -> Dictionary:
	var ids: Array[String] = []
	for value: Variant in resident_ids:
		var resident_id := String(value).strip_edges()
		if resident_id.is_empty():
			return {
				"ok": false,
				"errors": ["阵营分配收到空居民编号"],
				"assignment": {},
				"quota": {},
				"randomState": 0,
			}
		if not ids.has(resident_id):
			ids.append(resident_id)
	ids.sort()
	var count := ids.size()
	if count <= 0:
		return {
			"ok": false,
			"errors": ["阵营分配至少需要一名居民"],
			"assignment": {},
			"quota": {},
			"randomState": 0,
		}
	var quota := faction_quota(count)
	var shuffled := ids.duplicate()
	var state := posmod(seed, RANDOM_MODULUS - 1) + 1
	# Fisher-Yates：确定性洗牌，使分配只依赖居民集合与 seed。
	for index in range(shuffled.size() - 1, 0, -1):
		state = int((state * RANDOM_MULTIPLIER) % RANDOM_MODULUS)
		if state <= 0:
			state = 1
		var swap_index := state % (index + 1)
		var carried := shuffled[index]
		shuffled[index] = shuffled[swap_index]
		shuffled[swap_index] = carried
	var assignment := {}
	var cursor := 0
	for faction: String in SPECIAL_FACTIONS:
		var remaining := int(quota.get(faction, 0))
		for _index in range(remaining):
			if cursor >= shuffled.size():
				break
			assignment[shuffled[cursor]] = faction
			cursor += 1
	while cursor < shuffled.size():
		assignment[shuffled[cursor]] = FACTION_VILLAGER
		cursor += 1
	return {
		"ok": true,
		"errors": [],
		"assignment": assignment,
		"quota": quota,
		"randomState": state,
	}


## 合成符合 AgentSoulProfile 契约的私有开局资料。
##
## residents 接受开局居民数组，每项含 residentId/resident_id 与 attributes。
## 返回 resident_id -> soul_profile；无法分配时返回空字典。
##
## 同伴必须以「姓名｜编号」出现：编号是稳定身份，姓名是模型实际能读懂的
## 称呼。只给编号会让「狼人识同伴」这条核心信息在提示词里失去作用。
static func synthesize_soul_profiles(
	resident_ids: Array,
	residents: Array,
	seed: int,
) -> Dictionary:
	var dealt := deal(resident_ids, seed)
	if not bool(dealt.get("ok", false)):
		return {}
	var assignment := dealt.get("assignment", {}) as Dictionary
	var attributes_by_id := _attributes_by_id(residents)
	var names_by_id := _names_by_id(residents)
	var pack_by_resident := _pack_members(assignment)
	var profiles := {}
	for resident_id_value: Variant in assignment:
		var resident_id := String(resident_id_value)
		var faction := String(assignment[resident_id])
		var attributes := attributes_by_id.get(resident_id, {}) as Dictionary
		profiles[resident_id] = _profile_for(
			resident_id,
			faction,
			attributes,
			pack_by_resident.get(resident_id, []) as Array,
			names_by_id,
		)
	return profiles


static func _attributes_by_id(residents: Array) -> Dictionary:
	var result := {}
	for value: Variant in residents:
		if not value is Dictionary:
			continue
		var resident := value as Dictionary
		var resident_id := String(resident.get(
			"residentId",
			resident.get("resident_id", ""),
		)).strip_edges()
		if resident_id.is_empty():
			continue
		var attributes := resident.get("attributes", {}) as Dictionary
		result[resident_id] = attributes.duplicate(true)
	return result


## 居民编号到姓名的索引，用于把同伴渲染成模型可读的形式。
static func _names_by_id(residents: Array) -> Dictionary:
	var result := {}
	for value: Variant in residents:
		if not value is Dictionary:
			continue
		var resident := value as Dictionary
		var resident_id := String(resident.get(
			"residentId",
			resident.get("resident_id", ""),
		)).strip_edges()
		if resident_id.is_empty():
			continue
		var attributes := resident.get("attributes", {}) as Dictionary
		var name := String(attributes.get("name", resident.get("name", ""))).strip_edges()
		if not name.is_empty():
			result[resident_id] = name
	return result


## 把模式身份合并进既有开局资料。
##
## 合并而不是替换：AgentSoulProfile.analyze 从 OC 文本得出的特殊身份与关系线索
## 必须保留，本模式只追加自己的身份条目。重复编译时先清掉旧的模式条目，
## 避免同一身份在 special_identities 里出现两次。
static func merge_profile(base: Dictionary, overlay: Dictionary) -> Dictionary:
	if base.is_empty():
		return overlay.duplicate(true)
	if overlay.is_empty():
		return base.duplicate(true)
	var merged := base.duplicate(true)
	var identities: Array = []
	for value: Variant in merged.get("special_identities", []) as Array:
		if not value is Dictionary:
			continue
		var identity_id := String((value as Dictionary).get("identity_id", ""))
		if identity_id.begins_with(IDENTITY_PREFIX):
			continue
		identities.append(value)
	for value: Variant in overlay.get("special_identities", []) as Array:
		identities.append(value)
	merged["special_identities"] = identities
	if not merged.get("relationship_hints") is Array:
		merged["relationship_hints"] = []
	var base_source := String(merged.get("source_text", ""))
	var overlay_source := String(overlay.get("source_text", ""))
	merged["source_text"] = _truncate_source(
		"%s；%s" % [overlay_source, base_source] if not base_source.is_empty() else overlay_source,
	)
	# 不在这里写 analysis_version：该版本号由 AgentSoulProfile 拥有，
	# 基座（analyze_all 的产物）已带正确值，本地重复定义会在对方升版时冲突。
	return merged


static func _truncate_source(text: String) -> String:
	if text.length() <= MAX_SOURCE_LENGTH:
		return text
	return text.substr(0, MAX_SOURCE_LENGTH)


## 与 AgentPromptCompiler._person 相同的「编号｜姓名」惯例，
## 保证提示词里同一个人在任何位置都是同一种写法。
static func _person_label(resident_id: String, names_by_id: Dictionary) -> String:
	var name := String(names_by_id.get(resident_id, "")).strip_edges()
	if name.is_empty():
		return resident_id
	return "%s｜%s" % [name, resident_id]


## 狼人需要知道同伴；其他阵营不产生额外条目。
static func _pack_members(assignment: Dictionary) -> Dictionary:
	var pack: Array[String] = []
	for resident_id_value: Variant in assignment:
		if String(assignment[resident_id_value]) == FACTION_WEREWOLF:
			pack.append(String(resident_id_value))
	pack.sort()
	var result := {}
	for resident_id_value: Variant in assignment:
		var resident_id := String(resident_id_value)
		if String(assignment[resident_id]) != FACTION_WEREWOLF:
			continue
		var teammates: Array[String] = []
		for mate: String in pack:
			if mate != resident_id:
				teammates.append(mate)
		result[resident_id] = teammates
	return result


static func _profile_for(
	resident_id: String,
	faction: String,
	attributes: Dictionary,
	teammates: Array,
	names_by_id: Dictionary,
) -> Dictionary:
	var label := String(FACTION_LABELS.get(faction, faction))
	var identities: Array[Dictionary] = [{
		"identity_id": "%s%s" % [IDENTITY_PREFIX, faction],
		"label": "本次身份：%s" % label,
		"evidence": "开局身份由本局发牌确定：%s。" % label,
		"confidence": "high",
	}]
	if faction == FACTION_WEREWOLF and not teammates.is_empty():
		var shown: Array[String] = []
		for index in mini(teammates.size(), MAX_PACK_MEMBERS_IN_LABEL):
			shown.append(_person_label(String(teammates[index]), names_by_id))
		identities.append({
			"identity_id": "%spack" % IDENTITY_PREFIX,
			"label": "狼人同伴：%s" % "、".join(shown),
			"evidence": "发牌结果：本人与上述居民同为狼人。",
			"confidence": "high",
		})
	return {
		"analysis_version": SOUL_PROFILE.ANALYSIS_VERSION,
		"source_text": _source_text(resident_id, faction, attributes),
		"special_identities": identities,
		"relationship_hints": [],
	}


## 与 AgentSoulProfile.analyze 相同的资料字段来源，保持两套资料同形。
static func _source_text(
	resident_id: String,
	faction: String,
	attributes: Dictionary,
) -> String:
	var parts: Array[String] = ["身份：%s" % String(FACTION_LABELS.get(faction, faction))]
	for field_name in ["name", "gender", "age", "desire", "personality", "speech"]:
		var text := str(attributes.get(field_name, "")).strip_edges()
		if not text.is_empty():
			parts.append("%s：%s" % [field_name, text])
	for field_name in ["interests", "customInterests"]:
		for value: Variant in attributes.get(field_name, []) as Array:
			var interest := str(value).strip_edges()
			if not interest.is_empty():
				parts.append("兴趣：%s" % interest)
	var source_text := "%s（%s）；%s" % [
		String(attributes.get("name", resident_id)),
		resident_id,
		"；".join(parts),
	]
	if source_text.length() > MAX_SOURCE_LENGTH:
		source_text = source_text.substr(0, MAX_SOURCE_LENGTH)
	return source_text