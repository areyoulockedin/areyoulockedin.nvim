local default_config = {
	BASE_URL = "https://areyoulocked.in",
	HEARTBEAT = "/api/time",
	HEARTBEAT_INTERVAL = 2 * 60 * 1000, -- 2 minutes in milliseconds
	session_key = nil,
	last_heartbeat_time = nil,
	typing_timer = nil,
	activity_start_time = nil,
}

return default_config
