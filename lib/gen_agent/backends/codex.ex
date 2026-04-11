defmodule GenAgent.Backends.Codex do
  @moduledoc """
  `GenAgent.Backend` implementation backed by `CodexWrapper`.

  ## Why this uses `exec_json` instead of streaming

  `CodexWrapper.Exec.stream/2` and `CodexWrapper.ExecResume.stream/2`
  currently hang against `codex-cli ≥ 0.118` because the underlying
  Erlang `Port` leaves stdin open and Codex reads stdin at startup.
  See https://github.com/joshrotenberg/codex_wrapper_ex/issues/37.

  This backend calls `Exec.execute_json/2` (or
  `ExecResume.execute_json/2` for follow-up turns) which wraps
  `System.cmd`, so stdin is closed cleanly. The tradeoff is that a
  turn's events arrive all at once after the CLI exits, rather than
  progressively. That's fine for GenAgent because the prompt task
  blocks on the whole turn anyway and `handle_stream_event` still
  fires for every event in order.

  If/when the upstream streaming bug is fixed, this backend can switch
  to real streaming without any caller-visible change.

  ## Session continuation

  Codex reports its persistent thread identifier as `thread_id` in the
  first `thread.started` event of a turn, not in the terminal
  `turn.completed` event. The `EventTranslator` captures it and
  injects it into the `:result` event as `session_id`. This backend's
  `update_session/2` then records it on the session struct, and the
  next turn is dispatched via `ExecResume` with that id.

  ## Options accepted by `start_session/1`

  Config-level (forwarded to `CodexWrapper.Config.new/1`):

    * `:binary`, `:working_dir` (aliased as `:cwd`), `:env`, `:timeout`,
      `:verbose`

  Exec-level (forwarded to `CodexWrapper.Exec`):

    * `:model`, `:sandbox`, `:approval_policy`, `:full_auto`,
      `:dangerously_bypass_approvals_and_sandbox`, `:skip_git_repo_check`,
      `:ephemeral`, `:cd`, `:add_dirs`, `:search`, `:output_schema`,
      `:config_overrides`, `:enabled_features`, `:disabled_features`,
      `:images`

  Backend-only:

    * `:exec_fn` -- a 2-arity function `(prompt, session) -> {:ok,
      [%JsonLineEvent{}]} | {:error, term()}` that replaces the default
      `Exec`/`ExecResume` dispatch. Intended for tests.

  Codex has no equivalent of Claude's `--system-prompt`; if you need
  system-level instructions, pass them via `AGENTS.md` in the working
  directory or through Codex's configuration layer.
  """

  @behaviour GenAgent.Backend

  alias CodexWrapper.{Config, Exec, ExecResume, JsonLineEvent}
  alias GenAgent.Backends.Codex.EventTranslator

  @config_keys [:binary, :working_dir, :env, :timeout, :verbose]

  defstruct [
    :config,
    :exec_opts,
    :exec_fn,
    thread_id: nil
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          exec_opts: keyword(),
          exec_fn: (String.t(), t() -> {:ok, [JsonLineEvent.t()]} | {:error, term()}),
          thread_id: String.t() | nil
        }

  @impl GenAgent.Backend
  def start_session(opts) do
    {exec_fn, opts} = Keyword.pop(opts, :exec_fn, &default_exec/2)
    opts = normalize_cwd(opts)
    {config_opts, exec_opts} = Keyword.split(opts, @config_keys)
    config = Config.new(config_opts)

    {:ok,
     %__MODULE__{
       config: config,
       exec_opts: exec_opts,
       exec_fn: exec_fn
     }}
  end

  @impl GenAgent.Backend
  def prompt(%__MODULE__{} = session, prompt) when is_binary(prompt) do
    case session.exec_fn.(prompt, session) do
      {:ok, json_events} when is_list(json_events) ->
        {:ok, EventTranslator.translate(json_events), session}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exec_fn_raised, Exception.message(e)}}
  end

  @impl GenAgent.Backend
  def update_session(%__MODULE__{} = session, %{session_id: sid}) when is_binary(sid) do
    %{session | thread_id: sid}
  end

  def update_session(%__MODULE__{} = session, _data), do: session

  @impl GenAgent.Backend
  def resume_session(session_id, opts) when is_binary(session_id) do
    {:ok, session} = start_session(opts)
    {:ok, %{session | thread_id: session_id}}
  end

  @impl GenAgent.Backend
  def terminate_session(%__MODULE__{}), do: :ok

  # ---------------------------------------------------------------------------
  # Default exec_fn -- routes between Exec and ExecResume based on thread_id
  # ---------------------------------------------------------------------------

  defp default_exec(prompt, %__MODULE__{thread_id: nil} = session) do
    exec = build_exec(prompt, session.exec_opts)
    Exec.execute_json(exec, session.config)
  end

  defp default_exec(prompt, %__MODULE__{thread_id: tid} = session) when is_binary(tid) do
    resume = build_exec_resume(tid, prompt, session.exec_opts)
    ExecResume.execute_json(resume, session.config)
  end

  defp build_exec(prompt, exec_opts) do
    Enum.reduce(exec_opts, Exec.new(prompt), fn
      {:model, v}, e ->
        Exec.model(e, v)

      {:sandbox, v}, e ->
        Exec.sandbox(e, v)

      {:approval_policy, v}, e ->
        Exec.approval_policy(e, v)

      {:full_auto, true}, e ->
        Exec.full_auto(e)

      {:dangerously_bypass_approvals_and_sandbox, true}, e ->
        Exec.dangerously_bypass_approvals_and_sandbox(e)

      {:skip_git_repo_check, true}, e ->
        Exec.skip_git_repo_check(e)

      {:ephemeral, true}, e ->
        Exec.ephemeral(e)

      {:cd, v}, e ->
        Exec.cd(e, v)

      {:search, true}, e ->
        Exec.search(e)

      {:output_schema, v}, e ->
        Exec.output_schema(e, v)

      {:config_overrides, v}, e ->
        Enum.reduce(v, e, &Exec.config(&2, &1))

      {:enabled_features, v}, e ->
        Enum.reduce(v, e, &Exec.enable(&2, &1))

      {:disabled_features, v}, e ->
        Enum.reduce(v, e, &Exec.disable(&2, &1))

      {:add_dirs, v}, e ->
        Enum.reduce(v, e, &Exec.add_dir(&2, &1))

      {:images, v}, e ->
        Enum.reduce(v, e, &Exec.image(&2, &1))

      _other, e ->
        e
    end)
  end

  defp build_exec_resume(thread_id, prompt, exec_opts) do
    resume =
      ExecResume.new()
      |> ExecResume.session_id(thread_id)
      |> ExecResume.prompt(prompt)

    Enum.reduce(exec_opts, resume, fn
      {:model, v}, r ->
        ExecResume.model(r, v)

      {:full_auto, true}, r ->
        ExecResume.full_auto(r)

      {:dangerously_bypass_approvals_and_sandbox, true}, r ->
        ExecResume.dangerously_bypass_approvals_and_sandbox(r)

      {:skip_git_repo_check, true}, r ->
        ExecResume.skip_git_repo_check(r)

      {:ephemeral, true}, r ->
        ExecResume.ephemeral(r)

      _other, r ->
        r
    end)
  end

  defp normalize_cwd(opts) do
    case Keyword.pop(opts, :cwd) do
      {nil, rest} -> rest
      {cwd, rest} -> Keyword.put_new(rest, :working_dir, cwd)
    end
  end
end
