defmodule ArborCli.FormatHelpers do
  @moduledoc """
  Provides utility functions for formatting data for CLI output.

  This module includes helpers for formatting time, file sizes, numbers,
  durations, and agent IDs to ensure consistent presentation across the
  Arbor CLI.
  """

  @doc """
  Formats a DateTime into a human-readable "time ago" string.

  ## Examples

      iex> seconds_ago = DateTime.utc_now() |> DateTime.add(-30, :second)
      iex> ArborCli.FormatHelpers.format_time_ago(seconds_ago)
      "30 seconds ago"

      iex> minutes_ago = DateTime.utc_now() |> DateTime.add(-120, :second)
      iex> ArborCli.FormatHelpers.format_time_ago(minutes_ago)
      "2 minutes ago"

      iex> ArborCli.FormatHelpers.format_time_ago(DateTime.utc_now())
      "just now"
  """
  @spec format_time_ago(DateTime.t()) :: String.t()
  def format_time_ago(%DateTime{} = datetime) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff_seconds < 1 ->
        "just now"
      diff_seconds < 60 ->
        pluralize(diff_seconds, "second") <> " ago"
      diff_seconds < 3_600 ->
        minutes = div(diff_seconds, 60)
        pluralize(minutes, "minute") <> " ago"
      diff_seconds < 86_400 ->
        hours = div(diff_seconds, 3_600)
        pluralize(hours, "hour") <> " ago"
      diff_seconds < 2_592_000 -> # 30 days
        days = div(diff_seconds, 86_400)
        pluralize(days, "day") <> " ago"
      diff_seconds < 31_536_000 -> # 365 days
        months = div(diff_seconds, 2_592_000)
        pluralize(months, "month") <> " ago"
      true ->
        years = div(diff_seconds, 31_536_000)
        pluralize(years, "year") <> " ago"
    end
  end

  @doc """
  Formats a file size in bytes into a human-readable string (B, KB, MB, GB).

  ## Examples

      iex> ArborCli.FormatHelpers.format_file_size(123)
      "123 B"

      iex> ArborCli.FormatHelpers.format_file_size(12345)
      "12.1 KB"

      iex> ArborCli.FormatHelpers.format_file_size(12_345_678)
      "11.8 MB"

      iex> ArborCli.FormatHelpers.format_file_size(12_345_678_901)
      "11.5 GB"
  """
  @spec format_file_size(non_neg_integer()) :: String.t()
  def format_file_size(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes < 1024 ->
        "#{bytes} B"
      bytes < 1_048_576 -> # 1024^2
        "#{round_to_one_decimal(bytes / 1024)} KB"
      bytes < 1_073_741_824 -> # 1024^3
        "#{round_to_one_decimal(bytes / 1_048_576)} MB"
      true ->
        "#{round_to_one_decimal(bytes / 1_073_741_824)} GB"
    end
  end

  @doc """
  Formats a number with thousands separators.

  ## Examples

      iex> ArborCli.FormatHelpers.format_number(1234567)
      "1,234,567"

      iex> ArborCli.FormatHelpers.format_number(12345.67)
      "12,345.67"
  """
  @spec format_number(number()) :: String.t()
  def format_number(number) when is_number(number) do
    [integer_part | fractional_part] = String.split(to_string(number), ".")

    formatted_integer =
      integer_part
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.join(",")
      |> String.reverse()

    case fractional_part do
      [] -> formatted_integer
      [fractional_string] -> formatted_integer <> "." <> fractional_string
    end
  end

  @doc """
  Formats a number with a given style.

  Supported styles: `:percentage`, `:currency`, `:compact`.

  ## Examples

      iex> ArborCli.FormatHelpers.format_number(0.25, :percentage)
      "25.0%"

      iex> ArborCli.FormatHelpers.format_number(1234.56, :currency)
      "$1,234.56"

      iex> ArborCli.FormatHelpers.format_number(12345, :compact)
      "12.3K"

      iex> ArborCli.FormatHelpers.format_number(1_234_567, :compact)
      "1.2M"
  """
  @spec format_number(number(), :percentage) :: String.t()
  def format_number(number, :percentage) when is_number(number) do
    "#{round_to_one_decimal(number * 100)}%"
  end

  @spec format_number(number(), :currency) :: String.t()
  def format_number(number, :currency) when is_number(number) do
    float_number = to_float(number)

    [integer_part_str, fractional_part_str] =
      String.split(:erlang.float_to_binary(float_number, decimals: 2), ".")

    integer_part = String.to_integer(integer_part_str)

    "$#{format_number(integer_part)}.#{fractional_part_str}"
  end

  @spec format_number(integer(), :compact) :: String.t()
  def format_number(number, :compact) when is_integer(number) do
    cond do
      number < 1_000 ->
        to_string(number)
      number < 1_000_000 ->
        "#{round_to_one_decimal(number / 1_000)}K"
      number < 1_000_000_000 ->
        "#{round_to_one_decimal(number / 1_000_000)}M"
      true ->
        "#{round_to_one_decimal(number / 1_000_000_000)}B"
    end
  end

  @doc """
  Formats a duration in milliseconds into a human-readable string.

  It shows up to 3 most significant units of time for brevity.

  ## Examples

      iex> ArborCli.FormatHelpers.format_duration(123)
      "123ms"

      iex> ArborCli.FormatHelpers.format_duration(12345)
      "12s 345ms"

      iex> ArborCli.FormatHelpers.format_duration(123_456)
      "2m 3s 456ms"

      iex> ArborCli.FormatHelpers.format_duration(86_400_000)
      "1d"
  """
  @spec format_duration(non_neg_integer()) :: String.t()
  def format_duration(ms) when is_integer(ms) and ms >= 0 do
    if ms == 0, do: "0ms"

    {total_seconds, milliseconds} = div_rem(ms, 1000)
    {total_minutes, seconds} = div_rem(total_seconds, 60)
    {total_hours, minutes} = div_rem(total_minutes, 60)
    {days, hours} = div_rem(total_hours, 24)

    parts =
      [
        {days, "d"},
        {hours, "h"},
        {minutes, "m"},
        {seconds, "s"},
        {milliseconds, "ms"}
      ]
      |> Enum.filter(fn {val, _} -> val > 0 end)
      |> Enum.map(fn {val, unit} -> "#{val}#{unit}" end)

    if Enum.empty?(parts) do
      "0ms"
    else
      parts
      |> Enum.take(3)
      |> Enum.join(" ")
    end
  end

  @doc """
  Formats an agent ID for display, truncating it if it's too long.

  ## Examples

      iex> ArborCli.FormatHelpers.format_agent_id("agent-short-id")
      "agent-short-id"

      iex> ArborCli.FormatHelpers.format_agent_id("agent-a-very-long-and-unwieldy-identifier-string")
      "agent-a-very-long-and-unwieldy-..."
  """
  @spec format_agent_id(String.t()) :: String.t()
  def format_agent_id(agent_id) when is_binary(agent_id) do
    if String.length(agent_id) <= 32 do
      agent_id
    else
      String.slice(agent_id, 0, 29) <> "..."
    end
  end

  @spec format_agent_id(any()) :: String.t()
  def format_agent_id(agent_id) do
    # Handle non-binary values by converting to string first
    agent_id
    |> to_string()
    |> format_agent_id()
  end

  # Private Helpers

  @spec pluralize(integer(), String.t()) :: String.t()
  defp pluralize(1, unit), do: "1 " <> unit
  defp pluralize(count, unit), do: "#{count} #{unit}s"

  @spec round_to_one_decimal(float()) :: float()
  defp round_to_one_decimal(float) do
    (float * 10) |> Float.round() |> Kernel./(10)
  end

  @spec to_float(number()) :: float()
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n

  @spec div_rem(non_neg_integer(), pos_integer()) :: {non_neg_integer(), non_neg_integer()}
  defp div_rem(numerator, denominator) do
    {div(numerator, denominator), rem(numerator, denominator)}
  end
end
