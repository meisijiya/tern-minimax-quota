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
	-- Outcome of the last refresh, recorded explicitly: the toast must not
	-- have to infer success from the rendered text.
	lastOk = false,
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

-- Every terminal outcome passes through show(), so this is where the busy
-- icon is cleared: no error path can leave the segment spinning for good.
local function clear_fetching()
	state.icon = "md-cloud-outline"
end

-- `ok` is an explicit argument rather than something derived from the tone or
-- the text: the server's own message can read like anything, and the toast
-- has to report what happened, not how the sentence looks.
local function show(text, toneName, ok)
	state.text = text
	state.tone = toneName
	state.lastOk = ok == true
	clear_fetching()
	tern.chrome.refresh()
end

local function fail(message)
	show("MiniMax " .. message, "error", false)
end

-- Marks the segment busy without wiping the last known numbers, so a click
-- shows motion rather than the whole line flashing back to a placeholder.
local function mark_fetching()
	state.icon = "md-refresh"
	state.text = state.text .. " …"
	tern.chrome.refresh()
end

local function onBody(result)
	-- The awaitable hands over `T?`: a response that never arrived arrives as
	-- nil, and indexing it would throw inside the await callback.
	if result == nil then
		fail("offline")
		return
	end
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
	show(summary.text, summary.tone, true)
end

-- A toast can raise "userdata has been destructed" when the window half went
-- away between the await and the toast. A failed toast must not take the
-- plugin down with it, so it is swallowed; the log keeps the evidence.
local function toast(cx, level, title, sub)
	if cx == nil then
		return
	end
	local ok, err = pcall(function()
		cx:toast(level, title, sub)
	end)
	if not ok then
		tern.log.warn("minimax-quota: toast failed", tostring(err))
	end
end

-- Reports the outcome when a refresh was user-triggered; silent for the timer.
-- The verdict comes from `state.lastOk`, written by show(): the server's own
-- message ("invalid api key") says nothing about success, and guessing from
-- the text turned such a failure into a green toast.
local function notify(cx)
	if cx == nil then
		return
	end
	local detail = state.text:gsub("^MiniMax ", "")
	local level = "success"
	if not state.lastOk then
		level = "error"
	end
	toast(cx, level, "MiniMax quota", detail)
end

-- `wantNotice` asks for a toast about the outcome; `cmdCx` is the cx of the
-- command that asked, valid only while that command runs. It is used for the
-- immediate "already refreshing" answer, never for the outcome toast: by the
-- time the request comes back, that cx is gone.
local function poll(wantNotice, cmdCx)
	if state.fetching then
		-- A click during a request in flight used to be swallowed silently:
		-- no toast, no movement, and the segment looked frozen. The segment
		-- already carries the in-flight marker, so the toast only has to say
		-- that a refresh is under way.
		--
		-- The click path does deliver a cx, so no text-only fallback is
		-- needed: the segment's `command` is the action
		-- `plugin.minimax-quota.refresh`, which dispatches this very command
		-- and hands it the window cx. That cx is alive for the length of the
		-- call, and the toast below happens inside it.
		if wantNotice then
			toast(cmdCx, "info", "MiniMax quota", "refreshing…")
		end
		return
	end
	state.fetching = true
	mark_fetching()

	-- Every exit from the request path goes through settle(), and settle
	-- clears the busy flag before it does anything else. A stuck flag is
	-- fatal: every later poll returns early, so the segment stays frozen and
	-- every click is swallowed until the window is reloaded.
	local settled = false
	local function settle(result, cx)
		if settled then
			return
		end
		settled = true
		state.fetching = false
		local ok, err = pcall(onBody, result)
		if not ok then
			tern.log.warn("minimax-quota: the response could not be read", tostring(err))
			fail("bad reply")
		end
		if wantNotice then
			notify(cx)
		end
	end

	-- The same discipline for the paths that never reach the API at all.
	local function abandon(message, cx)
		if settled then
			return
		end
		settled = true
		state.fetching = false
		fail(message)
		if wantNotice then
			notify(cx)
		end
	end

	-- The keychain read is under pcall for the same reason as the request: a
	-- raise here would leave the busy flag set and the segment frozen for
	-- good, with nothing to tell the user why. This one is still inside the
	-- command's call, so cmdCx is alive and can carry the outcome.
	local readKey = pcall(function()
		tern.secrets.get("api_key"):next(function(key, err, secretsCx)
			-- The callback body is guarded as well: a raise inside an await
			-- callback ends that callback and nothing else, so the busy flag
			-- would stay set and the segment would freeze.
			local ok = pcall(function()
				local apiKey = key
				if err ~= nil or apiKey == nil or apiKey == "" then
					apiKey = tern.getenv("MINIMAX_CN_API_KEY") or tern.getenv("MINIMAX_API_KEY")
				end
				if apiKey == nil or apiKey == "" then
					-- The secrets awaitable already handed us a fresh cx; use it.
					abandon("no key — run 'Set API key'", secretsCx)
					return
				end

				local options = {
					headers = { Authorization = "Bearer " .. apiKey, Accept = "application/json" },
					timeout_ms = 10_000,
				}

				-- tern.fetch raises on a malformed URL or header, and a key with
				-- a newline in it makes a malformed header. A raise inside an
				-- await callback kills the callback before it can clear the
				-- busy flag, so the request is made under pcall and every
				-- failure ends in settle.
				local requested = pcall(function()
					tern.fetch(API_CN, options):next(function(result, _, fetchCx)
						-- `result` is `FetchResult?`: a request that produced no
						-- response at all arrives as nil.
						if result ~= nil and (result.status == 401 or result.status == 403) then
							-- A key from the wrong region authenticates nowhere; retry
							-- on the global host. The busy flag stays set until that
							-- request answers.
							local retried = pcall(function()
								tern.fetch(API_GLOBAL, options):next(function(global_result, _, globalCx)
									settle(global_result, globalCx)
								end)
							end)
							if not retried then
								settle(nil, fetchCx)
							end
							return
						end
						settle(result, fetchCx)
					end)
				end)
				if not requested then
					settle(nil, secretsCx)
				end
			end)
			if not ok then
				settle(nil, secretsCx)
			end
		end)
	end)
	if not readKey then
		settle(nil, cmdCx)
	end
end

local function schedule()
	-- tern.timer is one-shot, so chain it.
	tern.timer(REFRESH_MS, function()
		poll()
		schedule()
	end)
end

-- Registered at entry load, not under tern.on("window_start"): window_start is
-- dispatched before this plugin's window half has loaded, so a handler
-- registered there never ran and neither the segment nor the palette commands
-- appeared. Registering at entry load also survives a reload, which re-runs
-- the entry.
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
	run = function(cmdCx)
		-- The cx to toast the outcome with is the one the fetch awaitable
		-- hands back, never this call's; this one is only good for the
		-- immediate answer to a click that arrives while a fetch is running.
		poll(true, cmdCx)
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

-- One poll chain per instance of this module: a second chain would double
-- every request it schedules. The guard only covers one execution of this
-- entry — a reload re-runs the entry and gets a fresh `started`, and the
-- previous chain's timer can outlive it — so a reload can leave two chains
-- running. Suppressing that would need a lease in tern.kv, but tern.kv is
-- shared by every window, so a lease taken in one window would silence the
-- segment in all the others. One extra request per interval is the cheaper
-- of the two mistakes.
local started = false

local function startPolling()
	if started then
		return
	end
	started = true
	-- The first poll is deferred by one tick. It reads the keychain and
	-- redraws the chrome, and the entry-load hook has a 50 ms budget: over
	-- it, the whole entry fails to load, and the segment and the commands
	-- vanish with nothing on screen to say why. A timer callback also has
	-- the chrome.refresh() call site the API allows.
	tern.timer(1, function()
		poll()
	end)
	-- The 5-minute chain is only registered here, not run: tern.timer just
	-- schedules, so this costs nothing against the load budget.
	schedule()
end

startPolling()
