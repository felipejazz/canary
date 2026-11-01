local combat = Combat()
combat:setParameter(COMBAT_PARAM_TYPE, COMBAT_PHYSICALDAMAGE)
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_BLOCKHIT)
combat:setParameter(COMBAT_PARAM_BLOCKARMOR, 1)

function onGetFormulaValues(player, skill, attack, factor)
	local level = player:getLevel()
	local shieldSkill = player:getSkillLevel(SKILL_SHIELD)
	local def = 30
	local left = player:getSlotItem(CONST_SLOT_LEFT)
	local right = player:getSlotItem(CONST_SLOT_RIGHT)
	if left and left:getType():getWeaponType() == WEAPON_SHIELD then
		def = left:getType():getDefense()
	elseif right and right:getType():getWeaponType() == WEAPON_SHIELD then
		def = right:getType():getDefense()
	end
	local min = (level / 5) + (shieldSkill * 0.5) + (def * 0.8)
	local max = (level / 5) + (shieldSkill * 1.2) + (def * 1.5)
	return -min, -max
end

combat:setCallback(CALLBACK_PARAM_SKILLVALUE, "onGetFormulaValues")

local spell = Spell("instant")

function spell.onCastSpell(creature, var)
	local player = creature:getPlayer()
	if player then
		local left = player:getSlotItem(CONST_SLOT_LEFT)
		local right = player:getSlotItem(CONST_SLOT_RIGHT)
		local hasShield = (left and left:getType():getWeaponType() == WEAPON_SHIELD) or (right and right:getType():getWeaponType() == WEAPON_SHIELD)
		if not hasShield then
			player:sendCancelMessage("You must equip a shield to use this spell.")
			player:getPosition():sendMagicEffect(CONST_ME_POFF)
			return false
		end
	end
	return combat:execute(creature, var)
end

spell:group("attack")
spell:id(303)
spell:name("Shield Bash")
spell:words("exori ico scu")
spell:level(18)
spell:mana(30)
spell:range(1)
spell:needTarget(true)
spell:isPremium(true)
spell:cooldown(4 * 1000)
spell:groupCooldown(2 * 1000)

spell:vocation("knight;true", "elite knight;true")
spell:register()
