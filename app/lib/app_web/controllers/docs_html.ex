defmodule PrikkeWeb.DocsHTML do
  @moduledoc """
  This module contains pages rendered by DocsController.
  """
  use PrikkeWeb, :html

  embed_templates "docs_html/*"

  attr :rest, :global
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def docs_layout(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-50 flex flex-col">
      <div class="max-w-[800px] mx-auto px-6 w-full flex-1">
        <.marketing_header menu_id="docs-menu-toggle" current_scope={@current_scope} />

        <!-- Content -->
        <main class="docs-content py-8">
          {render_slot(@inner_block)}
        </main>
      </div>

      <div class="max-w-[800px] mx-auto px-6 w-full">
        <.footer variant="marketing" />
      </div>
    </div>
    """
  end
end
