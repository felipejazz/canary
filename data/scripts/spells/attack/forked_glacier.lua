local combat = Combat()
combat:setParameter(COMBAT_PARAM_TYPE, COMBAT_ICEDAMAGE)
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_ICEATTACK)
combat:setParameter(COMBAT_PARAM_DISTANCEEFFECT, CONST_ANI_ICE)
combat:setArea(createCombatArea(AREA_CIRCLE3X3))

function onGetFormulaValues(player, level, maglevel)
	local min = (level / 5) + (maglevel * 3.8) + 25
	local max = (level / 5) + (maglevel * 5.8) + 45
	return -min, -max
end

combat:setCallback(CALLBACK_PARAM_LEVELMAGICVALUE, "onGetFormulaValues")

local spell = Spell("instant")

function spell.onCastSpell(creature, var)
	return combat:execute(creature, var)
end

spell:group("attack")
spell:id(306)
spell:name("Forked Glacier")
spell:words("exevo fur frigo")
spell:level(90)
spell:mana(180)
spell:range(4)
spell:needCasterTargetOrDirection(true)
spell:blockWalls(true)
spell:isPremium(true)
spell:cooldown(6 * 1000)
spell:groupCooldown(2 * 1000)

spell:vocation("druid;true", "elder druid;true")
spell:register()
