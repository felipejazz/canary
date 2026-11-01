local combat1 = Combat()
combat1:setParameter(COMBAT_PARAM_TYPE, COMBAT_DEATHDAMAGE)
combat1:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_MORTAREA)
combat1:setArea(createCombatArea(AREA_CIRCLE2X2))

local combat2 = Combat()
combat2:setParameter(COMBAT_PARAM_TYPE, COMBAT_DEATHDAMAGE)
combat2:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_MORTAREA)
combat2:setArea(createCombatArea(AREA_CIRCLE3X3))

function onGetFormulaValues1(player, level, maglevel)
	local min = (level / 5) + (maglevel * 4.2) + 25
	local max = (level / 5) + (maglevel * 6.5) + 40
	return -min, -max
end

function onGetFormulaValues2(player, level, maglevel)
	local min = ((level / 5) + (maglevel * 4.2) + 25) * 1.5
	local max = ((level / 5) + (maglevel * 6.5) + 40) * 1.5
	return -min, -max
end

combat1:setCallback(CALLBACK_PARAM_LEVELMAGICVALUE, "onGetFormulaValues1")
combat2:setCallback(CALLBACK_PARAM_LEVELMAGICVALUE, "onGetFormulaValues2")

local spell = Spell("instant")

function spell.onCastSpell(creature, var)
	local cid = creature:getId()
	local ok = combat1:execute(creature, var)
	if ok then
		addEvent(function()
			local c = Creature(cid)
			if c and not c:isRemoved() then
				combat2:execute(c, var)
			end
		end, 1000)
	end
	return ok
end

spell:group("attack")
spell:id(305)
spell:name("Death Echo")
spell:words("exevo mort ora")
spell:level(120)
spell:mana(150)
spell:range(4)
spell:needCasterTargetOrDirection(true)
spell:blockWalls(true)
spell:isPremium(true)
spell:cooldown(6 * 1000)
spell:groupCooldown(2 * 1000)

spell:vocation("sorcerer;true", "master sorcerer;true")
spell:register()
