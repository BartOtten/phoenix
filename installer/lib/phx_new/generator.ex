defmodule Phx.New.Generator do
  @moduledoc false
  import Mix.Generator
  alias Phx.New.{Project}

  @phoenix Path.expand("../..", __DIR__)
  @phoenix_version Version.parse!(Mix.Project.config()[:version])

  @callback prepare_project(Project.t()) :: Project.t()
  @callback generate(Project.t()) :: Project.t()

  defmacro __using__(_env) do
    quote do
      @behaviour unquote(__MODULE__)
      import Mix.Generator
      import unquote(__MODULE__)
      Module.register_attribute(__MODULE__, :templates, accumulate: true)
      @before_compile unquote(__MODULE__)
    end
  end

  defmacro __before_compile__(env) do
    root = Path.expand("../../templates", __DIR__)

    templates_ast =
      for {name, mappings} <- Module.get_attribute(env.module, :templates) do
        for {format, _proj_location, files} <- mappings,
            format != :keep,
            {source, _target} <- files,
            source = to_string(source) do
          path = Path.join(root, source)

          if format in [:config, :prod_config, :eex] do
            compiled = EEx.compile_file(path)

            quote do
              @external_resource unquote(path)
              @file unquote(path)
              def render(unquote(name), unquote(source), var!(assigns))
                  when is_list(var!(assigns)) do
                var!(maybe_heex_attr_gettext) = &unquote(__MODULE__).maybe_heex_attr_gettext/2
                _ = var!(maybe_heex_attr_gettext)
                var!(maybe_eex_gettext) = &unquote(__MODULE__).maybe_eex_gettext/2
                _ = var!(maybe_eex_gettext)
                unquote(compiled)
              end
            end
          else
            quote do
              @external_resource unquote(path)
              def render(unquote(name), unquote(source), _assigns), do: unquote(File.read!(path))
            end
          end
        end
      end

    quote do
      unquote(templates_ast)
      def template_files(name), do: Keyword.fetch!(@templates, name)
    end
  end

  defmacro template(name, mappings) do
    quote do
      @templates {unquote(name), unquote(mappings)}
    end
  end

  def copy_from(%Project{} = project, mod, name) when is_atom(name) do
    mapping = mod.template_files(name)

    for {format, project_location, files} <- mapping,
        {source, target_path} <- files,
        source = to_string(source) do
      target = Project.join_path(project, project_location, target_path)

      case format do
        :keep ->
          File.mkdir_p!(target)

        :text ->
          create_file(target, mod.render(name, source, project.binding))

        :config ->
          contents = mod.render(name, source, project.binding)
          config_inject(Path.dirname(target), Path.basename(target), contents)

        :prod_config ->
          contents = mod.render(name, source, project.binding)
          prod_only_config_inject(Path.dirname(target), Path.basename(target), contents)

        :eex ->
          contents = mod.render(name, source, project.binding)
          create_file(target, contents)
      end
    end
  end

  def config_inject(path, file, to_inject) do
    file = Path.join(path, file)

    contents =
      case File.read(file) do
        {:ok, bin} -> bin
        {:error, _} -> "import Config\n"
      end

    case :binary.split(contents, "import Config") do
      [left, right] ->
        write_formatted!(file, [left, to_inject, right])

      [_] ->
        Mix.raise(~s[Could not find "import Config" in #{inspect(file)}])
    end
  end

  def prod_only_config_inject(path, file, to_inject) do
    file = Path.join(path, file)

    contents =
      case File.read(file) do
        {:ok, bin} ->
          bin

        {:error, _} ->
          """
          import Config

          if config_env() == :prod do
          end
          """
      end

    case :binary.split(contents, "if config_env() == :prod do") do
      [left, right] ->
        write_formatted!(file, [left, "if config_env() == :prod do\n", to_inject, right])

      [_] ->
        Mix.raise(~s[Could not find "if config_env() == :prod do" in #{inspect(file)}])
    end
  end

  defp write_formatted!(file, contents) do
    formatted = contents |> IO.iodata_to_binary() |> Code.format_string!()
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, [formatted, ?\n])
  end

  def inject_umbrella_config_defaults(project) do
    unless File.exists?(Project.join_path(project, :project, "config/dev.exs")) do
      path = Project.join_path(project, :project, "config/config.exs")

      extra =
        Phx.New.Umbrella.render(:new, "phx_umbrella/config/extra_config.exs", project.binding)

      File.write(path, [File.read!(path), extra])
    end
  end

  def in_umbrella?(app_path) do
    umbrella = Path.expand(Path.join([app_path, "..", ".."]))
    mix_path = Path.join(umbrella, "mix.exs")
    apps_path = Path.join(umbrella, "apps")

    File.exists?(mix_path) && File.exists?(apps_path)
  end

  def put_binding(%Project{opts: opts} = project) do
    db = Keyword.get(opts, :database, "postgres")
    web_adapter = Keyword.get(opts, :adapter, "bandit")
    ecto = Keyword.get(opts, :ecto, true)
    html = Keyword.get(opts, :html, true)
    live = html && Keyword.get(opts, :live, true)
    dashboard = Keyword.get(opts, :dashboard, true)
    gettext = Keyword.get(opts, :gettext, true)
    assets = Keyword.get(opts, :assets, true)
    esbuild = Keyword.get(opts, :esbuild, assets)
    tailwind = Keyword.get(opts, :tailwind, assets)
    mailer = Keyword.get(opts, :mailer, true)
    dev = Keyword.get(opts, :dev, false)
    from_elixir_install = Keyword.get(opts, :from_elixir_install, false)
    phoenix_path = phoenix_path(project, dev, false)
    phoenix_path_umbrella_root = phoenix_path(project, dev, true)

    # detect if we're inside a docker env, but if we're in github actions,
    # we want to treat it like regular env for end-user testing purposes
    inside_docker_env? =
      Keyword.get_lazy(opts, :inside_docker_env, fn ->
        if System.get_env("PHX_CI") do
          false
        else
          File.exists?("/.dockerenv")
        end
      end)

    # We lowercase the database name because according to the
    # SQL spec, they are case insensitive unless quoted, which
    # means creating a database like FoO is the same as foo in
    # some storages.
    {adapter_app, adapter_module, adapter_config} =
      get_ecto_adapter(db, String.downcase(project.app), project.app_mod)

    {web_adapter_app, web_adapter_vsn, web_adapter_module, web_adapter_docs} =
      get_web_adapter(web_adapter)

    pubsub_server = get_pubsub_server(project.app_mod)

    adapter_config =
      case Keyword.fetch(opts, :binary_id) do
        {:ok, value} -> Keyword.put_new(adapter_config, :binary_id, value)
        :error -> adapter_config
      end

    binding = [
      app_name: project.app,
      app_module: inspect(project.app_mod),
      root_app_name: project.root_app,
      root_app_module: inspect(project.root_mod),
      lib_web_name: project.lib_web_name,
      web_app_name: project.web_app,
      endpoint_module: inspect(Module.concat(project.web_namespace, Endpoint)),
      web_namespace: inspect(project.web_namespace),
      phoenix_dep: phoenix_dep(phoenix_path),
      phoenix_dep_umbrella_root: phoenix_dep(phoenix_path_umbrella_root),
      phoenix_js_path: phoenix_js_path(phoenix_path),
      phoenix_version: @phoenix_version,
      pubsub_server: pubsub_server,
      secret_key_base_dev: random_string(64),
      secret_key_base_test: random_string(64),
      signing_salt: random_string(8),
      lv_signing_salt: random_string(8),
      in_umbrella: project.in_umbrella?,
      asset_builders: Enum.filter([tailwind && :tailwind, esbuild && :esbuild], & &1),
      javascript: esbuild,
      css: tailwind,
      mailer: mailer,
      ecto: ecto,
      html: html,
      live: live,
      live_comment: if(live, do: nil, else: "// "),
      dashboard: dashboard,
      gettext: gettext,
      adapter_app: adapter_app,
      adapter_module: adapter_module,
      adapter_config: adapter_config,
      web_adapter_app: web_adapter_app,
      web_adapter_module: web_adapter_module,
      web_adapter_vsn: web_adapter_vsn,
      web_adapter_docs: web_adapter_docs,
      generators: nil_if_empty(project.generators ++ adapter_generators(adapter_config)),
      namespaced?: namespaced?(project),
      dev: dev,
      from_elixir_install: from_elixir_install,
      elixir_install_otp_bin_path: from_elixir_install && elixir_install_otp_bin_path(),
      elixir_install_bin_path: from_elixir_install && elixir_install_bin_path(),
      inside_docker_env?: inside_docker_env?
    ]

    %{project | binding: binding}
  end

  def elixir_install_otp_bin_path do
    "erl"
    |> System.find_executable()
    |> Path.split()
    |> Enum.drop(-1)
    |> Path.join()
    |> Path.relative_to(System.user_home())
  end

  def elixir_install_bin_path do
    "elixir"
    |> System.find_executable()
    |> Path.split()
    |> Enum.drop(-1)
    |> Path.join()
    |> Path.relative_to(System.user_home())
  end

  defp namespaced?(project) do
    Macro.camelize(project.app) != inspect(project.app_mod)
  end

  def gen_ecto_config(%Project{project_path: project_path, binding: binding}) do
    adapter_config = binding[:adapter_config]

    config_inject(project_path, "config/dev.exs", """
    import Config

    # Configure your database
    config :#{binding[:app_name]}, #{binding[:app_module]}.Repo#{kw_to_config(adapter_config[:dev])}
    """)

    config_inject(project_path, "config/test.exs", """
    import Config

    # Configure your database
    #
    # The MIX_TEST_PARTITION environment variable can be used
    # to provide built-in test partitioning in CI environment.
    # Run `mix help test` for more information.
    config :#{binding[:app_name]}, #{binding[:app_module]}.Repo#{kw_to_config(adapter_config[:test])}
    """)

    prod_only_config_inject(project_path, "config/runtime.exs", """
    #{adapter_config[:prod_variables]}

    config :#{binding[:app_name]}, #{binding[:app_module]}.Repo,
      #{adapter_config[:prod_config]}
    """)
  end

  defp get_pubsub_server(module) do
    module
    |> Module.split()
    |> hd()
    |> Module.concat(PubSub)
  end

  defp get_ecto_adapter("mssql", app, module) do
    {:tds, Ecto.Adapters.Tds, socket_db_config(app, module, "sa", "some!Password")}
  end

  defp get_ecto_adapter("mysql", app, module) do
    {:myxql, Ecto.Adapters.MyXQL, socket_db_config(app, module, "root", "")}
  end

  defp get_ecto_adapter("postgres", app, module) do
    {:postgrex, Ecto.Adapters.Postgres, socket_db_config(app, module, "postgres", "postgres")}
  end

  defp get_ecto_adapter("sqlite3", app, module) do
    {:ecto_sqlite3, Ecto.Adapters.SQLite3, fs_db_config(app, module)}
  end

  defp get_ecto_adapter(db, _app, _mod) do
    Mix.raise("Unknown database #{inspect(db)}")
  end

  defp get_web_adapter("cowboy"),
    do:
      {:plug_cowboy, "~> 2.7", Phoenix.Endpoint.Cowboy2Adapter,
       "https://hexdocs.pm/plug_cowboy/Plug.Cowboy.html"}

  defp get_web_adapter("bandit"),
    do:
      {:bandit, "~> 1.5", Bandit.PhoenixAdapter,
       "https://hexdocs.pm/bandit/Bandit.html#t:options/0"}

  defp get_web_adapter(other), do: Mix.raise("Unknown web adapter #{inspect(other)}")

  defp fs_db_config(app, module) do
    [
      dev: [
        database: {:literal, ~s|Path.expand("../#{app}_dev.db", __DIR__)|},
        pool_size: 5,
        stacktrace: true,
        show_sensitive_data_on_connection_error: true
      ],
      test: [
        database: {:literal, ~s|Path.expand("../#{app}_test.db", __DIR__)|},
        pool_size: 5,
        pool: Ecto.Adapters.SQL.Sandbox
      ],
      test_setup_all: "Ecto.Adapters.SQL.Sandbox.mode(#{inspect(module)}.Repo, :manual)",
      test_setup: """
          pid = Ecto.Adapters.SQL.Sandbox.start_owner!(#{inspect(module)}.Repo, shared: not tags[:async])
          on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)\
      """,
      prod_variables: """
      database_path =
        System.get_env("DATABASE_PATH") ||
          raise \"""
          environment variable DATABASE_PATH is missing.
          For example: /etc/#{app}/#{app}.db
          \"""
      """,
      prod_config: """
      database: database_path,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
      """
    ]
  end

  defp socket_db_config(app, module, user, pass) do
    [
      dev: [
        username: user,
        password: pass,
        hostname: "localhost",
        database: "#{app}_dev",
        stacktrace: true,
        show_sensitive_data_on_connection_error: true,
        pool_size: 10
      ],
      test: [
        username: user,
        password: pass,
        hostname: "localhost",
        database: {:literal, ~s|"#{app}_test\#{System.get_env("MIX_TEST_PARTITION")}"|},
        pool: Ecto.Adapters.SQL.Sandbox,
        pool_size: {:literal, ~s|System.schedulers_online() * 2|}
      ],
      test_setup_all: "Ecto.Adapters.SQL.Sandbox.mode(#{inspect(module)}.Repo, :manual)",
      test_setup: """
          pid = Ecto.Adapters.SQL.Sandbox.start_owner!(#{inspect(module)}.Repo, shared: not tags[:async])
          on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)\
      """,
      prod_variables: """
      database_url =
        System.get_env("DATABASE_URL") ||
          raise \"""
          environment variable DATABASE_URL is missing.
          For example: ecto://USER:PASS@HOST/DATABASE
          \"""

      maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

      """,
      prod_config: """
      # ssl: true,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      # For machines with several cores, consider starting multiple pools of `pool_size`
      # pool_count: 4,
      socket_options: maybe_ipv6
      """
    ]
  end

  defp kw_to_config(kw) do
    Enum.map(kw, fn
      {k, {:literal, v}} -> ",\n  #{k}: #{v}"
      {k, v} -> ",\n  #{k}: #{inspect(v)}"
    end)
  end

  defp adapter_generators(adapter_config) do
    adapter_config
    |> Keyword.take([:binary_id, :migration, :sample_binary_id])
    |> Enum.filter(fn {_, value} -> not is_nil(value) end)
  end

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(other), do: other

  defp phoenix_path(%Project{} = project, true = _dev, umbrella_root?) do
    absolute = Path.expand(project.project_path)
    relative = Path.relative_to(absolute, @phoenix)

    if absolute == relative do
      Mix.raise("--dev projects must be generated inside Phoenix directory")
    end

    project
    |> phoenix_path_prefix(umbrella_root?)
    |> Path.join(relative)
    |> Path.split()
    |> Enum.map(fn _ -> ".." end)
    |> Path.join()
  end

  defp phoenix_path(%Project{}, false = _dev, _umbrella_root?) do
    "deps/phoenix"
  end

  defp phoenix_path_prefix(%Project{in_umbrella?: false}, _), do: ".."
  defp phoenix_path_prefix(%Project{in_umbrella?: true}, true = _umbrella_root?), do: ".."
  defp phoenix_path_prefix(%Project{in_umbrella?: true}, false = _umbrella_root?), do: "../../../"

  case @phoenix_version do
    %Version{pre: "dev"} ->
      defp phoenix_dep("deps/phoenix") do
        ~s[{:phoenix, github: "phoenixframework/phoenix", override: true}]
      end

    %Version{pre: ["rc", _]} ->
      defp phoenix_dep("deps/phoenix") do
        ~s[{:phoenix, "~> #{unquote(to_string(@phoenix_version))}", override: true}]
      end

    %Version{} ->
      defp phoenix_dep("deps/phoenix") do
        ~s[{:phoenix, "~> #{unquote(to_string(@phoenix_version))}"}]
      end
  end

  defp phoenix_dep(path),
    do: ~s[{:phoenix, path: #{inspect(path)}, override: true}]

  defp phoenix_js_path("deps/phoenix"), do: "phoenix"
  defp phoenix_js_path(path), do: "../../#{path}/"

  defp random_string(length) do
    :crypto.strong_rand_bytes(length) |> Base.encode64(padding: false) |> binary_part(0, length)
  end

  # In the context of a HEEx attribute value, transforms a given message into a
  # dynamic `gettext` call or a fixed-value string attribute, depending on the
  # `gettext?` parameter.
  #
  # ## Examples
  #
  #     iex> ~s|<tag attr=#{maybe_heex_attr_gettext("Hello", true)} />|
  #     ~S|<tag attr={gettext("Hello")} />|
  #
  #     iex> ~s|<tag attr=#{maybe_heex_attr_gettext("Hello", false)} />|
  #     ~S|<tag attr="Hello" />|
  def maybe_heex_attr_gettext(message, gettext?) do
    if gettext? do
      ~s|{gettext(#{inspect(message)})}|
    else
      inspect(message)
    end
  end

  # In the context of an EEx template, transforms a given message into a dynamic
  # `gettext` call or the message as is, depending on the `gettext?` parameter.
  #
  # ## Examples
  #
  #     iex> ~s|<tag>#{maybe_eex_gettext("Hello", true)}</tag>|
  #     ~S|<tag>{gettext("Hello")}</tag>|
  #
  #     iex> ~s|<tag>#{maybe_eex_gettext("Hello", false)}</tag>|
  #     ~S|<tag>Hello</tag>|
  def maybe_eex_gettext(message, gettext?) do
    if gettext? do
      ~s|{gettext(#{inspect(message)})}|
    else
      message
    end
  end
end
