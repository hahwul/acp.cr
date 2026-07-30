# AGENTS.md - AI Agent Instructions for the acp.cr Documentation Site

This document is for AI agents editing the acp.cr documentation site under `docs/`.

## Project Overview

This is the documentation companion to [acp.cr](https://github.com/hahwul/acp.cr), a Crystal implementation of the Agent Client Protocol (ACP). The site is a static site built with [Hwaro](https://github.com/hahwul/hwaro) (Crinja/Jinja2 templates).

It shares a single canonical design system with the docs sites of the sibling libraries (acp.cr, caido.cr, cvss.cr, cwe.cr, epss.cr, fm.cr, kev.cr, purl.cr, sarif.cr, spdx.cr, vex.cr, zap.cr): `templates/` (except the two slot partials), `static/css/style.css`, `static/js/search.js`, and `static/fonts/` are byte-identical across all of them. If you change one of those files here, port the change to every sibling site.

## Hwaro Usage

Run from inside `docs/`:

| Command | Description |
|---------|-------------|
| `hwaro build` | Build the site to `public/` |
| `hwaro serve` | Local dev server with live reload (port 3000) |
| `hwaro doctor` | Sanity-check config and content |

## Directory Structure

```
docs/
├── config.toml            # Site configuration (incl. [og.auto_image] brand colors)
├── content/               # Markdown content (user-guide/, api-reference/ + index.md)
├── templates/
│   ├── header.html        # <head>, no-FOUC theme script, css link
│   ├── footer.html        # footer, search.js, theme-toggle + mobile-drawer scripts
│   ├── page.html          # page body + prev/next nav
│   ├── section.html       # section body + "In This Section" cards
│   ├── 404.html
│   ├── taxonomy.html / taxonomy_term.html
│   ├── partials/
│   │   ├── nav.html       # top bar: brand, section links, search, theme, GitHub
│   │   ├── sidebar.html   # DYNAMIC sidebar (loops site.sections, weight-sorted)
│   │   ├── search.html    # command-K search overlay
│   │   ├── brand.html     # per-site slot: sidebar logo (empty by default)
│   │   └── icons.html     # per-site slot: favicons (empty by default)
│   └── shortcodes/alert.html
└── static/
    ├── css/style.css      # design tokens + all component styles
    ├── js/search.js       # search modal logic
    └── fonts/             # Geist + Geist Mono (variable woff2, self-hosted)
```

## Design System (do not regress these)

- **Theming:** every color is a `light-dark()` token in `:root`. The theme toggle pins a scheme via `data-theme` on `<html>`; auto follows the OS. Never hardcode a color in a component rule - add or reuse a token.
- **Syntax highlighting** is server-side (Tartrazine, hljs-compatible classes) colored by the `--code-*` tokens in `style.css`. Do **not** re-add `{{ highlight_css }}` to `header.html` - the CDN theme would fight the tokens.
- **Typography:** Geist (sans) and Geist Mono, self-hosted in `static/fonts/`. Do not add webfont CDN links.
- **Mobile:** the sidebar becomes a drawer behind the hamburger button under 768px. Keep the drawer script in `footer.html` intact.
- **No new JS dependencies.** The site uses only `static/js/search.js` and the inline scripts in `header.html`/`footer.html`.

## Content Guidelines

### Front matter

TOML front matter delimited by `+++`:

```toml
+++
title = "Page Title"
description = "Short SEO description (also rendered as the page lede)"
weight = 1
+++
```

- **Always preserve front matter** when editing.
- `description` renders under the h1 as the page lede and on section cards - keep it one sentence, informative, no trailing period needed.
- Cross-link generously between pages. **Keep URLs relative** - `{{ base_url }}/...` in templates, `/section/page/` in markdown links.

### Adding a new page

1. Create the `.md` under the right section directory with `title`, `description`, and `weight`.
2. That's it. The sidebar, header nav, section cards, and prev/next links are all generated dynamically from `site.sections` (weight-sorted). **No template edits needed.**

### Editing rules

- Keep terminology consistent with the library and the upstream protocol: "agent", "client", "session", "capability", "JSON-RPC".
- Code samples must be valid Crystal that runs against the latest acp.cr - copy from the repo's `examples/` directory when in doubt.

## Notes for AI Agents

1. **Don't invent APIs.** Only document symbols that exist in `src/**`. Verify by grepping the source before adding examples.
2. **Use `crystal spec`** (from the repo root) to confirm any code sample you add still type-checks semantically.
