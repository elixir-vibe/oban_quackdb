defmodule Oban.QuackDB.Transaction do
  @moduledoc false

  @expected_delay 10
  @expected_retry 20

  def run(conf, fun_or_multi, opts \\ []) do
    expected_delay = Keyword.get(opts, :expected_delay, @expected_delay)
    expected_retry = Keyword.get(opts, :expected_retry, @expected_retry)

    run(conf, fun_or_multi, opts, expected_delay, expected_retry, 1)
  end

  defp run(conf, fun_or_multi, opts, expected_delay, expected_retry, attempt) do
    Oban.Repo.transaction(conf, fun_or_multi, opts)
  rescue
    error in QuackDB.Error ->
      retry? = Keyword.get(opts, :retry, true) not in [0, false]

      if error.retriable? and retry? and attempt < expected_retry do
        expected_delay
        |> Oban.Backoff.jitter()
        |> Process.sleep()

        run(conf, fun_or_multi, opts, expected_delay, expected_retry, attempt + 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
