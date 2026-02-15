// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/app"
import topbar from "../vendor/topbar"

const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.getAttribute("data-clipboard-text")
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(() => this.flash())
      } else {
        const ta = document.createElement("textarea")
        ta.value = text
        ta.style.position = "fixed"
        ta.style.left = "-9999px"
        document.body.appendChild(ta)
        ta.select()
        document.execCommand("copy")
        document.body.removeChild(ta)
        this.flash()
      }
    })
  },
  flash() {
    if (this.el.dataset.copied) return
    this.el.dataset.copied = "true"
    const icon = this.el.querySelector("span")
    const originalClass = icon ? icon.getAttribute("class") : null
    if (icon) {
      icon.setAttribute("class", originalClass.replace("hero-clipboard-document", "hero-check"))
      icon.style.color = "#10b981"
    }
    const tip = document.createElement("span")
    tip.textContent = "Copied!"
    tip.style.cssText = "position:absolute;bottom:100%;left:50%;transform:translateX(-50%);margin-bottom:6px;padding:4px 10px;background:#0f172a;color:white;font-size:12px;border-radius:6px;white-space:nowrap;pointer-events:none;z-index:50"
    this.el.style.position = "relative"
    this.el.appendChild(tip)
    setTimeout(() => {
      if (icon && originalClass) {
        icon.setAttribute("class", originalClass)
        icon.style.color = ""
      }
      tip.remove()
      delete this.el.dataset.copied
    }, 1500)
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CopyToClipboard},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Dropdown toggle
document.addEventListener("click", (e) => {
  const toggle = e.target.closest("[data-dropdown-toggle]")

  if (toggle) {
    e.preventDefault()
    const dropdown = toggle.closest("[data-dropdown]")
    const menu = dropdown.querySelector("[data-dropdown-menu]")
    // Close all other dropdowns first
    document.querySelectorAll("[data-dropdown-menu]").forEach(other => {
      if (other !== menu) other.classList.add("hidden")
    })
    menu.classList.toggle("hidden")
  } else {
    // Close all dropdowns when clicking outside
    document.querySelectorAll("[data-dropdown-menu]").forEach(menu => {
      menu.classList.add("hidden")
    })
  }
})


// Copy to clipboard for dead views (data-copy attribute)
document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-copy]")
  if (!btn) return
  const text = btn.dataset.copy
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(() => flashCopyButton(btn))
  } else {
    const ta = document.createElement("textarea")
    ta.value = text
    ta.style.position = "fixed"
    ta.style.left = "-9999px"
    document.body.appendChild(ta)
    ta.select()
    document.execCommand("copy")
    document.body.removeChild(ta)
    flashCopyButton(btn)
  }
})

function flashCopyButton(btn) {
  if (btn.dataset.copied) return
  btn.dataset.copied = "true"
  const icon = btn.querySelector("span")
  const originalClass = icon ? icon.getAttribute("class") : null
  if (icon) {
    icon.setAttribute("class", originalClass.replace("hero-clipboard-document", "hero-check"))
    icon.style.color = "#10b981"
  }
  const tip = document.createElement("span")
  tip.textContent = "Copied!"
  tip.style.cssText = "position:absolute;bottom:100%;left:50%;transform:translateX(-50%);margin-bottom:6px;padding:4px 10px;background:#0f172a;color:white;font-size:12px;border-radius:6px;white-space:nowrap;pointer-events:none;z-index:50"
  btn.appendChild(tip)
  setTimeout(() => {
    if (icon && originalClass) {
      icon.setAttribute("class", originalClass)
      icon.style.color = ""
    }
    tip.remove()
    delete btn.dataset.copied
  }, 1500)
}

// Code example tab switching (curl / Node.js SDK)
document.addEventListener("click", (e) => {
  const tab = e.target.closest("[data-tab]")
  if (!tab) return
  const group = tab.closest("[data-tab-group]")
  group.querySelectorAll("[data-tab]").forEach(t => {
    t.classList.remove("text-emerald-400", "border-emerald-400")
    t.classList.add("text-slate-500", "border-transparent")
  })
  tab.classList.add("text-emerald-400", "border-emerald-400")
  tab.classList.remove("text-slate-500", "border-transparent")
  const target = tab.dataset.tab
  group.querySelectorAll("[data-tab-content]").forEach(c => {
    c.style.display = c.dataset.tabContent === target ? "" : "none"
  })
})

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

