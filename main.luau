-- MiniMax Quota — a status line segment showing the MiniMax Token Plan quota.
--
-- Set the key once: palette › Plugins › minimax-quota › Set API key.
-- It lands in the system keychain under account `plugin.minimax-quota.api_key`.
-- Falls back to the MINIMAX_CN_API_KEY / MINIMAX_API_KEY environment variables.

local API_CN = "https://api.minimaxi.com/v1/token_plan/remains"
local API_GLOBAL = "https://www.minimax.io/v1/token_plan/remains"

local REFRESH_MS = 5 * 60 * 1000
local WALL_CLOCK_MS = 100_000_000_000 -- above this, an end_time is a timestamp, not a duration

local state = {
	text = "MiniMax —",
	icon = "md-cloud-outline",
	tone = "muted",
	fetching = false,
}

local function tone_for(usedRatio)
	if usedRatio == nil then
		return "muted"
	end
	if usedRatio >= 0.9 then
		return "error"
	elseif usedRatio >= 0.7 then
		return "warning"
	end
	return "success"
end

local function human_duration(ms)
	if ms >= 3_600_000 then
		return math.floor(ms / 3_600_000) .. "h"
	end
	return math.max(1, math.floor(ms / 60_000)) .. "m"
end

-- Milliseconds until reset. MiniMax sends `remains_time` as an actual duration,
-- so use it directly. `end_time` is a wall-clock stamp, and tern.now() is a
-- monotonic clock that cannot be differenced against the epoch, so a stamp alone
-- yields no countdown rather than a wrong one.
local function ms_until_reset(entry, durationField, endField)
	local duration = entry[durationField]
	if type(duration) == "number" and duration > 0 then
		return duration
	end
	local stamp = entry[endField]
	if type(stamp) == "number" and stamp > 0 and stamp <= WALL_CLOCK_MS then
		-- Small values are already a duration in disguise.
		return stamp
	end
	return nil
end

-- Picks the model window with the least left; that is the one the plan gates on.
local function summarize(payload)
	local entries = payload.model_remains
	if type(entries) ~= "table" or #entries == 0 then
		return nil, "no plan data"
	end

	local best, bestLeft
	for _, entry in entries do
		if type(entry) == "table" then
			-- Percent is what MiniMax actually enforces; counts are often absent.
			local percent = entry.current_interval_remaining_percent
			local remaining = nil
			if type(percent) == "number" then
				remaining = percent
			else
				local direct = entry.current_interval_remaining_count or entry.current_interval_remains_count
				if direct ~= nil then
					remaining = direct
				else
					local total = entry.current_interval_total_count
					local used = entry.current_interval_usage_count
					if type(total) == "number" and type(used) == "number" then
						remaining = total - used
					end
				end
			end
			if remaining ~= nil and (bestLeft == nil or remaining < bestLeft) then
				bestLeft = remaining
				best = { entry = entry, percent = type(percent) == "number" }
			end
		end
	end
	if best == nil then
		return nil, "no remaining quota"
	end

	local entry = best.entry
	local parts = {}
	if best.percent then
		local left = math.floor(bestLeft)
		local weekly = entry.current_weekly_remaining_percent
		if type(weekly) == "number" then
			table.insert(parts, string.format("%d%% left · week %d%%", left, math.floor(weekly)))
		else
			table.insert(parts, left .. "% left")
		end
	else
		table.insert(parts, tostring(bestLeft) .. " left")
	end

	local reset = ms_until_reset(entry, "remains_time", "end_time")
	if reset ~= nil and reset < 7 * 24 * 3_600_000 then
		table.insert(parts, "resets in " .. human_duration(reset))
	end

	return {
		text = "MiniMax " .. table.concat(parts, " · "),
		tone = tone_for(1 - bestLeft / 100),
	}, nil
end

local function show(text, toneName)
	state.text = text
	state.tone = toneName
	tern.chrome.refresh()
end

local function fail(message)
	show("MiniMax " .. message, "error")
end

-- Marks the segment busy without wiping the last known numbers, so a click
-- shows motion rather than the whole line flashing back to a placeholder.
local function mark_fetching()
	state.icon = "md-refresh"
	state.text = state.text .. " …"
	tern.chrome.refresh()
end

local function clear_fetching()
	state.icon = "md-cloud-outline"
end

local function onBody(result)
	clear_fetching()
	if result.error ~= nil then
		fail("offline")
		return
	end
	if result.status ~= 200 then
		fail("HTTP " .. result.status)
		return
	end
	local ok, payload = pcall(tern.json.decode, result.body)
	if not ok or type(payload) ~= "table" then
		fail("bad reply")
		return
	end
	local base = payload.base_resp
	if type(base) == "table" and base.status_code ~= nil and base.status_code ~= 0 then
		fail(tostring(base.status_msg or "API error"))
		return
	end
	local summary, why = summarize(payload)
	if summary == nil then
		fail(why)
		return
	end
	show(summary.text, summary.tone)
end

-- Reports the outcome when a refresh was user-triggered; silent for the timer.
-- `cx` must be the one handed to the innermost await callback: any earlier
-- WindowCx has been destroyed by the time the request comes back.
local function notify(cx)
	if cx == nil then
		return
	end
	local detail = state.text:gsub("^MiniMax ", "")
	if string.find(detail, "error", 1, true) == nil and
		string.find(detail, "offline", 1, true) == nil and
		string.find(detail, "HTTP", 1, true) == nil and
		string.find(detail, "bad reply", 1, true) == nil and
		string.find(detail, "no key", 1, true) == nil and
		string.find(detail, "no plan", 1, true) == nil and
		string.find(detail, "no remaining", 1, true) == nil then
		cx:toast("success", "MiniMax quota", detail)
		return
	end
	cx:toast("error", "MiniMax quota", detail)
end

local function poll(wantNotice)
	if state.fetching then
		return
	end
	state.fetching = true
	mark_fetching()

	tern.secrets.get("api_key"):next(function(key, err, secretsCx)
		local apiKey = key
		if err ~= nil or apiKey == nil or apiKey == "" then
			apiKey = tern.getenv("MINIMAX_CN_API_KEY") or tern.getenv("MINIMAX_API_KEY")
		end
		if apiKey == nil or apiKey == "" then
			state.fetching = false
			fail("no key — run 'Set API key'")
			-- The secrets awaitable already handed us a fresh cx; use it.
			if wantNotice then
				notify(secretsCx)
			end
			return
		end

		local options = {
			headers = { Authorization = "Bearer " .. apiKey, Accept = "application/json" },
			timeout_ms = 10_000,
		}

		tern.fetch(API_CN, options):next(function(result, _, fetchCx)
			-- A key from the wrong region authenticates nowhere; retry on the global host.
			if result.status == 401 or result.status == 403 then
				tern.fetch(API_GLOBAL, options):next(function(global_result, _, globalCx)
					state.fetching = false
					onBody(global_result)
					if wantNotice then
						notify(globalCx)
					end
				end)
				return
			end
			state.fetching = false
			onBody(result)
			if wantNotice then
				notify(fetchCx)
			end
		end)
	end)
end

local function schedule()
	-- tern.timer is one-shot, so chain it.
	tern.timer(REFRESH_MS, function()
		poll()
		schedule()
	end)
end

tern.on("window_start", function(cx)
	tern.chrome.status(function()
		-- Clicking the segment runs the refresh command.
		return { {
			text = state.text,
			icon = state.icon,
			tone = state.tone,
			command = "plugin.minimax-quota.refresh",
		} }
	end)

	tern.command({
		id = "refresh",
		title = "MiniMax Quota: Refresh now",
		icon = "md-refresh",
		run = function()
			-- Pass only the "user asked" intent; the cx to toast with is the one
			-- the fetch awaitable hands back, never this call's.
			poll(true)
		end,
	})

	tern.command({
		id = "key",
		title = "MiniMax Quota: Set API key",
		icon = "md-key-outline",
		run = function(inner)
			-- A WindowCx is valid only during the call, so every async callback
			-- uses the fresh cx it hands back rather than `inner`.
			inner:prompt({ placeholder = "MiniMax API key", icon = "md-key-outline" }):next(function(input, promptErr, promptCx)
				if promptErr ~= nil then
					promptCx:toast("error", "MiniMax key prompt failed", promptErr)
					return
				end
				if input == nil then
					promptCx:toast("info", "MiniMax key unchanged")
					return
				end
				tern.secrets.set("api_key", input):next(function(_, err, saveCx)
					if err ~= nil then
						saveCx:toast("error", "MiniMax key not saved", tostring(err))
						return
					end
					saveCx:toast("success", "MiniMax key saved")
					poll()
				end)
			end)
		end,
	})

	poll()
	schedule()
end)
