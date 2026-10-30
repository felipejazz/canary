dofile(CORE_DIRECTORY .. "/libs/systems/blessing.lua")

local adventurerBlessingLogin = CreatureEvent("AdventurerBlessingLogin")

function adventurerBlessingLogin.onLogin(player)
	-- Desativado para jogadores humanos: jogadores devem comprar blessings normalmente via NPCs ou !bless.
	-- Bots recebem e mantêm suas bênçãos através de BotSystem.applyBotBlessings(player).
	if not player or player:isRemoved() then
		return true
	end

	local isBot = player.isBotPlayer and player:isBotPlayer()
	if not isBot then
		return true
	end

	return Blessings.doAdventurerBlessing(player)
end

adventurerBlessingLogin:register()
