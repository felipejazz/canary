-- Save/clean schedule published for the dashboard: data/save_status.json
-- Fields (unix seconds): lastSave, nextSave (interval save), nextDailySave, lastMapClean, nextMapClean.
-- Values survive `/reload scripts` because the file is read back when this lib loads.

SaveStatus = SaveStatus or {}

local STATUS_FILE = CORE_DIRECTORY .. "/save_status.json"
local FIELDS = { "lastSave", "nextSave", "nextDailySave", "lastMapClean", "nextMapClean", "saveIntervalSec" }

local function load()
	local state = {}
	local file = io.open(STATUS_FILE, "r")
	if file then
		local content = file:read("*a")
		file:close()
		for _, name in ipairs(FIELDS) do
			local value = content:match('"' .. name .. '"%s*:%s*(%d+)')
			if value then
				state[name] = tonumber(value)
			end
		end
	end
	return state
end

SaveStatus.state = SaveStatus.state or load()

local function write()
	local parts = {}
	for _, name in ipairs(FIELDS) do
		if SaveStatus.state[name] then
			parts[#parts + 1] = string.format('"%s":%d', name, SaveStatus.state[name])
		end
	end
	local file = io.open(STATUS_FILE, "w")
	if file then
		file:write("{" .. table.concat(parts, ",") .. "}")
		file:close()
	end
end

function SaveStatus.set(values)
	for name, value in pairs(values) do
		SaveStatus.state[name] = math.floor(value)
	end
	write()
end

-- Next os.time() at which one of the "HH:MM:SS" times of day happens.
function SaveStatus.nextOccurrence(timesOfDay)
	local now = os.time()
	local date = os.date("*t", now)
	local best
	for _, text in ipairs(timesOfDay) do
		local h, m, s = text:match("(%d+):(%d+):?(%d*)")
		for dayOffset = 0, 1 do
			local candidate = os.time({ year = date.year, month = date.month, day = date.day + dayOffset, hour = tonumber(h), min = tonumber(m), sec = tonumber(s) or 0 })
			if candidate > now and (not best or candidate < best) then
				best = candidate
				break
			end
		end
	end
	return best
end

-- Any Lua-side saveServer() (reload, daily save, interval save, ...) updates "last save".
if not SaveStatus.baseSaveServer then
	SaveStatus.baseSaveServer = saveServer
end
function saveServer(...)
	local result = SaveStatus.baseSaveServer(...)
	SaveStatus.set({ lastSave = os.time() })
	return result
end
