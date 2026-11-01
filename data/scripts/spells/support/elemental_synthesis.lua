local combat = Combat()
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_MAGIC_BLUE)
combat:setParameter(COMBAT_PARAM_AGGRESSIVE, false)

local condition = Condition(CONDITION_ATTRIBUTES)
condition:setParameter(CONDITION_PARAM_TICKS, 15 * 60 * 1000) -- 15 min stance
condition:setParameter(CONDITION_PARAM_BUFF_SPELL, true)
condition:setParameter(CONDITION_PARAM_STAT_MAGICPOINTSPERCENT, 110) -- +10% Magic Level

local spell = Spell("instant")

function spell.onCastSpell(creature, variant)
	local player = creature:getPlayer()
	if not player then return false end

	if player:getCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, 308) then
		player:removeCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, 308)
		player:getPosition():sendMagicEffect(CONST_ME_POFF)
		player:sendTextMessage(MESSAGE_STATUS_SMALL, "You deactivated Elemental Synthesis stance.")
		return true
	end

	condition:setParameter(CONDITION_PARAM_SUBID, 308)
	combat:addCondition(condition)
	player:sendTextMessage(MESSAGE_STATUS_SMALL, "You activated Elemental Synthesis stance (+10% Ice & Earth magic power).")
	return combat:execute(creature, variant)
end

spell:name("Elemental Synthesis")
spell:words("utito dru")
spell:group("support", "focus")
spell:vocation("druid;true", "elder druid;true")
spell:id(308)
spell:cooldown(10 * 1000)
spell:groupCooldown(2 * 1000)
spell:level(20)
spell:mana(400)
spell:isSelfTarget(true)
spell:isAggressive(false)
spell:isPremium(true)

spell:register()
