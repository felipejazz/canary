local combat = Combat()
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_MAGIC_BLUE)
combat:setParameter(COMBAT_PARAM_AGGRESSIVE, false)

local condition = Condition(CONDITION_REGENERATION, CONDITIONID_DEFAULT)
condition:setParameter(CONDITION_PARAM_TICKS, 60 * 1000)
condition:setParameter(CONDITION_PARAM_HEALTHGAIN, 40)
condition:setParameter(CONDITION_PARAM_HEALTHTICKS, 2000)
combat:addCondition(condition)

local spell = Spell("instant")

function spell.onCastSpell(creature, var)
	return combat:execute(creature, var)
end

spell:group("healing")
spell:id(312)
spell:name("Shared Conservation")
spell:words("utura sio")
spell:level(20)
spell:mana(200)
spell:isPremium(true)
spell:needTarget(true)
spell:cooldown(60 * 1000)
spell:groupCooldown(1 * 1000)
spell:isAggressive(false)
spell:isBlockingWalls(true)
spell:hasParams(true)
spell:hasPlayerNameParam(true)
spell:vocation("druid;true", "elder druid;true")

spell:register()
