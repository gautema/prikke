defmodule PrikkeWeb.CronBuilder do
  @moduledoc """
  Visual cron expression builder component.

  Provides a simple mode with presets and dropdowns, and an advanced mode
  with a raw text input. Both modes show a live preview of the schedule.
  """
  use Phoenix.Component

  import PrikkeWeb.CoreComponents

  alias Prikke.Cron

  @presets [
    {"Every minute", "every_minute"},
    {"Every 5 minutes", "every_5_minutes"},
    {"Every 15 minutes", "every_15_minutes"},
    {"Every 30 minutes", "every_30_minutes"},
    {"Every hour", "every_hour"},
    {"Daily", "daily"},
    {"Weekly", "weekly"},
    {"Monthly", "monthly"}
  ]

  @weekdays [
    {"Mon", "1"},
    {"Tue", "2"},
    {"Wed", "3"},
    {"Thu", "4"},
    {"Fri", "5"},
    {"Sat", "6"},
    {"Sun", "0"}
  ]

  attr :form, :any, required: true
  attr :cron_mode, :atom, required: true
  attr :cron_preset, :string, required: true
  attr :cron_minute, :string, required: true
  attr :cron_hour, :string, required: true
  attr :cron_weekdays, :list, required: true
  attr :cron_day_of_month, :string, required: true

  def cron_builder(assigns) do
    assigns =
      assigns
      |> assign(:presets, @presets)
      |> assign(:weekdays, @weekdays)
      |> assign(:hours, Enum.map(0..23, fn h -> {String.pad_leading("#{h}", 2, "0"), "#{h}"} end))
      |> assign(:minutes, Enum.map(0..59, fn m -> {String.pad_leading("#{m}", 2, "0"), "#{m}"} end))
      |> assign(:days_of_month, Enum.map(1..31, fn d -> {"#{d}", "#{d}"} end))
      |> assign(:cron_expression, current_cron_expression(assigns))
      |> assign(:cron_description, current_cron_description(assigns))

    ~H"""
    <div>
      <label class="block text-sm font-medium text-slate-700 mb-2">
        Cron Expression
      </label>

      <%!-- Mode toggle --%>
      <div class="flex gap-1 mb-4 bg-slate-100 rounded-lg p-1 w-fit">
        <button
          type="button"
          phx-click="set_cron_mode"
          phx-value-mode="simple"
          class={[
            "px-3 py-1.5 text-sm font-medium rounded-md transition-colors",
            @cron_mode == :simple && "bg-white text-slate-900 shadow-sm",
            @cron_mode != :simple && "text-slate-500 hover:text-slate-700"
          ]}
        >
          Simple
        </button>
        <button
          type="button"
          phx-click="set_cron_mode"
          phx-value-mode="advanced"
          class={[
            "px-3 py-1.5 text-sm font-medium rounded-md transition-colors",
            @cron_mode == :advanced && "bg-white text-slate-900 shadow-sm",
            @cron_mode != :advanced && "text-slate-500 hover:text-slate-700"
          ]}
        >
          Advanced
        </button>
      </div>

      <%= if @cron_mode == :simple do %>
        <%!-- Simple mode --%>
        <div class="space-y-4">
          <%!-- Preset selector --%>
          <div>
            <label class="block text-xs font-medium text-slate-500 mb-1 uppercase tracking-wide">
              Frequency
            </label>
            <div class="grid grid-cols-4 gap-2">
              <%= for {label, value} <- @presets do %>
                <button
                  type="button"
                  phx-click="set_cron_preset"
                  phx-value-preset={value}
                  class={[
                    "px-3 py-2 text-sm font-medium rounded-lg border transition-all",
                    @cron_preset == value && "bg-emerald-50 border-emerald-300 text-emerald-700",
                    @cron_preset != value && "bg-white border-slate-200 text-slate-600 hover:border-slate-300 hover:bg-slate-50"
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>
          </div>

          <%!-- Time picker (for daily/weekly/monthly) --%>
          <%= if @cron_preset in ["daily", "weekly", "monthly"] do %>
            <div>
              <label class="block text-xs font-medium text-slate-500 mb-1 uppercase tracking-wide">
                Time (UTC)
              </label>
              <div class="flex items-center gap-2">
                <select
                  phx-change="set_cron_hour"
                  name="cron_hour"
                  id="cron-builder-hour"
                  class="w-20 px-3 py-2 border border-slate-200 rounded-lg text-sm font-mono text-slate-900 bg-white focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                >
                  <%= for {label, value} <- @hours do %>
                    <option value={value} selected={@cron_hour == value}>{label}</option>
                  <% end %>
                </select>
                <span class="text-slate-400 font-bold">:</span>
                <select
                  phx-change="set_cron_minute"
                  name="cron_minute"
                  id="cron-builder-minute"
                  class="w-20 px-3 py-2 border border-slate-200 rounded-lg text-sm font-mono text-slate-900 bg-white focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                >
                  <%= for {label, value} <- @minutes do %>
                    <option value={value} selected={@cron_minute == value}>{label}</option>
                  <% end %>
                </select>
              </div>
            </div>
          <% end %>

          <%!-- Weekday picker (for weekly) --%>
          <%= if @cron_preset == "weekly" do %>
            <div>
              <label class="block text-xs font-medium text-slate-500 mb-1 uppercase tracking-wide">
                Days
              </label>
              <div class="flex gap-2">
                <%= for {label, value} <- @weekdays do %>
                  <button
                    type="button"
                    phx-click="toggle_weekday"
                    phx-value-day={value}
                    class={[
                      "w-11 h-11 text-sm font-medium rounded-full border transition-all",
                      value in @cron_weekdays && "bg-emerald-600 border-emerald-600 text-white",
                      value not in @cron_weekdays && "bg-white border-slate-200 text-slate-600 hover:border-slate-300"
                    ]}
                  >
                    {label}
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Day of month picker (for monthly) --%>
          <%= if @cron_preset == "monthly" do %>
            <div>
              <label class="block text-xs font-medium text-slate-500 mb-1 uppercase tracking-wide">
                Day of month
              </label>
              <select
                phx-change="set_cron_day_of_month"
                name="cron_day_of_month"
                id="cron-builder-day"
                class="w-20 px-3 py-2 border border-slate-200 rounded-lg text-sm font-mono text-slate-900 bg-white focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
              >
                <%= for {label, value} <- @days_of_month do %>
                  <option value={value} selected={@cron_day_of_month == value}>{label}</option>
                <% end %>
              </select>
            </div>
          <% end %>
        </div>

        <%!-- Hidden input to sync the computed expression with the form --%>
        <input type="hidden" name={@form[:cron_expression].name} value={@cron_expression} />
      <% else %>
        <%!-- Advanced mode: raw text input --%>
        <.input
          field={@form[:cron_expression]}
          type="text"
          placeholder="0 * * * *"
          class="w-full px-4 py-3 font-mono text-base bg-white/70 border border-white/50 rounded-md text-slate-900 placeholder-slate-400"
        />
        <p class="text-sm text-slate-500 mt-2">
          Format: <code class="bg-slate-100 px-1.5 py-0.5 rounded text-slate-700 font-mono">minute hour day month weekday</code>
        </p>
      <% end %>

      <%!-- Preview (always visible) --%>
      <div class="mt-3 flex items-center gap-3 px-3 py-2.5 bg-slate-50 rounded-lg border border-slate-100">
        <.icon name="hero-clock" class="w-4 h-4 text-slate-400 flex-shrink-0" />
        <div class="flex items-center gap-2 min-w-0">
          <span class="text-sm text-slate-700 font-medium">{@cron_description}</span>
          <code class="text-xs font-mono text-slate-400 bg-slate-100 px-1.5 py-0.5 rounded">{@cron_expression}</code>
        </div>
      </div>
    </div>
    """
  end

  defp current_cron_expression(assigns) do
    if assigns.cron_mode == :simple do
      Cron.compute_cron(
        assigns.cron_preset,
        assigns.cron_minute,
        assigns.cron_hour,
        assigns.cron_weekdays,
        assigns.cron_day_of_month
      )
    else
      assigns.form[:cron_expression].value || "0 * * * *"
    end
  end

  defp current_cron_description(assigns) do
    expr = current_cron_expression(assigns)

    if expr && expr != "" do
      Cron.describe(expr)
    else
      "No schedule set"
    end
  end
end
