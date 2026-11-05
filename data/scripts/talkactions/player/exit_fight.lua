-- TalkAction: /exit_fight
-- Ends the "in fight" state so the player can log out right away.
-- Dropping the INFIGHT condition also clears the PZ lock (Player::onEndCondition),
-- unless it comes from a recent PvP kill/skull, which stays on purpose.

local function onSayExitFight(player, words, param)
	local removed = false
	while player:getCondition(CONDITION_INFIGHT, CONDITIONID_DEFAULT) do
		player:removeCondition(CONDITION_INFIGHT, CONDITIONID_DEFAULT)
		removed = true
	end

	if not player:isPzLocked() then
		player:getPosition():sendMagicEffect(CONST_ME_MAGIC_BLUE)
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, removed and "You are no longer in a fight. You can log out now." or "You are not in a fight.")
	else
		player:sendCancelMessage("You are still PZ-locked (recent player kill); you cannot log out yet.")
	end
	return true
end

local exitFight = TalkAction("/exit_fight", "!exit_fight")
exitFight.onSay = onSayExitFight
exitFight:separator(" ")
exitFight:groupType("normal")
exitFight:register()
