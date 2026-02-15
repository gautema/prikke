defmodule PrikkeWeb.GuidesHTML do
  @moduledoc """
  This module contains pages rendered by GuidesController.
  """
  use PrikkeWeb, :html

  import PrikkeWeb.DocsHTML, only: [docs_layout: 1]

  embed_templates "guides_html/*"
end
