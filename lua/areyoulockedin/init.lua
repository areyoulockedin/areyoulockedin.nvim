local config = require("areyoulockedin.config")

local Job = require("plenary.job")

local function send_heartbeat(language, time_spent_minutes)
	if not config.session_key then
		print("AreYouLockedIn: Session key not set. Use :AYLISetSessionKey to set it.")
		return
	end

	if time_spent_minutes <= 0 then
		return
	end

	local body = vim.json.encode({
		timestamp = os.date("!%Y-%m-%dT%TZ"),
		sessionKey = config.session_key,
		language = language,
		timeSpent = time_spent_minutes,
	})

	print("AreYouLockedIn: Sending heartbeat.")

	Job:new({
		command = "curl",
		args = {
			"-X",
			"POST",
			"-H",
			"Content-Type: application/json",
			"-d",
			body,
			config.BASE_URL .. config.HEARTBEAT, -- Use config values
		},
		on_exit = vim.schedule_wrap(function(j, return_val)
			local current_time = vim.fn.localtime()
			if return_val == 0 then
				-- SUCCESS: Update state in the config table
				config.last_heartbeat_time = current_time
				config.activity_start_time = current_time -- Reset for next interval
				print("AreYouLockedIn: Heartbeat sent successfully.")
			else
				-- FAILURE: Don't update state
				print("AreYouLockedIn: Failed to send heartbeat. Status: " .. return_val)
				print(table.concat(j:stderr_result(), "\n"))
				-- Keep config.activity_start_time as it was
			end
		end),
	}):start()
end

local function trigger_heartbeat()
	local language = vim.bo.filetype
	local current_time = vim.fn.localtime()
	local time_spent_seconds = 0

	-- Access state from config table
	if config.activity_start_time then
		time_spent_seconds = current_time - config.activity_start_time
	end

	local time_spent_minutes = time_spent_seconds / 60

	send_heartbeat(language, time_spent_minutes)
end

local function on_save()
	if config.typing_timer and config.typing_timer:is_active() then
		config.typing_timer:stop()
		config.typing_timer:close() -- Close might be needed depending on timer implementation details
	end
	config.typing_timer = nil -- Ensure handle is cleared in config

	trigger_heartbeat()
end

local function create_timer()
	return vim.uv and vim.uv.new_timer() or vim.loop.new_timer()
end

local function reset_inactivity_timer()
	if config.typing_timer then
		if config.typing_timer:is_active() then
			config.typing_timer:stop()
			config.typing_timer:close()
		end
		config.typing_timer = nil
	end

	config.typing_timer = create_timer()
	config.typing_timer:start(
		config.HEARTBEAT_INTERVAL,
		0,
		vim.schedule_wrap(function() -- Use config interval
			if not config.typing_timer or not config.typing_timer:is_active() then
				return
			end

			print("AreYouLockedIn: Sending heartbeat.")
			trigger_heartbeat()

			-- Clean up the timer that just fired (access via config)
			if config.typing_timer and config.typing_timer:is_active() then
				config.typing_timer:stop()
				config.typing_timer:close()
			end
			config.typing_timer = nil -- Clear handle in config
		end)
	)
end

local function on_change()
	local current_time = vim.fn.localtime()

	-- Use config for activity start time
	if not config.activity_start_time then
		config.activity_start_time = current_time
	end

	reset_inactivity_timer()
end

local M = {}

function M.set_session_key()
	vim.ui.input({
		prompt = "Enter session key: ",
		default = config.session_key or "", -- Use config value
	}, function(input)
		if input and input ~= "" then
			config.session_key = input
			print("AreYouLockedIn: Session key set.")
			-- Reset state related to the key
			config.activity_start_time = vim.fn.localtime() -- Start tracking now
			config.last_heartbeat_time = nil -- Reset last success time
		else
			print("AreYouLockedIn: Session key not set.")
		end
	end)
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts)
	-- Ensure state variables exist in the config table after merging
	config.last_heartbeat_time = config.last_heartbeat_time or nil
	config.typing_timer = config.typing_timer or nil -- Should generally start as nil anyway
	config.activity_start_time = config.activity_start_time or nil -- Will be set on first activity or key load

	-- Initialize activity start time if a key is present and it hasn't been set
	if config.session_key and not config.activity_start_time then
		config.activity_start_time = vim.fn.localtime()
	end

	-- Create Augroup
	local group = vim.api.nvim_create_augroup("AreYouLockedIn", { clear = true })

	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "*",
		group = group,
		callback = on_save,
	})

	vim.api.nvim_create_autocmd({ "TextChanged" }, {
		pattern = "*",
		group = group,
		callback = on_change,
	})

	vim.api.nvim_create_user_command("AYLISetSessionKey", M.set_session_key, {})

	print("AreYouLockedIn: Setup complete. Inactivity timeout: " .. (config.HEARTBEAT_INTERVAL / 1000) .. "s.")
	if not config.session_key then
		print("AreYouLockedIn: Session key not loaded. Use :AYLISetSessionKey")
	end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	pattern = "*",
	group = vim.api.nvim_create_augroup("AreYouLockedInCleanup", { clear = true }),
	callback = function()
		if config.typing_timer and config.typing_timer:is_active() then
			pcall(function()
				config.typing_timer:stop()
				config.typing_timer:close()
			end) -- Wrap in pcall for safety
			config.typing_timer = nil
		end
	end,
})

return M
