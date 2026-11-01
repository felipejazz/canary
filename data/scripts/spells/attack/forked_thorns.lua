local combat = Combat()
combat:setParameter(COMBAT_PARAM_TYPE, COMBAT_EARTHDAMAGE)
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_PLANTATTACK)
combat:setParameter(COMBAT_PARAM_DISTANCEEFFECT, CONST_ANI_EARTH)
combat:setArea(createCombatArea(AREA_CIRCLE3X3))

function onGetFormulaValues(player, level, maglevel)
	local min = (level / 5) + (maglevel * 3.4) + 20
	local max = (level / 5) + (maglevel * 5.2) + 40
	return -min, -max
end

combat:setCallback(CALLBACK_PARAM_LEVELMAGICVALUE, "onGetFormulaValues")

local spell = Spell("instant")

function spell.onCastSpell(creature, var)
	return combat:execute(creature, var)
end

spell:group("attack")
spell:id(307)
spell:name("Forked Thorns")
spell:words("exevo fur tera")
spell:level(80)
spell:mana(150)
spell:range(4)
spell:needCasterTargetOrDirection(true)
spell:blockWalls(true)
spell:isPremium(true)
spell:cooldown(6 * 1000)
spell:groupCooldown(2 * 1000)

spell:vocation("druid;true", "elder druid;true")
spell:register()
