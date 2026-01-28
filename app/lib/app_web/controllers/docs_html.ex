defmodule PrikkeWeb.DocsHTML do
  @moduledoc """
  This module contains pages rendered by DocsController.
  """
  use PrikkeWeb, :html

  embed_templates "docs_html/*"

  attr :rest, :global
  slot :inner_block, required: true

  def docs_layout(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-50">
      <div class="max-w-[800px] mx-auto px-6">
        <!-- Header -->
        <header class="py-6 border-b border-slate-200 mb-12 flex justify-between items-center">
          <a href="/" class="flex items-center gap-2.5 text-xl font-semibold text-slate-900 no-underline">
            <div class="w-4 h-4 bg-emerald-500 rounded-full"></div>
            prikke
          </a>
          <nav class="flex gap-6">
            <a href="/docs" class="text-slate-600 no-underline text-[15px] hover:text-emerald-500">Docs</a>
            <a href="/docs/api" class="text-slate-600 no-underline text-[15px] hover:text-emerald-500">API</a>
            <a href="/use-cases" class="text-slate-600 no-underline text-[15px] hover:text-emerald-500">Use Cases</a>
          </nav>
        </header>

        <!-- Content -->
        <main class="docs-content">
          {render_slot(@inner_block)}
        </main>

        <!-- Footer -->
        <footer class="mt-20 py-10 border-t border-slate-200 text-center text-slate-500 text-sm">
          <p>Prikke · Background jobs, made simple · <a href="/" class="text-slate-600 no-underline hover:text-emerald-500">Home</a></p>
        </footer>
      </div>
    </div>
    """
  end
end
