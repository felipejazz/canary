local savingEvent = 0

local save = TalkAction("/save")

function save.onSay(player, words, param)
	-- create log
	logCommand(player, words, param)

	if isNumber(param) then
		stopEvent(savingEvent)
		local delay = tonumber(param) * 60 * 1000
		savingEvent = addEvent(function()
			saveServer()
			SaveHirelings()
		end, delay, delay)
	else
		saveServer()
		SaveHirelings()
		local snapName = string.format("save_%s_god", os.date("%Y%m%d_%H%M%S"))
		local curlCmd = string.format("curl -s -X POST http://127.0.0.1:8085/api/snapshots/create -H 'Content-Type: application/json' -d '{\"folder\":\"sessions\",\"name\":\"%s\"}' >/dev/null 2>&1 &", snapName)
		os.execute(curlCmd)
		player:sendTextMessage(MESSAGE_ADMINISTRATOR, string.format("Server has been saved. Snapshot '%s' created.", snapName))
	end
	return true
end

save:separator(" ")
save:groupType("god")
save:register()
