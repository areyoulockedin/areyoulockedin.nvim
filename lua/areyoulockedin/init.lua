local config = require("areyoulockedin.config")
local Job = require("plenary.job")

-- Helper: create timer
local function create_timer()
	return vim.uv and vim.uv.new_timer() or vim.loop.new_timer()
end

-- Func: Send Heartbeat Request
local function send_heartbeat(file_ext, total_time_seconds)
	if not config.session_key then
		print("AreYouLockedIn: Session key not set. Use :AYLISetSessionKey to set it.")
		return false -- Indicate failure to proceed
	end

	if total_time_seconds <= 0 then
		return true -- Nothing to send, technically success
	end

	if total_time_seconds < 10 then -- Less than 10 seconds
		return true -- Consider it success, reset local state later if needed
	end

	local time_spent_minutes = math.floor((total_time_seconds / 60) * 100) / 100 -- Round down to 2 decimal places

	local body = vim.json.encode({
		timestamp = os.date("!%Y-%m-%dT%TZ"),
		sessionKey = config.session_key,
		extension = file_ext,
		timeSpent = time_spent_minutes,
	})

	local success = false -- Flag to track outcome

	Job:new({
		command = "curl",
		args = {
			"-X",
			"POST",
			"-H",
			"Content-Type: application/json",
			"-d",
			body,
			config.BASE_URL .. config.HEARTBEAT,
		},
		-- Use on_exit_sync or manage async carefully if needed later
		on_exit = vim.schedule_wrap(function(j, return_val)
			local current_time = vim.fn.localtime()
			if return_val == 0 then
				-- SUCCESS: Update state in the config table
				config.last_heartbeat_time = current_time
				-- Reset accumulator AFTER successful send
				config.accumulated_time_seconds = 0
				-- We reset activity_chunk_start_time elsewhere (on change/focus)
				print("AreYouLockedIn: Heartbeat sent successfully.")
				success = true
			else
				-- FAILURE: Don't update state (accumulator keeps the time)
				print("AreYouLockedIn: Failed to send heartbeat. Status: " .. return_val)
				local stderr = j:stderr_result()
				if stderr and #stderr > 0 then
					print(table.concat(stderr, "\n"))
				else
					print("AreYouLockedIn: (No stderr output from curl)")
				end
				-- Keep config.accumulated_time_seconds as it was
				success = false
			end
		end),
	}):start()
	return true -- Indicate the sending process was initiated
end

-- Stops the current timer if active
local function stop_timer()
	if config.typing_timer then
		if config.typing_timer:is_active() then
			config.typing_timer:stop()
		end
		-- Ensure timer is closed to release resources
		pcall(function()
			config.typing_timer:close()
		end) -- Wrap close in pcall
		config.typing_timer = nil
	end
end

-- Calculates elapsed time in the current chunk and adds to accumulator
local function accumulate_current_chunk()
	if config.activity_chunk_start_time then
		local current_time = vim.fn.localtime()
		local elapsed = current_time - config.activity_chunk_start_time
		if elapsed > 0 then
			config.accumulated_time_seconds = config.accumulated_time_seconds + elapsed
		end
		-- Reset chunk start time as this chunk is now accounted for
		config.activity_chunk_start_time = nil
	end
end

-- Function: trigger heartbeat logic (called by timer, save, focus loss, exit)
local function trigger_heartbeat_logic()
	stop_timer()

	accumulate_current_chunk()

	local file_ext = vim.fn.expand("%:e") -- Use buffer filetype or a default
  if file_ext and file_ext ~= "" then
    send_heartbeat(file_ext, config.accumulated_time_seconds)
  end
end

-- Function: Resets and starts the inactivity timer
local function reset_inactivity_timer()
	stop_timer() -- Stop previous timer first

	-- Don't start timer if not focused
	if not config.is_focused then
		return
	end

	config.typing_timer = create_timer()
	config.typing_timer:start(
		config.HEARTBEAT_INTERVAL / 5,
		0, -- Don't repeat
		vim.schedule_wrap(function()
			-- Timer fired due to inactivity
			trigger_heartbeat_logic()
			-- Timer cleans itself up mostly, but ensure handle is nil
			config.typing_timer = nil
		end)
	)
end

-- Called on TextChanged, TextChangedI etc.
local function on_activity()
	if not config.is_focused then
		return
	end

	local current_time = vim.fn.localtime()
	local heartbeat_interval_seconds = config.HEARTBEAT_INTERVAL / 1000

	if not config.activity_chunk_start_time then
		config.activity_chunk_start_time = current_time
		-- Start the inactivity timer to catch when activity *stops*
		reset_inactivity_timer()
        -- No duration check needed yet, just started
		return -- Exit after starting the chunk and timer
	end

	local duration_seconds = current_time - config.activity_chunk_start_time

	if duration_seconds >= heartbeat_interval_seconds then
		trigger_heartbeat_logic()

		config.activity_chunk_start_time = current_time
		reset_inactivity_timer()

	else
		reset_inactivity_timer()
	end
end

-- Called on BufWritePost
local function on_save()
	-- Saving is a deliberate action, implies focus or final action
	trigger_heartbeat_logic()
end

-- Called on FocusGained
local function on_focus_gained()
	if not config.is_focused then
		config.is_focused = true
		-- Don't start timer or tracking yet, wait for actual activity (on_activity)
		-- Reset chunk start time, a new focused period begins
		config.activity_chunk_start_time = nil
	end
end

-- Called on FocusLost
local function on_focus_lost()
	if config.is_focused then
		config.is_focused = false

		-- Stop the inactivity timer as we are no longer active
		stop_timer()

		-- Accumulate time for the chunk that just ended due to focus loss
		accumulate_current_chunk()
	end
end

local M = {}

function M.set_session_key()
	vim.ui.input({
		prompt = "Enter session key: ",
		default = config.session_key or "",
	}, function(input)
		if input and input ~= "" then
			if input ~= config.session_key then
				print("AreYouLockedIn: Session key set/changed.")
				config.session_key = input
				-- Reset state completely when key changes
				config.accumulated_time_seconds = 0
				config.activity_chunk_start_time = nil
				config.last_heartbeat_time = nil
				stop_timer()
				-- Assume focused after setting key interactively
				config.is_focused = true
			else
				print("AreYouLockedIn: Session key unchanged.")
			end
		else
			print("AreYouLockedIn: Session key not set.")
			config.session_key = nil
			config.accumulated_time_seconds = 0
		end
	end)
end

function M.setup(opts)
	-- Merge user options with defaults
	config = vim.tbl_deep_extend("force", config, opts or {})

	-- Initialize state variables in the config table if they don't exist
	config.last_heartbeat_time = config.last_heartbeat_time or nil
	config.typing_timer = config.typing_timer or nil -- Timer handle
	config.activity_chunk_start_time = config.activity_chunk_start_time or nil -- Start of current active period
	config.accumulated_time_seconds = config.accumulated_time_seconds or 0 -- Time waiting to be sent
	config.is_focused = config.is_focused == nil and true or config.is_focused -- Assume focused initially if not set

	-- Define Augroups safely
	local group_name = "AreYouLockedInActivity"
	vim.api.nvim_create_augroup(group_name, { clear = true })

	-- Autocommands
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "*",
		group = group_name,
		callback = on_save,
	})

	-- Use a broader set of events to detect activity
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
		pattern = "*",
		group = group_name,
		callback = on_activity,
	})

	vim.api.nvim_create_autocmd("FocusGained", {
		pattern = "*",
		group = group_name,
		callback = on_focus_gained,
	})

	vim.api.nvim_create_autocmd("FocusLost", {
		pattern = "*",
		group = group_name,
		callback = on_focus_lost,
	})

	-- Cleanup on exit
	local cleanup_group_name = "AreYouLockedInCleanup"
	vim.api.nvim_create_augroup(cleanup_group_name, { clear = true })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		pattern = "*",
		group = cleanup_group_name,
		callback = function()
			print("AreYouLockedIn: VimLeavePre triggered.")
			-- Ensure any remaining time is accounted for and sent
			trigger_heartbeat_logic()
			-- Stop timer explicitly just in case (should be done by trigger_heartbeat_logic)
			stop_timer()
		end,
	})

	-- User Command
	vim.api.nvim_create_user_command("AYLISetSessionKey", M.set_session_key, {})

	if not config.session_key then
		print("AreYouLockedIn: Session key not set. Use :AYLISetSessionKey")
	end
end

return M
