local combat = Combat()
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_HOLYDAMAGE)
combat:setParameter(COMBAT_PARAM_AGGRESSIVE, false)

local condition = Condition(CONDITION_ATTRIBUTES)
condition:setParameter(CONDITION_PARAM_TICKS, -1) -- Permanente ate desativacao ou troca de stance
condition:setParameter(CONDITION_PARAM_BUFF_SPELL, true)
condition:setParameter(CONDITION_PARAM_BUFF_DAMAGERECEIVED, 94) -- defensive mitigation against distant damage
condition:setParameter(CONDITION_PARAM_STAT_MAGICPOINTS, 3)

local spell = Spell("instant")

function spell.onCastSpell(creature, variant)
	local player = creature:getPlayer()
	if not player then return false end

	-- Toggle stance: se ja estiver ativa, desativa a postura
	if player:getCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, 300) then
		player:removeCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, 300)
		player:getPosition():sendMagicEffect(CONST_ME_POFF)
		player:sendTextMessage(MESSAGE_STATUS_SMALL, "You deactivated Divine Defiance stance.")
		return true
	end

	-- Troca de postura: se Sharpshooter estiver ativo, desativa-o
	if player:getCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, AttrSubId_Sharpshooter) then
		player:removeCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, AttrSubId_Sharpshooter)
		player:sendTextMessage(MESSAGE_STATUS_SMALL, "Your offensive stance (Sharpshooter) was replaced by Divine Defiance.")
	end

	condition:setParameter(CONDITION_PARAM_SUBID, 300)
	combat:addCondition(condition)
	player:sendTextMessage(MESSAGE_STATUS_SMALL, "You activated Divine Defiance stance (+12% distant evasion, holy/healing bonus).")
	return combat:execute(creature, variant)
end

spell:name("Divine Defiance")
spell:words("utori hur")
spell:group("support", "focus")
spell:vocation("paladin;true", "royal paladin;true")
spell:id(300)
spell:cooldown(2 * 1000)
spell:groupCooldown(2 * 1000)
spell:level(20)
spell:mana(250)
spell:isSelfTarget(true)
spell:isAggressive(false)
spell:isPremium(true)

spell:register()
