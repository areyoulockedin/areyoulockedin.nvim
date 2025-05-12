-- init.lua
local config_module = require("areyoulockedin.config") -- Original module name for require
local Job = require("plenary.job")

-- Module to be returned, will hold the active config and public functions
local M = {}
M.config = {} -- This will be populated in M.setup()

-- Helper: create timer
local function create_timer()
	return vim.uv and vim.uv.new_timer() or vim.loop.new_timer()
end

-- Helper: Process heartbeat result (used by both sync and async sends)
local function process_heartbeat_result(job_object_or_nil, return_val, is_job_object_provided)
	local current_time = vim.fn.localtime()
	if return_val == 0 then
		M.config._last_heartbeat_time = current_time
		M.config._accumulated_time_seconds = 0 -- Reset accumulator ONLY on successful send
		print("AreYouLockedIn: Heartbeat sent successfully.")
		return true
	else
		print("AreYouLockedIn: Failed to send heartbeat.")
		if is_job_object_provided and job_object_or_nil then
			local stderr = job_object_or_nil:stderr_result()
			if stderr and #stderr > 0 then
				for _, line in ipairs(stderr) do
					print(line)
				end
			end
		end
		return false
	end
end

-- Func: Send Heartbeat Request
local function send_heartbeat(file_ext, total_time_seconds, is_sync_call)
	if not M.config.session_key then
		print("AreYouLockedIn: Session key not set. Use :AYLISetSessionKey to set it.")
		return false
	end

	if total_time_seconds <= 0 then
		return true -- Nothing to send
	end

	if total_time_seconds < M.config._min_seconds_to_send then
		return true
	end

	local time_spent_minutes = math.floor((total_time_seconds / 60) * 100) / 100

	local body_table = {
		timestamp = os.date("!%Y-%m-%dT%TZ"),
		sessionKey = M.config.session_key,
		extension = file_ext,
		timeSpent = time_spent_minutes,
	}
	local body_json = vim.json.encode(body_table)

	local job_params = {
		command = "curl",
		args = {
			"-X",
			"POST",
			"-H",
			"Content-Type: application/json",
			"--connect-timeout",
			"5", -- Max time in seconds to connect
			"--max-time",
			"10", -- Max total time in seconds for the operation
			"-d",
			body_json,
			M.config.BASE_URL .. M.config.HEARTBEAT_API_ENDPOINT,
		},
	}

	if is_sync_call then
		print("AreYouLockedIn: Sending heartbeat.")
		local job = Job:new(job_params)
		-- job:sync() returns {stdout lines}, exit_code
		local _, return_val = job:sync(15000) -- Wait up to 15 seconds (connect + max-time + buffer)

		if return_val == nil then
			return false
		end
		return process_heartbeat_result(job, return_val, true)
	else
		Job:new(vim.tbl_extend("force", job_params, {
			on_exit = vim.schedule_wrap(function(j, rv)
				process_heartbeat_result(j, rv, true)
			end),
		})):start()
		return true
	end
end

-- Stops the current timer if active
local function stop_timer()
	if M.config._typing_timer then
		local timer_to_stop = M.config._typing_timer
		M.config._typing_timer = nil -- Nil out first to prevent re-entry issues

		if timer_to_stop:is_active() then
			timer_to_stop:stop()
		end
		-- pcall to ensure no error if timer is already closed or in an odd state
		pcall(function()
			if not timer_to_stop:is_closed() then
				timer_to_stop:close()
			end
		end)
	end
end

-- Calculates elapsed time in the current chunk and adds to accumulator
local function accumulate_current_chunk()
	if M.config._activity_chunk_start_time then
		local current_time = vim.fn.localtime()
		local elapsed = current_time - M.config._activity_chunk_start_time
		if elapsed > 0 then
			M.config._accumulated_time_seconds = M.config._accumulated_time_seconds + elapsed
		end
		M.config._activity_chunk_start_time = nil
	end
end

-- Function: trigger heartbeat logic (called by timer, save, interval, or exit)
local function trigger_heartbeat_logic(is_exit_call)
	is_exit_call = is_exit_call or false
	stop_timer()
	accumulate_current_chunk()

	local file_ext = vim.fn.expand("%:e")
	if not file_ext or file_ext == "" then
		local current_buf_name = vim.api.nvim_buf_get_name(0)
		if current_buf_name and current_buf_name ~= "" then
			local match = string.match(current_buf_name, "%.([^.]+)$")
			if match then
				file_ext = match
			end
		end
	end

	if file_ext and file_ext ~= "" then
		file_ext = file_ext:lower()
		send_heartbeat(file_ext, M.config._accumulated_time_seconds, is_exit_call)
	end
end

-- Function: Resets and starts the inactivity timer
local function reset_inactivity_timer()
	stop_timer()

	M.config._typing_timer = create_timer()
	if not M.config._typing_timer then
		return
	end

	M.config._typing_timer:start(
		M.config.INACTIVITY_TIMEOUT_MS,
		0, -- Don't repeat
		vim.schedule_wrap(function()
			trigger_heartbeat_logic(false)
		end)
	)
end

-- Called on TextChanged, CursorMoved, etc.
local function on_activity()
	if not M.config._is_focused then
		return -- Only track activity if Neovim has focus
	end

	local current_time = vim.fn.localtime()

	if not M.config._activity_chunk_start_time then
		M.config._activity_chunk_start_time = current_time
	end
	reset_inactivity_timer() -- Always reset inactivity timer on any qualifying activity

	-- Check if total time (accumulated + current ongoing chunk) meets HEARTBEAT_INTERVAL_MS
	local current_chunk_duration_seconds = current_time - (M.config._activity_chunk_start_time or current_time)
	local total_tracked_time_seconds = M.config._accumulated_time_seconds + current_chunk_duration_seconds

	if total_tracked_time_seconds >= (M.config.HEARTBEAT_INTERVAL_MS / 1000) then
		trigger_heartbeat_logic(false)
	end
end

-- Called on BufWritePost
local function on_save()
	trigger_heartbeat_logic(false)
end

-- Called on FocusGained
local function on_focus_gained()
	if not M.config._is_focused then
		M.config._is_focused = true
		-- If no activity chunk was in progress (e.g., inactivity timer fired while unfocused), start a new one.
		if not M.config._activity_chunk_start_time then
			M.config._activity_chunk_start_time = vim.fn.localtime()
		end
		-- Restart inactivity timer as we are now (presumably) active and focused.
		reset_inactivity_timer()
	end
end

-- Called on FocusLost
local function on_focus_lost()
	if M.config._is_focused then
		M.config._is_focused = false
	end
end

function M.set_session_key()
	vim.ui.input({
		prompt = "Enter session key: ",
		default = M.config.session_key or "",
	}, function(input)
		if input and input ~= "" then
			if input ~= M.config.session_key then
				print("AreYouLockedIn: Session key set/changed.")
				M.config.session_key = input
				-- Reset state completely when key changes
				M.config._accumulated_time_seconds = 0
				M.config._activity_chunk_start_time = nil
				M.config._last_heartbeat_time = nil
				stop_timer()

				-- Re-initialize activity tracking based on current focus state
				M.config._is_focused = vim.fn.hasFocus()
				if M.config._is_focused then
					M.config._activity_chunk_start_time = vim.fn.localtime()
					reset_inactivity_timer()
				end
				print("AreYouLockedIn: Activity tracking re-initialized.")
			else
				print("AreYouLockedIn: Session key unchanged.")
			end
		else
			print("AreYouLockedIn: Session key not set (cleared).")
			M.config.session_key = nil
			M.config._accumulated_time_seconds = 0
			M.config._activity_chunk_start_time = nil
			stop_timer()
		end
	end)
end

function M.setup(user_opts)
	-- Initialize M.config by deep extending defaults, then user options
	local default_copy = vim.deepcopy(config_module) -- Use deepcopy for safety
	M.config = vim.tbl_deep_extend("force", default_copy, user_opts or {})

	-- Ensure internal state variables are correctly initialized after merge
	M.config._typing_timer = nil -- Always nil at fresh setup
	M.config._activity_chunk_start_time = nil -- Always nil at fresh setup
	M.config._accumulated_time_seconds = M.config._accumulated_time_seconds or 0 -- Keep if user somehow set it
	M.config._is_focused = true -- Initialize with actual current focus state

	if M.config._is_focused then
		M.config._activity_chunk_start_time = vim.fn.localtime()
		reset_inactivity_timer()
	end
	print("AreYouLockedIn: Initialized.")

	local group_name = "AreYouLockedInActivity"
	vim.api.nvim_create_augroup(group_name, { clear = true })

	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "*",
		group = group_name,
		callback = on_save,
	})

	-- Broader set of events to detect activity including normal mode movements and pauses
	vim.api.nvim_create_autocmd(
		{ "TextChanged", "TextChangedI", "TextChangedP", "CursorMoved", "CursorHold", "CursorHoldI" },
		{ pattern = "*", group = group_name, callback = on_activity }
	)

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

	local cleanup_group_name = "AreYouLockedInCleanup"
	vim.api.nvim_create_augroup(cleanup_group_name, { clear = true })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		pattern = "*",
		group = cleanup_group_name,
		callback = function()
			trigger_heartbeat_logic(true) -- true for synchronous call
		end,
	})

	vim.api.nvim_create_user_command("AYLISetSessionKey", M.set_session_key, {})

	if not M.config.session_key then
		print("AreYouLockedIn: Session key not set. Use :AYLISetSessionKey to set it.")
	end
	print("AreYouLockedIn: Setup complete.")
end

return M
