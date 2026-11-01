local combat = Combat()
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_MAGIC_GREEN)
combat:setParameter(COMBAT_PARAM_AGGRESSIVE, false)

local spell = Spell("instant")

function spell.onCastSpell(creature, variant)
	local player = creature:getPlayer()
	if not player then return false end

	-- 1. Toggle: se ja estiver ativa, desativa a postura (remove condicao)
	if player:getCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, AttrSubId_Sharpshooter) then
		player:removeCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, AttrSubId_Sharpshooter)
		player:getPosition():sendMagicEffect(CONST_ME_POFF)
		player:sendTextMessage(MESSAGE_STATUS_SMALL, "You deactivated Sharpshooter stance.")
		return true
	end

	-- 2. Troca de postura: se a postura defensiva (Divine Defiance = 300) estiver ativa, desativa-a
	if player:getCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, 300) then
		player:removeCondition(CONDITION_ATTRIBUTES, CONDITIONID_COMBAT, 300)
		player:sendTextMessage(MESSAGE_STATUS_SMALL, "Your defensive stance (Divine Defiance) was replaced by Sharpshooter.")
	end

	-- 3. Postura ofensiva permanente (ticks = -1, permanece ativa continuamente ate ser desativada ou trocada)
	local skill = Condition(CONDITION_ATTRIBUTES)
	skill:setParameter(CONDITION_PARAM_SUBID, AttrSubId_Sharpshooter)
	skill:setParameter(CONDITION_PARAM_TICKS, -1)
	skill:setParameter(CONDITION_PARAM_BUFF_SPELL, true)

	-- Bonus de Distance Fighting em 32% (ou 36% com upgrade no Wheel of Destiny)
	local grade = player:upgradeSpellsWOD("Sharpshooter")
	if grade == WHEEL_GRADE_UPGRADED then
		skill:setParameter(CONDITION_PARAM_SKILL_DISTANCEPERCENT, 136)
	else
		skill:setParameter(CONDITION_PARAM_SKILL_DISTANCEPERCENT, 132)
	end

	-- Penalidade: enquanto ativa, a cura do paladino e reduzida em 25% (sem paralyze e sem bloquear magias de cura)
	skill:setParameter(CONDITION_PARAM_BUFF_HEALINGRECEIVED, 75)
	skill:setParameter(CONDITION_PARAM_BUFF_HEALINGDEALT, 75)

	player:addCondition(skill)
	combat:execute(player, variant)
	player:sendTextMessage(MESSAGE_STATUS_SMALL, "You activated Sharpshooter stance (+32% distance fighting, -25% healing).")
	return true
end

spell:name("Sharpshooter")
spell:words("utori con")
spell:group("support", "focus")
spell:vocation("paladin;true", "royal paladin;true")
spell:castSound(SOUND_EFFECT_TYPE_SPELL_SHARPSHOOTER)
spell:id(135)
spell:cooldown(2 * 1000)
spell:groupCooldown(2 * 1000)
spell:level(20)
spell:mana(250)
spell:isSelfTarget(true)
spell:isAggressive(false)
spell:isPremium(false)

spell:register()

local legacySpell = Spell("instant")
legacySpell.onCastSpell = spell.onCastSpell
legacySpell:name("Sharpshooter (Legacy)")
legacySpell:words("utito tempo san")
legacySpell:group("support", "focus")
legacySpell:vocation("paladin;true", "royal paladin;true")
legacySpell:castSound(SOUND_EFFECT_TYPE_SPELL_SHARPSHOOTER)
legacySpell:id(135)
legacySpell:cooldown(2 * 1000)
legacySpell:groupCooldown(2 * 1000)
legacySpell:level(20)
legacySpell:mana(250)
legacySpell:isSelfTarget(true)
legacySpell:isAggressive(false)
legacySpell:isPremium(false)

legacySpell:register()
