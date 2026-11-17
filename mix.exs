defmodule Quickmaster.MixProject do
  use Mix.Project

  def project do
    [
      app: :quickmaster,
      version: File.read!("VERSION") |> String.trim(),
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: Mix.env() == :dev && [Phoenix.CodeReloader] || []
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Quickmaster.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:desktop, github: "elixir-desktop/desktop"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end

defmodule Mix.Tasks.Quickmaster.Cli do
  use Mix.Task

  @shortdoc "Control Quickmaster via CLI"

  @moduledoc """
  Quickmaster CLI commands:

    mix quickmaster.cli load <path>          # Load audio file
    mix quickmaster.cli set <param> <value>  # Set parameter
    mix quickmaster.cli get <param>          # Get parameter
    mix quickmaster.cli params               # Show all parameters
    mix quickmaster.cli toggle-pregain       # Toggle pregain
    mix quickmaster.cli preview [source]     # Play preview (original|master)
    mix quickmaster.cli stop-preview         # Stop preview
    mix quickmaster.cli render <path>        # Render to file
    mix quickmaster.cli status               # Show session status
    mix quickmaster.cli reset                # Reset to defaults
    mix quickmaster.cli wait-ready           # Wait until mastering complete
    mix quickmaster.cli test <path>          # Run full test sequence
  """

  def run(args) do
    Mix.Task.run("app.start", [])
    require Logger
    Logger.configure(level: :warn)

    # Ensure SessionSupervisor is running and start session for window_id
    ensure_session_supervisor()
    case Quickmaster.SessionSupervisor.start_session(1) do
      {:ok, _pid} -> :ok
      {:error, :already_started} -> :ok
      {:error, reason} ->
        Mix.shell().error("Failed to start session: #{inspect(reason)}")
        System.halt(1)
    end

    {parsed_args, window_id} = parse_args_with_window(args)

    case parsed_args do
      ["load", path] ->
        run_cli(fn -> Quickmaster.CLI.load_file(path, window_id) end)
      ["set", param, value] ->
        run_cli(fn -> Quickmaster.CLI.set_param(param, parse_value(value), window_id) end)
      ["get", param] ->
        run_cli(fn -> Quickmaster.CLI.get_param(param, window_id) end)
      ["params"] ->
        run_cli(fn -> Quickmaster.CLI.get_params(window_id) end)
      ["toggle-pregain"] ->
        run_cli(fn -> Quickmaster.CLI.toggle_pregain(window_id) end)
      ["preview" | rest] ->
        source = if rest == [], do: :master, else: String.to_atom(hd(rest))
        run_cli(fn -> Quickmaster.CLI.preview(source, window_id) end)
      ["stop-preview"] ->
        run_cli(fn -> Quickmaster.CLI.stop_preview(window_id) end)
      ["render", path] ->
        run_cli(fn -> Quickmaster.CLI.render(path, window_id) end)
      ["status"] ->
        run_cli(fn -> Quickmaster.CLI.status(window_id) end)
      ["reset"] ->
        run_cli(fn -> Quickmaster.CLI.reset(window_id) end)
      ["wait-ready"] ->
        run_cli(fn -> Quickmaster.CLI.wait_until_ready(window_id) end)
      ["test", path] ->
        run_cli(fn -> Quickmaster.CLI.test_sequence(path, window_id) end)
      _ ->
        Mix.shell().error("Usage: mix quickmaster.cli <command> [args...]")
        Mix.shell().error("Run 'mix help quickmaster.cli' for details")
        System.halt(1)
    end
  end

  defp parse_args_with_window(args) do
    case args do
      ["--window", window_id | rest] ->
        {rest, String.to_integer(window_id)}
      ["-w", window_id | rest] ->
        {rest, String.to_integer(window_id)}
      _ ->
        {args, 1}
    end
  end

  defp run_cli(fun) do
    case fun.() do
      {:ok, result} ->
        IO.puts(inspect(result, pretty: true))
        System.halt(0)
      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
        System.halt(1)
    end
  end

  defp parse_value(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error ->
        case v do
          "true" -> true
          "false" -> false
          _ -> v
        end
    end
  end

  defp ensure_session_supervisor do
    unless Process.whereis(Quickmaster.SessionSupervisor) do
      Quickmaster.SessionSupervisor.start_link()
    end
    {:ok, _pid} = Quickmaster.SessionSupervisor.start_session(1)
  end
end
