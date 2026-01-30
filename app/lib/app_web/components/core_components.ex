defmodule PrikkeWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: PrikkeWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-4 right-4 z-50"
      {@rest}
    >
      <div class={[
        "flex items-center gap-3 w-80 sm:w-96 px-4 py-3 rounded-lg shadow-lg border text-sm",
        @kind == :info && "bg-emerald-50 border-emerald-200 text-emerald-800",
        @kind == :error && "bg-red-50 border-red-200 text-red-800"
      ]}>
        <.icon
          :if={@kind == :info}
          name="hero-check-circle"
          class={["size-5 shrink-0", "text-emerald-500"]}
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class={["size-5 shrink-0", "text-red-500"]}
        />
        <div class="flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <button type="button" class="group cursor-pointer" aria-label={gettext("close")}>
          <.icon
            name="hero-x-mark"
            class={[
              "size-5",
              @kind == :info && "text-emerald-400 group-hover:text-emerald-600",
              @kind == :error && "text-red-400 group-hover:text-red-600"
            ]}
          />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-4">
      <label class="flex items-center gap-3 cursor-pointer">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={
            @class ||
              "w-5 h-5 rounded border-slate-300 text-emerald-500 focus:ring-2 focus:ring-emerald-500 focus:ring-offset-4"
          }
          {@rest}
        />
        <span :if={@label} class="text-base text-slate-700">{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-4">
      <label>
        <span :if={@label} class="block text-base font-medium text-slate-700 mb-2">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class ||
              "w-full px-4 py-3 text-base border border-slate-300 rounded-md bg-white text-slate-900",
            "focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:ring-offset-4",
            @errors != [] && "border-red-500"
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-4">
      <label>
        <span :if={@label} class="block text-base font-medium text-slate-700 mb-2">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class ||
              "w-full px-4 py-3 text-base border border-slate-300 rounded-md text-slate-900 placeholder-slate-400",
            "focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:ring-offset-4",
            @errors != [] && "border-red-500"
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="mb-4">
      <label>
        <span :if={@label} class="block text-base font-medium text-slate-700 mb-2">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class ||
              "w-full px-4 py-3 text-base border border-slate-300 rounded-md text-slate-900 placeholder-slate-400",
            "focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:ring-offset-4",
            @errors != [] && "border-red-500"
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a modal.

  ## Examples

      <.modal id="confirm-modal">
        This is a modal.
      </.modal>

  JS commands may be passed to the `:on_cancel` to configure
  the closing/cancel event, for example:

      <.modal id="confirm" on_cancel={JS.navigate(~p"/posts")}>
        This is another modal.
      </.modal>

  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div
        id={"#{@id}-bg"}
        class="bg-slate-900/50 fixed inset-0 transition-opacity"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center">
          <div class="w-full max-w-xl p-4 sm:p-6 lg:py-8">
            <.focus_wrap
              id={"#{@id}-container"}
              phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
              class="relative hidden bg-white rounded-lg shadow-xl ring-1 ring-slate-900/10 transition"
            >
              <div class="absolute top-4 right-4">
                <button
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  type="button"
                  class="flex-none p-2 text-slate-400 hover:text-slate-500"
                  aria-label="close"
                >
                  <svg
                    class="w-5 h-5"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    stroke-width="2"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </div>
              <div id={"#{@id}-content"} class="p-6">
                {render_slot(@inner_block)}
              </div>
            </.focus_wrap>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 300,
      transition: {"transition-all ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      time: 200,
      transition: {"transition-all ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(PrikkeWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(PrikkeWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Renders a datetime in the user's local timezone.

  Uses a JavaScript hook to convert UTC to local time on the client side.

  ## Examples

      <.local_time id="created-at" datetime={@created_at} />
      <.local_time id="scheduled" datetime={@scheduled_at} format="datetime" />

  ## Formats

    * `:datetime` - "29 Jan 2026, 14:30" (default)
    * `:time` - "14:30:45"
    * `:date` - "29 Jan 2026"
    * `:full` - "29 January 2026 at 14:30"

  """
  attr :id, :string, required: true
  attr :datetime, :any, required: true, doc: "DateTime, NaiveDateTime, or nil"
  attr :format, :string, default: "datetime", values: ~w(datetime time date full)

  def local_time(%{datetime: nil} = assigns) do
    ~H"""
    <span>—</span>
    """
  end

  def local_time(assigns) do
    ~H"""
    <span
      id={@id}
      phx-hook=".LocalTime"
      data-timestamp={to_iso8601(@datetime)}
      data-format={@format}
      class="relative group/time inline-block"
    >
      <span>{format_utc_fallback(@datetime, @format)}</span>
      <span class="absolute invisible group-hover/time:visible top-full left-0 mt-1 px-2 py-1 text-xs text-white bg-slate-800 rounded whitespace-nowrap z-50 pointer-events-none">
        {format_utc_tooltip(@datetime)}
      </span>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      export default {
        mounted() {
          this.formatTime()
        },
        updated() {
          this.formatTime()
        },
        formatTime() {
          const timestamp = this.el.dataset.timestamp
          const format = this.el.dataset.format
          const date = new Date(timestamp)

          let text
          switch(format) {
            case 'time':
              text = date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
              break
            case 'date':
              text = date.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
              break
            case 'full':
              text = date.toLocaleDateString('en-GB', { day: '2-digit', month: 'long', year: 'numeric' }) +
                     ' at ' + date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', hour12: false })
              break
            default: // datetime
              text = date.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) +
                     ', ' + date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', hour12: false })
          }
          this.el.firstElementChild.textContent = text
        }
      }
    </script>
    """
  end

  @doc """
  Renders a relative time that updates live on the client.

  Shows times like "5s ago", "2m ago", "1h ago". Falls back to local datetime
  for times older than 24 hours.

  ## Examples

      <.relative_time id="exec-123" datetime={@execution.scheduled_for} />

  """
  attr :id, :string, required: true
  attr :datetime, :any, required: true, doc: "DateTime, NaiveDateTime, or nil"

  def relative_time(%{datetime: nil} = assigns) do
    ~H"""
    <span>—</span>
    """
  end

  def relative_time(assigns) do
    ~H"""
    <span
      id={@id}
      phx-hook=".RelativeTime"
      data-timestamp={to_iso8601(@datetime)}
      class="relative group/time inline-block"
    >
      <span>{format_relative_fallback(@datetime)}</span>
      <span class="absolute invisible group-hover/time:visible top-full left-0 mt-1 px-2 py-1 text-xs text-white bg-slate-800 rounded whitespace-nowrap z-50 pointer-events-none">
        {format_utc_tooltip(@datetime)}
      </span>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RelativeTime">
      export default {
        mounted() {
          this.updateTime()
          this.interval = setInterval(() => this.updateTime(), 10000)
        },
        updated() {
          this.updateTime()
        },
        destroyed() {
          clearInterval(this.interval)
        },
        updateTime() {
          const timestamp = this.el.dataset.timestamp
          const date = new Date(timestamp)
          const now = new Date()
          const diff = Math.floor((now - date) / 1000)

          let text
          if (diff < 0) {
            text = "just now"
          } else if (diff < 60) {
            text = `${diff}s ago`
          } else if (diff < 3600) {
            text = `${Math.floor(diff / 60)}m ago`
          } else if (diff < 86400) {
            text = `${Math.floor(diff / 3600)}h ago`
          } else {
            text = date.toLocaleDateString('en-GB', { day: '2-digit', month: 'short' }) +
                   ', ' + date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', hour12: false })
          }
          this.el.firstElementChild.textContent = text
        }
      }
    </script>
    """
  end

  defp to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso8601(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt) <> "Z"

  defp format_utc_tooltip(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_utc_fallback(datetime, format) do
    case format do
      "time" -> Calendar.strftime(datetime, "%H:%M:%S")
      "date" -> Calendar.strftime(datetime, "%d %b %Y")
      "full" -> Calendar.strftime(datetime, "%d %B %Y at %H:%M")
      _ -> Calendar.strftime(datetime, "%d %b %Y, %H:%M")
    end
  end

  defp format_relative_fallback(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 0 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(datetime, "%d %b, %H:%M")
    end
  end

  @doc """
  Renders the marketing header with navigation and mobile menu.

  ## Examples

      <.marketing_header />
      <.marketing_header menu_id="login-menu" current_scope={@current_scope} />
  """
  attr :menu_id, :string, default: "marketing-menu-toggle"
  attr :current_scope, :map, default: nil

  def marketing_header(assigns) do
    ~H"""
    <div class="group/menu">
      <input type="checkbox" id={@menu_id} class="hidden" />
      <header class="py-6 flex justify-between items-center">
        <a
          href="/"
          class="flex items-center gap-2.5 text-xl font-semibold text-slate-900 no-underline"
        >
          <span class="relative flex h-5 w-5 items-center justify-center">
            <span class="animate-[ping_4s_cubic-bezier(0,0,0.2,1)_infinite] absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75">
            </span>
            <span class="relative inline-flex rounded-full h-3 w-3 bg-emerald-500"></span>
          </span>
          cronly
        </a>
        <!-- Mobile menu toggle (CSS-only) -->
        <label for={@menu_id} class="sm:hidden p-2 text-slate-600 cursor-pointer">
          <span class="group-has-[:checked]/menu:hidden">
            <.icon name="hero-bars-3" class="w-6 h-6" />
          </span>
          <span class="hidden group-has-[:checked]/menu:block">
            <.icon name="hero-x-mark" class="w-6 h-6" />
          </span>
        </label>
        <!-- Desktop nav -->
        <nav class="hidden sm:flex items-center gap-6">
          <a href="/docs" class="text-slate-600 no-underline text-[15px] hover:text-emerald-500">
            Docs
          </a>
          <a href="/status" class="text-slate-600 no-underline text-[15px] hover:text-emerald-500">
            Status
          </a>
          <span class="w-px h-4 bg-slate-300"></span>
          <%= if @current_scope do %>
            <a
              href="/dashboard"
              class="text-[15px] font-medium text-white bg-emerald-500 hover:bg-emerald-600 px-4 py-2 rounded-md transition-colors no-underline"
            >
              Dashboard
            </a>
          <% else %>
            <a
              href="/users/register"
              class="text-slate-600 no-underline text-[15px] hover:text-emerald-500"
            >
              Register
            </a>
            <a
              href="/users/log-in"
              class="text-[15px] font-medium text-white bg-emerald-500 hover:bg-emerald-600 px-4 py-2 rounded-md transition-colors no-underline"
            >
              Log in
            </a>
          <% end %>
        </nav>
      </header>
      <!-- Mobile menu (overlay, CSS-only) -->
      <div class="hidden group-has-[:checked]/menu:block sm:hidden fixed inset-x-0 top-[72px] bottom-0 bg-white border-t border-slate-200 z-50 overflow-y-auto">
        <nav class="flex flex-col gap-1 px-6 py-4">
          <a
            href="/docs"
            class="block py-3 text-base text-slate-700 no-underline hover:text-emerald-500"
          >
            Docs
          </a>
          <a
            href="/status"
            class="block py-3 text-base text-slate-700 no-underline hover:text-emerald-500"
          >
            Status
          </a>
          <div class="border-t border-slate-200 pt-3 mt-2 flex flex-col gap-1">
            <%= if @current_scope do %>
              <a
                href="/dashboard"
                class="block py-3 text-base font-medium text-emerald-600 no-underline"
              >
                Dashboard
              </a>
            <% else %>
              <a
                href="/users/register"
                class="block py-3 text-base text-slate-700 no-underline hover:text-emerald-500"
              >
                Register
              </a>
              <a
                href="/users/log-in"
                class="block py-3 text-base font-medium text-emerald-600 no-underline"
              >
                Log in
              </a>
            <% end %>
          </div>
        </nav>
      </div>
    </div>
    """
  end

  @doc """
  Renders the app footer with documentation links.

  ## Examples

      <.footer />
      <.footer variant="marketing" />
  """
  attr :variant, :string, default: "app", values: ["app", "marketing"]

  def footer(assigns) do
    ~H"""
    <%= if @variant == "marketing" do %>
      <footer class="py-10 border-t border-slate-200 text-center text-slate-500 text-sm">
        <div class="flex flex-wrap justify-center gap-4 mb-3">
          <a href="/docs" class="text-slate-600 no-underline hover:text-emerald-500">Docs</a>
          <a href="/docs/api" class="text-slate-600 no-underline hover:text-emerald-500">
            API Reference
          </a>
          <a href="/status" class="text-slate-600 no-underline hover:text-emerald-500">Status</a>
          <a
            href="mailto:support@cronly.eu"
            class="text-slate-600 no-underline hover:text-emerald-500"
          >
            Contact
          </a>
        </div>
        <p class="text-slate-400">Cronly · Made in Norway</p>
      </footer>
    <% else %>
      <footer class="border-t border-slate-200 mt-12">
        <div class="max-w-4xl mx-auto px-4 py-6">
          <div class="flex flex-col sm:flex-row justify-between items-center gap-4 text-sm text-slate-500">
            <div class="flex flex-wrap justify-center gap-4 sm:gap-6">
              <a href="/docs" class="hover:text-slate-700">Docs</a>
              <a href="/docs/api" class="hover:text-slate-700">API Reference</a>
              <a href="/status" class="hover:text-slate-700">Status</a>
            </div>
            <div>
              <a href="mailto:support@cronly.eu" class="hover:text-slate-700">Contact</a>
            </div>
          </div>
        </div>
      </footer>
    <% end %>
    """
  end
end
