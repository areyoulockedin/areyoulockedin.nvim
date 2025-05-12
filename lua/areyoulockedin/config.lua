-- config.lua
local default_config = {
	BASE_URL = "https://areyoulocked.in",
	HEARTBEAT_API_ENDPOINT = "/api/time",
	HEARTBEAT_INTERVAL_MS = 5 * 60 * 1000,
	INACTIVITY_TIMEOUT_MS = 0.5 * 60 * 1000,

	-- User specific
	session_key = nil,

	-- Internal State (should generally not be set by user, prefixed with underscore)
	_last_heartbeat_time = nil,
	_typing_timer = nil,
	_activity_chunk_start_time = nil,
	_accumulated_time_seconds = 0,
	_is_focused = true,
	_min_seconds_to_send = 10,
}

return default_config
