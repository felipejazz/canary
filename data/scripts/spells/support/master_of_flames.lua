local combat = Combat()
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_FIREAREA)
combat:setParameter(COMBAT_PARAM_AGGRESSIVE, false)

local condition = Condition(CONDITION_ATTRIBUTES)
condition:setParameter(CONDITION_PARAM_TICKS, 15 * 60 * 1000)
condition:setParameter(CONDITION_PARAM_BUFF_SPELL, true)
condition:setParameter(CONDITION_PARAM_STAT_MAGICPOINTS, 3)
condition:setParameter(CONDITION_PARAM_BUFF_DAMAGEDEALT, 104) -- +4% Fire Damage

local spell = Spell("instant")

function spell.onCastSpell(creature, variant)
	local player = creature:getPlayer()
	if not player then return false end

	if player:getCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, 309) then
		player:removeCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, 309)
		player:getPosition():sendMagicEffect(CONST_ME_POFF)
		player:sendTextMessage(MESSAGE_STATUS_SMALL, "You deactivated Master of Flames stance.")
		return true
	end

	condition:setParameter(CONDITION_PARAM_SUBID, 309)
	combat:addCondition(condition)
	player:sendTextMessage(MESSAGE_STATUS_SMALL, "You activated Master of Flames stance (+4% Fire power).")
	return combat:execute(creature, variant)
end

spell:name("Master of Flames")
spell:words("uteta flam")
spell:group("support", "focus")
spell:vocation("sorcerer;true", "master sorcerer;true")
spell:id(309)
spell:cooldown(10 * 1000)
spell:groupCooldown(2 * 1000)
spell:level(20)
spell:mana(400)
spell:isSelfTarget(true)
spell:isAggressive(false)
spell:isPremium(true)

spell:register()
