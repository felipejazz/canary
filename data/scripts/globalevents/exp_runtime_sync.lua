-- Applies XP settings saved by the dashboard ("Salvar e Aplicar ao vivo") without a restart.
-- The dashboard already persists rateExp/rateUseStages/lowLevelBonusExp in config.lua and
-- the stage table in stages.lua (so the next boot keeps them) and then bumps the flag file.
-- Here we poll that tiny file and, when it changes, reload config.lua + stages.lua.

local FLAG_FILE = CORE_DIRECTORY .. "/exp_apply.flag"
local POLL_INTERVAL_MS = 5000

local function readFlag()
	local file = io.open(FLAG_FILE, "r")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	return content
end

-- Whatever is already in the file at boot was applied by that boot's config load.
local lastSeen = readFlag()

-- The XP rate shown by the client (skills/stats window) is only pushed at login
-- (creaturescripts/player/login.lua), so after a reload we resend it to everyone online.
local function refreshXpDisplay(player)
	if configManager.getBoolean(configKeys.XP_DISPLAY_MODE) then
		local baseRate = player:getFinalBaseRateExperience() * 100
		if configManager.getBoolean(configKeys.VIP_SYSTEM_ENABLED) then
			local vipBonusExp = configManager.getNumber(configKeys.VIP_BONUS_EXP)
			if vipBonusExp > 0 and player:isVip() then
				baseRate = baseRate * (1 + (math.min(vipBonusExp, 100) / 100))
			end
		end
		player:setBaseXpGain(baseRate) -- also resends the stats packet
	end
	player:getFinalLowLevelBonus()
end

local expRuntimeSync = GlobalEvent("ExpRuntimeSync")

function expRuntimeSync.onThink(interval)
	local current = readFlag()
	if not current or current == lastSeen then
		return true
	end
	lastSeen = current

	-- stages.lua defines the global experienceStages; config.lua feeds configManager.
	local ok, err = pcall(dofile, CORE_DIRECTORY .. "/stages.lua")
	if not ok then
		logger.error("[ExpRuntimeSync] failed to reload stages.lua: " .. tostring(err))
		return true
	end
	if not Game.reload(RELOAD_TYPE_CONFIG) then
		logger.error("[ExpRuntimeSync] failed to reload config.lua")
		return true
	end

	for _, player in ipairs(Game.getPlayers()) do
		if not (player.isBotPlayer and player:isBotPlayer()) then
			refreshXpDisplay(player)
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("XP rate updated: x%s.", tostring(player:getFinalBaseRateExperience())))
		end
	end

	logger.info(string.format("[ExpRuntimeSync] XP reloaded: rateExp=%s rateUseStages=%s lowLevelBonusExp=%s",
		tostring(configManager.getNumber(configKeys.RATE_EXPERIENCE)),
		tostring(configManager.getBoolean(configKeys.RATE_USE_STAGES)),
		tostring(configManager.getNumber(configKeys.LOW_LEVEL_BONUS_EXP))))
	return true
end

expRuntimeSync:interval(POLL_INTERVAL_MS)
expRuntimeSync:register()
