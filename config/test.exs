import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :quickmaster, QuickmasterWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "1EXUHFi6OomGOnfRN4ireK6oRyh+ga7Vo3/SdojOPCIhvE3uIGUUMWMnqPGy+Dvr",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Resolve external audio tools at boot so tests can find them on PATH.
config :quickmaster,
  ffmpeg: System.find_executable("ffmpeg") || "ffmpeg",
  ffprobe: System.find_executable("ffprobe") || "ffprobe",
  mpv: System.find_executable("mpv") || "mpv"

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
