local combat = Combat()
combat:setParameter(COMBAT_PARAM_TYPE, COMBAT_PHYSICALDAMAGE)
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_HITAREA)
combat:setParameter(COMBAT_PARAM_DISTANCEEFFECT, CONST_ANI_ETHEREALSPEAR)
combat:setParameter(COMBAT_PARAM_BLOCKARMOR, 1)
combat:setArea(createCombatArea(AREA_CIRCLE3X3))

function onGetFormulaValues(player, skill, attack, factor)
	local level = player:getLevel()
	local min = (level / 5) + (skill * 0.8) + 15
	local max = (level / 5) + (skill * 1.6) + 30
	return -min, -max
end

combat:setCallback(CALLBACK_PARAM_SKILLVALUE, "onGetFormulaValues")

local spell = Spell("instant")

function spell.onCastSpell(creature, var)
	return combat:execute(creature, var)
end

spell:group("attack")
spell:id(302)
spell:name("Ethereal Barrage")
spell:words("exori dir moe")
spell:level(60)
spell:mana(135)
spell:range(6)
spell:needTarget(true)
spell:blockWalls(true)
spell:isPremium(true)
spell:cooldown(4 * 1000)
spell:groupCooldown(2 * 1000)

spell:vocation("paladin;true", "royal paladin;true")
spell:register()
