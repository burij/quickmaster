import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# elixir-desktop: the window loads the endpoint, so the server is
# always enabled (no PHX_SERVER gate like a web deploy would need).
if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :tischlampe, TischlampeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/tischlampe_web/router\.ex$",
        ~r"lib/tischlampe_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  # local desktop app (loopback only + Desktop.Auth):
  # fixed default is fine, no env vars needed at runtime
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      "tischlampe-local-default-secret-7f3c9a1e5d2b4f6a8c0e1b3d5f7a9c2e"

  port = String.to_integer(System.get_env("PORT", "4000"))

  config :tischlampe, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :tischlampe, TischlampeWeb.Endpoint,
    server: true,
    # elixir-desktop: the window loads this local URL (desktop app, no TLS)
    url: [host: "localhost", port: port],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :tischlampe, TischlampeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :tischlampe, TischlampeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
