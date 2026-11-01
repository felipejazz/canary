-- ============================================================================
-- Bot Hunt Tester Poller
-- Polls bot_hunt_test_commands table every 1 second to execute external CLI commands
-- dispatched by `manage.py test-hunts`.
-- ============================================================================

local testPoller = GlobalEvent("BotHuntTesterCommandPoller")

function testPoller.onThink(interval)
	local res = db.storeQuery(
		"SELECT `id`, `command`, `param`, `workers` FROM `bot_hunt_test_commands` " ..
		"WHERE `status` = 'PENDING' ORDER BY `id` ASC LIMIT 1"
	)
	if not res then return true end

	local cmdId = Result.getNumber(res, "id")
	local cmd = Result.getString(res, "command")
	local param = Result.getString(res, "param") or ""
	local workers = Result.getNumber(res, "workers")
	Result.free(res)

	db.asyncQuery(string.format("UPDATE `bot_hunt_test_commands` SET `status` = 'RUNNING' WHERE `id` = %d", cmdId))

	if cmd == "start" then
		local options = {
			workers = math.max(1, math.min(20, workers or 1)),
			parallelExplicit = (workers and workers > 1)
		}

		local rawParam = param:match("^%s*(.-)%s*$") or ""

		local modeMatch = rawParam:match("mode:(%a+)")
		if modeMatch then
			options.mode = modeMatch:lower()
			rawParam = rawParam:gsub("mode:%a+", ""):match("^%s*(.-)%s*$")
		end

		if rawParam:lower():find("reset") then
			options.reset = true
			rawParam = rawParam:gsub("[Rr][Ee][Ss][Ee][Tt]", ""):match("^%s*(.-)%s*$")
		end

		if rawParam:lower():find("force") then
			options.force = true
			rawParam = rawParam:gsub("[Ff][Oo][Rr][Cc][Ee]", ""):match("^%s*(.-)%s*$")
		end

		if rawParam:lower():find("untested") then
			options.untestedOnly = true
			rawParam = rawParam:gsub("[Uu][Nn][Tt][Ee][Ss][Tt][Ee][Dd]", ""):match("^%s*(.-)%s*$")
		end

		if rawParam:lower():find("failed") then
			options.failedOnly = true
			rawParam = rawParam:gsub("[Ff][Aa][Ii][Ll][Ee][Dd]", ""):match("^%s*(.-)%s*$")
		end

		if rawParam ~= "" then
			local huntId = tonumber(rawParam)
			if huntId then
				options.huntId = huntId
			elseif rawParam:sub(1, 5):lower() == "town:" then
				options.town = rawParam:sub(6):match("^%s*(.-)%s*$")
			elseif rawParam:lower() == "all" then
				-- All hunts
			else
				options.town = rawParam
			end
		end

		local started = HuntTester.start(options)
		if not started then
			db.asyncQuery(string.format("UPDATE `bot_hunt_test_commands` SET `status` = 'COMPLETED' WHERE `id` = %d", cmdId))
		end
	elseif cmd == "stop" then
		HuntTester.stop()
		db.asyncQuery(string.format("UPDATE `bot_hunt_test_commands` SET `status` = 'COMPLETED' WHERE `id` = %d", cmdId))
	elseif cmd == "report" then
		HuntTester.generateMarkdownReport()
		db.asyncQuery(string.format("UPDATE `bot_hunt_test_commands` SET `status` = 'COMPLETED' WHERE `id` = %d", cmdId))
	elseif cmd == "reload_scripts" then
		pcall(function() dofile("data/scripts/lib/bot_system.lua") end)
		pcall(function() dofile("data/scripts/lib/bot_hunting_data.lua") end)
		pcall(function() dofile("data/scripts/lib/bot_hunt_tester.lua") end)
		if BotSystem and BotSystem.loadNpcAndKeyCatalogs then
			pcall(BotSystem.loadNpcAndKeyCatalogs)
		end
		if BotHuntData and BotHuntData.reload then
			pcall(BotHuntData.reload)
		end
		logger.info("[BotHuntTesterCommandPoller] Hot-reloaded bot_system.lua, bot_hunting_data.lua and bot_hunt_tester.lua + NPC/Key catalogs!")
		db.asyncQuery(string.format("UPDATE `bot_hunt_test_commands` SET `status` = 'COMPLETED' WHERE `id` = %d", cmdId))
	elseif cmd == "test_loop" then
		local ok, err = pcall(function()
			dofile("data/scripts/lib/bot_system.lua")
			dofile("data/scripts/talkactions/god/test_loop.lua")
			local god = Player("GOD") or Player("Tester")
			if not god then
				for _, p in ipairs(Game.getPlayers()) do
					if p:getGroup():getAccess() then god = p; break end
				end
			end
			if not god then
				god = {
					getName = function() return "SystemCLI" end,
					getGroup = function() return { getAccess = function() return true end } end,
					sendTextMessage = function(self, msgType, text) logger.info("[TestLoopCLI] " .. text) end
				}
			end
			TestLoop_Run(god, param)
		end)
		if not ok then
			logger.error("[BotHuntTesterCommandPoller] test_loop error: " .. tostring(err))
		end
		db.asyncQuery(string.format("UPDATE `bot_hunt_test_commands` SET `status` = 'COMPLETED' WHERE `id` = %d", cmdId))
	end

	return true
end

testPoller:interval(1000)
testPoller:register()
