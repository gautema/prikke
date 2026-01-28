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
        <main class="prose prose-slate max-w-none
          prose-headings:text-slate-900 prose-headings:font-semibold
          prose-h1:text-4xl prose-h1:mb-4
          prose-h2:text-2xl prose-h2:mt-12 prose-h2:pt-6 prose-h2:border-t prose-h2:border-slate-200
          prose-h3:text-lg prose-h3:mt-8
          prose-p:text-slate-700 prose-p:leading-relaxed
          prose-a:text-emerald-600 prose-a:no-underline hover:prose-a:underline
          prose-code:bg-slate-100 prose-code:px-1.5 prose-code:py-0.5 prose-code:rounded prose-code:text-sm prose-code:font-mono prose-code:before:content-none prose-code:after:content-none
          prose-pre:bg-slate-900 prose-pre:text-slate-100 prose-pre:rounded-lg prose-pre:p-5
          prose-table:text-sm
          prose-th:text-left prose-th:font-semibold prose-th:text-slate-600 prose-th:p-3 prose-th:border-b prose-th:border-slate-200
          prose-td:p-3 prose-td:border-b prose-td:border-slate-200
        ">
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
