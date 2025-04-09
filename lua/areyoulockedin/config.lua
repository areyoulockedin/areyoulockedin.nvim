local default_config = {
	BASE_URL = "https://areyoulocked.in",
	HEARTBEAT = "/api/time",
	HEARTBEAT_INTERVAL = 2 * 60 * 1000, -- 2 minutes in milliseconds

	-- User specific
	session_key = nil,

	-- Internal State (should generally not be set by user)
	last_heartbeat_time = nil, -- Timestamp of last successful heartbeat
	typing_timer = nil, -- Handle for the inactivity timer
	activity_chunk_start_time = nil, -- Timestamp when current focused activity started
	accumulated_time_seconds = 0, -- Seconds accumulated since last successful heartbeat
	is_focused = true, -- Tracks if Neovim window has focus
}

return default_config
