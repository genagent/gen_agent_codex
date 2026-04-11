defmodule GenAgent.Backends.CodexIntegrationTest do
  @moduledoc """
  End-to-end tests that drive a real `GenAgent` process with the
  Codex backend, but with Codex execution stubbed out via an injected
  `exec_fn`. Exercises the full state-machine path:
  `GenAgent.start_agent/2` -> `GenAgent.ask/2` -> `Codex.prompt/2` ->
  fake exec_fn -> `EventTranslator` -> back into the state machine and
  delivered as a `GenAgent.Response`.

  The live-CLI integration test lives in `codex_live_test.exs`.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias CodexWrapper.JsonLineEvent

  defmodule CodexAgent do
    use GenAgent

    defmodule State do
      defstruct responses: []
    end

    @impl true
    def init_agent(opts) do
      backend_opts =
        Keyword.take(opts, [
          :exec_fn,
          :sandbox,
          :skip_git_repo_check,
          :model,
          :cwd,
          :working_dir
        ])

      {:ok, backend_opts, %State{}}
    end

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      {:noreply, %{state | responses: state.responses ++ [response]}}
    end
  end

  defp event(type, data), do: %JsonLineEvent{event_type: type, data: data, raw: ""}

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp start_codex_agent(exec_fn, extra_opts \\ []) do
    name = unique_name("codex")

    {:ok, _pid} =
      GenAgent.start_agent(
        CodexAgent,
        [
          name: name,
          backend: GenAgent.Backends.Codex,
          exec_fn: exec_fn
        ] ++ extra_opts
      )

    on_exit(fn ->
      case GenAgent.whereis(name) do
        nil -> :ok
        _ -> GenAgent.stop(name)
      end
    end)

    name
  end

  describe "round trip through GenAgent.ask/2" do
    test "assembles a Response with text from agent_message items" do
      exec_fn = fn _prompt, _session ->
        {:ok,
         [
           event("thread.started", %{"thread_id" => "thread-101"}),
           event("turn.started", %{}),
           event("item.completed", %{
             "item" => %{"type" => "agent_message", "text" => "pong"}
           }),
           event("turn.completed", %{
             "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
           })
         ]}
      end

      name = start_codex_agent(exec_fn)

      assert {:ok, response} = GenAgent.ask(name, "ping")
      assert response.text == "pong"
      assert response.session_id == "thread-101"
      assert Enum.map(response.events, & &1.kind) == [:text, :usage, :result]
      assert response.usage == %{input_tokens: 10, output_tokens: 2}
    end

    test "threads thread_id across multiple turns" do
      test_pid = self()

      exec_fn = fn prompt, session ->
        send(test_pid, {:exec_call, prompt, session.thread_id})

        {:ok,
         [
           event("thread.started", %{"thread_id" => "thread-persist"}),
           event("item.completed", %{
             "item" => %{"type" => "agent_message", "text" => "ack #{prompt}"}
           }),
           event("turn.completed", %{})
         ]}
      end

      name = start_codex_agent(exec_fn)

      {:ok, _} = GenAgent.ask(name, "turn 1")
      assert_receive {:exec_call, "turn 1", nil}

      {:ok, _} = GenAgent.ask(name, "turn 2")
      assert_receive {:exec_call, "turn 2", "thread-persist"}

      {:ok, _} = GenAgent.ask(name, "turn 3")
      assert_receive {:exec_call, "turn 3", "thread-persist"}
    end

    test "delivers :no_terminal_event when turn.completed is missing" do
      exec_fn = fn _prompt, _session ->
        {:ok,
         [
           event("thread.started", %{"thread_id" => "t"}),
           event("item.completed", %{
             "item" => %{"type" => "agent_message", "text" => "partial"}
           })
         ]}
      end

      name = start_codex_agent(exec_fn)

      assert {:error, :no_terminal_event} = GenAgent.ask(name, "go")
    end

    test "delivers error when the exec_fn returns {:error, reason}" do
      exec_fn = fn _prompt, _session -> {:error, :codex_missing} end

      name = start_codex_agent(exec_fn)

      assert {:error, :codex_missing} = GenAgent.ask(name, "hello")
    end

    test "delivers a terminal :error event as the error reason" do
      exec_fn = fn _prompt, _session ->
        {:ok, [event("turn.failed", %{"error" => "sandbox violation"})]}
      end

      name = start_codex_agent(exec_fn)

      assert {:error, "sandbox violation"} = GenAgent.ask(name, "ouch")
    end
  end
end
