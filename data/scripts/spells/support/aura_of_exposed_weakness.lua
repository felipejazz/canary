local function onTargetCreature(creature, target)
	if target:isPlayer() then return false end
	local condition = Condition(CONDITION_ATTRIBUTES)
	condition:setParameter(CONDITION_PARAM_TICKS, 16000)
	condition:setParameter(CONDITION_PARAM_BUFF_DAMAGERECEIVED, 105)
	target:addCondition(condition)
	return true
end

local combat = Combat()
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_MORTAREA)
combat:setArea(createCombatArea(AREA_CIRCLE3X3))
combat:setCallback(CALLBACK_PARAM_TARGETCREATURE, "onTargetCreature")

local spell = Spell("instant")

function spell.onCastSpell(creature, var)
	local target = creature:getTarget()
	if target then
		var = Variant(target)
	end
	return combat:execute(creature, var)
end

spell:group("support", "crippling")
spell:id(313)
spell:name("Aura of Exposed Weakness")
spell:words("exori moe tempo")
spell:level(175)
spell:mana(1500)
spell:isSelfTarget(true)
spell:cooldown(30 * 1000)
spell:groupCooldown(2 * 1000, 30 * 1000)
spell:vocation("sorcerer;true", "master sorcerer;true")

spell:register()
