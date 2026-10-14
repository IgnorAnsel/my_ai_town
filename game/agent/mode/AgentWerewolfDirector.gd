class_name AgentWerewolfDirector
extends RefCounted
## 狼人杀对局导演：回合推进、放逐结算与胜负判定。
##
## 设计边界（路线 A「借壳」的硬约束）：
## 1. 不新增动作类型：居民全程使用既有 13 种动作，本模块不参与动作派发。
## 2. 不碰死亡与自动补位：出局只在导演自己的簿记里标记，绝不调用
##    死亡确认，因此不会触发 GameFlowHost 的居民补位轮询。
## 3. 不改 World 状态：阵营与出局记录是导演私有数据，通过私有事件
##    （queue_world_event）通知本人，通过世界日志让上帝视角的玩家看到。
## 4. 确定性：目标推演只依赖传入的票数与排序，随机仅用于夜间选择且
##    seed 由调用方提供，不使用系统时间。


const GAME_MODE := preload("res://agent/mode/AgentGameMode.gd")
const ROLE_DEALER := preload("res://agent/mode/AgentWerewolfRoleDealer.gd")

const PHASE_PREPARING := "preparing"
const PHASE_NIGHT := "night"
const PHASE_DAY_DISCUSSION := "day_discussion"
const PHASE_DAY_EXILE := "day_exile"
const PHASE_FINISHED := "finished"

const PHASE_ORDER: Array[String] = [
	PHASE_PREPARING,
	PHASE_NIGHT,
	PHASE_DAY_DISCUSSION,
	PHASE_DAY_EXILE,
	PHASE_FINISHED,
]

const TEAM_WEREWOLF := "werewolf"
const TEAM_GOOD := "good"

const OUTCOME_GOOD_WIN := "good_win"
const OUTCOME_WEREWOLF_WIN := "werewolf_win"
const OUTCOME_STALEMATE := "stalemate"

const MIN_PLAYERS := 4
const MAX_EXILE_TARGETS := 8

# 与 AgentWerewolfRoleDealer 相同的确定性随机参数。
const RANDOM_MODULUS := 2147483647
const RANDOM_MULTIPLIER := 48271


## 建立一局对局簿记。assignment 为 resident_id -> faction。
static func create(
	game_mode: String,
	assignment: Dictionary,
	seed: int,
) -> Dictionary:
	if not GAME_MODE.is_werewolf(game_mode):
		return _failure("WEREWOLF_MODE_REQUIRED", ["只有狼人杀模式可以开始对局"])
	if assignment.size() < MIN_PLAYERS:
		return _failure(
			"WEREWOLF_PLAYERS_INSUFFICIENT",
			["狼人杀至少需要 %d 名居民，实际 %d 名" % [MIN_PLAYERS, assignment.size()]],
		)
	var alive: Array[String] = []
	var exiled: Array[String] = []
	for resident_id_value: Variant in assignment:
		alive.append(String(resident_id_value))
	alive.sort()
	return {
		"ok": true,
		"errors": [],
		"state": {
			"gameMode": GAME_MODE.WEREWOLF,
			"day": 1,
			"phase": PHASE_PREPARING,
			"phaseIndex": 0,
			"assignment": assignment.duplicate(true),
			"alive": alive,
			"exiled": exiled,
			"nightTarget": "",
			"nightOutcome": "",
			"votes": {},
			"lastExile": {},
			"outcome": "",
			"randomState": posmod(seed, RANDOM_MODULUS - 1) + 1,
		},
	}


## 存活居民中属于指定阵营的编号，稳定排序。
static func team_members(state: Dictionary, team: String) -> Array[String]:
	var assignment := state.get("assignment", {}) as Dictionary
	var members: Array[String] = []
	for resident_id_value: Variant in state.get("alive", []) as Array:
		var resident_id := String(resident_id_value)
		if _team_of(assignment, resident_id) == team:
			members.append(resident_id)
	members.sort()
	return members


static func _team_of(assignment: Dictionary, resident_id: String) -> String:
	var faction := String(assignment.get(resident_id, ""))
	if faction == ROLE_DEALER.FACTION_WEREWOLF:
		return TEAM_WEREWOLF
	if faction.is_empty():
		return ""
	return TEAM_GOOD


## 推进到下一个阶段。
##
## 阶段循环：preparing → night → day_discussion → day_exile →（判胜负）
## 未分出胜负时回到 night 并进入下一天，直到满足结束条件才进入 finished。
static func advance_phase(state: Dictionary) -> Dictionary:
	var current := String(state.get("phase", PHASE_PREPARING))
	if current == PHASE_FINISHED:
		return _failure("WEREWOLF_MATCH_FINISHED", ["对局已经结束"])
	var next_state := state.duplicate(true)
	if current == PHASE_PREPARING:
		next_state["phase"] = PHASE_NIGHT
	elif current == PHASE_NIGHT:
		next_state["phase"] = PHASE_DAY_DISCUSSION
	elif current == PHASE_DAY_DISCUSSION:
		next_state["phase"] = PHASE_DAY_EXILE
	elif current == PHASE_DAY_EXILE:
		# 放逐结算完毕后先判定胜负；只有确实分出胜负才终局，
		# 否则进入下一天的夜晚，继续完整的多日循环。
		var outcome := evaluate_outcome(next_state)
		if not outcome.is_empty():
			return finish(next_state)
		next_state["day"] = int(next_state.get("day", 1)) + 1
		next_state["votes"] = {}
		next_state["lastExile"] = {}
		next_state["nightTarget"] = ""
		next_state["nightOutcome"] = ""
		next_state["phase"] = PHASE_NIGHT
	else:
		return _failure("WEREWOLF_PHASE_UNKNOWN", ["未知的对局阶段：%s" % current])
	next_state["phaseIndex"] = PHASE_ORDER.find(String(next_state["phase"]))
	return {"ok": true, "errors": [], "state": next_state}


## 夜间狼人选目标：在存活的好人里按确定性随机挑选。
## 借壳方案里夜间不产生死亡，只登记「今夜被盯上的人」，由对外表现层
## 决定呈现方式；导演本身不改动任何居民生命状态。
static func resolve_night(state: Dictionary) -> Dictionary:
	var next_state := state.duplicate(true)
	var targets := team_members(next_state, TEAM_GOOD)
	if targets.is_empty():
		return finish(next_state)
	var state_value := int(next_state.get("randomState", 1))
	var random_state := state_value
	random_state = int((random_state * RANDOM_MULTIPLIER) % RANDOM_MODULUS)
	if random_state <= 0:
		random_state = 1
	next_state["randomState"] = random_state
	var choice := String(targets[random_state % targets.size()])
	next_state["nightTarget"] = choice
	next_state["nightOutcome"] = "marked"
	return {"ok": true, "errors": [], "state": next_state}


## 记录一名存活居民的放逐票。重复投票覆盖旧票。
static func record_vote(
	state: Dictionary,
	voter_id: String,
	target_id: String,
) -> Dictionary:
	if not (state.get("alive", []) as Array).has(voter_id):
		return _failure("WEREWOLF_VOTER_NOT_ALIVE", ["投票人不在对局中"])
	if not (state.get("alive", []) as Array).has(target_id):
		return _failure("WEREWOLF_TARGET_NOT_ALIVE", ["被投对象不在对局中"])
	if voter_id == target_id:
		return _failure("WEREWOLF_SELF_VOTE", ["不能投自己"])
	var next_state := state.duplicate(true)
	var votes := (next_state.get("votes", {}) as Dictionary).duplicate(true)
	votes[voter_id] = target_id
	next_state["votes"] = votes
	return {"ok": true, "errors": [], "state": next_state}


## 结算放逐：票数最高者出局；平票时按编号稳定取小，保证结果可复现。
static func resolve_exile(state: Dictionary) -> Dictionary:
	var next_state := state.duplicate(true)
	var votes := next_state.get("votes", {}) as Dictionary
	if votes.is_empty():
		next_state["lastExile"] = {
			"exiled": "",
			"reason": "no_votes",
		}
		return {"ok": true, "errors": [], "state": next_state}
	var tally := {}
	for voter_id_value: Variant in votes:
		var target := String(votes[voter_id_value])
		tally[target] = int(tally.get(target, 0)) + 1
	var ranked: Array = tally.keys()
	ranked.sort()
	var best_target := ""
	var best_count := -1
	for target_value: Variant in ranked:
		var target := String(target_value)
		var count := int(tally[target])
		if count > best_count:
			best_count = count
			best_target = target
	var alive: Array[String] = []
	for resident_id_value: Variant in next_state.get("alive", []) as Array:
		if String(resident_id_value) != best_target:
			alive.append(String(resident_id_value))
	var exiled: Array[String] = []
	for resident_id_value: Variant in next_state.get("exiled", []) as Array:
		exiled.append(String(resident_id_value))
	if not best_target.is_empty():
		exiled.append(best_target)
	next_state["alive"] = alive
	next_state["exiled"] = exiled
	next_state["votes"] = {}
	next_state["lastExile"] = {
		"exiled": best_target,
		"votes": best_count,
		"tally": tally.duplicate(true),
		"reason": "voted",
	}
	return {"ok": true, "errors": [], "state": next_state}


## 胜负判定。
## 狼人全部出局 → 好人胜；狼人数达到或超过好人 → 狼人胜；
## 双方都无法继续（例如同时清空）→ 平局。
static func finish(state: Dictionary) -> Dictionary:
	var next_state := state.duplicate(true)
	var wolves := team_members(next_state, TEAM_WEREWOLF).size()
	var goods := team_members(next_state, TEAM_GOOD).size()
	var outcome := OUTCOME_STALEMATE
	if wolves <= 0:
		outcome = OUTCOME_GOOD_WIN
	elif wolves >= goods:
		outcome = OUTCOME_WEREWOLF_WIN
	elif goods <= 0:
		outcome = OUTCOME_WEREWOLF_WIN
	next_state["outcome"] = outcome
	next_state["phase"] = PHASE_FINISHED
	next_state["phaseIndex"] = PHASE_ORDER.find(PHASE_FINISHED)
	return {"ok": true, "errors": [], "state": next_state}


static func is_finished(state: Dictionary) -> bool:
	return String(state.get("phase", "")) == PHASE_FINISHED


## 面向玩家（上帝视角）的公开结果文本。玩家不参战，因此这里可以说明真相，
## 但每一行都只描述世界已确认的事实：谁被投出、当前存活人数与阵营计数。
static func public_summary(state: Dictionary) -> Dictionary:
	var exiled := state.get("lastExile", {}) as Dictionary
	var exiled_id := String(exiled.get("exiled", ""))
	return {
		"day": int(state.get("day", 1)),
		"phase": String(state.get("phase", "")),
		"aliveCount": (state.get("alive", []) as Array).size(),
		"werewolfCount": team_members(state, TEAM_WEREWOLF).size(),
		"goodCount": team_members(state, TEAM_GOOD).size(),
		"exiledResidentId": exiled_id,
		"exiledVotes": int(exiled.get("votes", 0)),
		"outcome": String(state.get("outcome", "")),
	}


## 某名居民的私有身份提示文本，供模式层通知本人使用。
static func private_identity_text(state: Dictionary, resident_id: String) -> String:
	var assignment := state.get("assignment", {}) as Dictionary
	var faction := String(assignment.get(resident_id, ""))
	if faction.is_empty():
		return ""
	var label := String(ROLE_DEALER.FACTION_LABELS.get(faction, faction))
	if faction != ROLE_DEALER.FACTION_WEREWOLF:
		return "你的身份是：%s。" % label
	var teammates := team_members(state, TEAM_WEREWOLF)
	var others: Array[String] = []
	for teammate: String in teammates:
		if teammate != resident_id:
			others.append(teammate)
	if others.is_empty():
		return "你的身份是：%s，本局没有其他狼人。" % label
	return "你的身份是：%s，同伴：%s。" % [label, "、".join(others)]


static func _failure(error_code: String, errors: Array) -> Dictionary:
	return {
		"ok": false,
		"errorCode": error_code,
		"errors": errors,
		"state": {},
	}