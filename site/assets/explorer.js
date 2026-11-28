// The explorer, breadcrumbs, tags, search and the toggles. Everything comes
// from site-index.json (written by site/gen), so no generator is assumed.
(function () {
  "use strict";

  var indexLink = document.getElementById("site-index");
  var base = indexLink.href.slice(0, indexLink.href.lastIndexOf("/") + 1);
  var current = location.pathname.replace(/^\/+|\/+$/g, "");
  var rootPath = new URL(base).pathname.replace(/^\/+|\/+$/g, "");
  if (rootPath && current.indexOf(rootPath) === 0) current = current.slice(rootPath.length).replace(/^\/+/, "");

  function store(key, value) {
    try { localStorage.setItem(key, value); } catch (e) {}
  }
  function stored(key) {
    try { return localStorage.getItem(key); } catch (e) { return null; }
  }

  function el(tag, attrs, text) {
    var node = document.createElement(tag);
    for (var name in attrs || {}) node.setAttribute(name, attrs[name]);
    if (text) node.textContent = text;
    return node;
  }

  function tagSlug(tag) {
    return tag.toLowerCase().replace(/[^a-z0-9]/g, "-");
  }

  function url(slug) {
    return base + (slug ? slug + "/" : "");
  }

  // ---- the tree ------------------------------------------------------

  function byOrder(a, b) {
    return (a.order - b.order) || a.title.localeCompare(b.title);
  }

  function makeTree(pages) {
    var root = { name: "", entry: null, folders: {}, pages: [] };
    pages.forEach(function (page) {
      if (page.slug === "" || /^tags(\/|$)/.test(page.slug)) return;
      var parts = page.slug.split("/");
      var node = root;
      var folderDepth = page.index ? parts.length : parts.length - 1;
      for (var i = 0; i < folderDepth; i++) {
        var name = parts[i];
        node.folders[name] = node.folders[name] || { name: name, entry: null, folders: {}, pages: [] };
        node = node.folders[name];
      }
      if (page.index) node.entry = page;
      else node.pages.push(page);
    });
    return root;
  }

  function folderOrder(node) {
    return node.entry ? node.entry.order : Number.MAX_SAFE_INTEGER;
  }

  function folderTitle(node) {
    return node.entry ? node.entry.title : node.name;
  }

  function renderNode(node, depth) {
    var list = el("ul");
    var items = [];
    Object.keys(node.folders).forEach(function (name) {
      var folder = node.folders[name];
      items.push({ order: folderOrder(folder), title: folderTitle(folder), folder: folder });
    });
    node.pages.forEach(function (page) {
      items.push({ order: page.order, title: page.title, page: page });
    });
    items.sort(byOrder);
    items.forEach(function (item) {
      var li = el("li");
      if (item.folder) {
        var folder = item.folder;
        var slug = folder.entry ? folder.entry.slug : null;
        var open = stored("explorer:" + (slug || folder.name));
        var contains = slug !== null && (current === slug || current.indexOf(slug + "/") === 0);
        li.className = "folder" + (contains || open === "open" ? " open" : "");
        var row = el("div", { class: "row" });
        var fold = el("button", { class: "fold", type: "button", "aria-label": "Expand or collapse" }, "▸");
        fold.addEventListener("click", function () {
          li.classList.toggle("open");
          store("explorer:" + (slug || folder.name), li.classList.contains("open") ? "open" : "closed");
        });
        row.appendChild(fold);
        row.appendChild(link(folder.entry, folderTitle(folder)));
        li.appendChild(row);
        li.appendChild(renderNode(folder, depth + 1));
      } else {
        pageItem(li, item.page);
      }
      list.appendChild(li);
    });
    return list;
  }

  // a page with headings is a fold: the headings are what it has inside
  function pageItem(li, page) {
    var tree = headingTree(page.headings);
    if (!tree.length) {
      li.appendChild(link(page, page.title));
      return;
    }
    var key = "explorer:" + page.slug;
    var open = page.slug === current || stored(key) === "open";
    li.className = "folder" + (open ? " open" : "");
    var row = el("div", { class: "row" });
    row.appendChild(foldButton(li, key));
    row.appendChild(link(page, page.title));
    li.appendChild(row);
    li.appendChild(headingList(page, tree));
  }

  function foldButton(li, key) {
    var fold = el("button", { class: "fold", type: "button", "aria-label": "Expand or collapse" }, "▸");
    fold.addEventListener("click", function () {
      li.classList.toggle("open");
      if (key) store(key, li.classList.contains("open") ? "open" : "closed");
    });
    return fold;
  }

  // the headings by depth: a heading is inside the nearest one above it that is less deep
  function headingTree(headings) {
    var root = { depth: 0, children: [] };
    var stack = [root];
    headings.forEach(function (h) {
      while (stack.length > 1 && stack[stack.length - 1].depth >= h.depth) stack.pop();
      var node = { heading: h, depth: h.depth, children: [] };
      stack[stack.length - 1].children.push(node);
      stack.push(node);
    });
    return root.children;
  }

  function headingList(page, nodes) {
    var list = el("ul");
    nodes.forEach(function (node) {
      var li = el("li");
      var a = el("a", { href: url(page.slug) + "#" + node.heading.id }, node.heading.text);
      if (node.children.length) {
        li.className = "folder";
        var row = el("div", { class: "row" });
        row.appendChild(foldButton(li, null));
        row.appendChild(a);
        li.appendChild(row);
        li.appendChild(headingList(page, node.children));
      } else {
        li.appendChild(a);
      }
      list.appendChild(li);
    });
    return list;
  }

  function link(entry, title) {
    if (!entry) return el("span", {}, title);
    var a = el("a", { href: url(entry.slug) }, title);
    if (entry.slug === current) a.className = "current";
    return a;
  }

  // ---- search --------------------------------------------------------

  function setupSearch(pages) {
    var input = document.getElementById("search-input");
    var results = document.getElementById("search-results");

    function hide() {
      results.hidden = true;
    }

    function show() {
      var terms = input.value.toLowerCase().split(/s+/).filter(Boolean);
      results.textContent = "";
      if (!terms.length) { hide(); return; }
      var hits = [];
      pages.forEach(function (page) {
        var score = 0;
        var title = page.title.toLowerCase();
        var text = page.text.toLowerCase();
        var headings = page.headings.map(function (h) { return h.text.toLowerCase(); }).join(" ");
        var tags = page.tags.join(" ").toLowerCase();
        for (var i = 0; i < terms.length; i++) {
          var t = terms[i];
          var s = (title.indexOf(t) >= 0 ? 10 : 0) + (tags.indexOf(t) >= 0 ? 5 : 0) +
            (headings.indexOf(t) >= 0 ? 3 : 0) + (text.indexOf(t) >= 0 ? 1 : 0);
          if (!s) { score = 0; break; }
          score += s;
        }
        if (score) hits.push({ page: page, score: score, text: text });
      });
      hits.sort(function (a, b) { return b.score - a.score; });
      if (!hits.length) results.appendChild(el("p", {}, "Nothing found"));
      hits.slice(0, 20).forEach(function (hit) {
        var a = el("a", { href: url(hit.page.slug) });
        a.appendChild(el("strong", {}, hit.page.title));
        var at = Math.max(0, hit.text.indexOf(terms[0]) - 40);
        a.appendChild(el("small", {}, hit.page.text.slice(at, at + 140)));
        results.appendChild(a);
      });
      results.hidden = false;
    }

    input.addEventListener("input", show);
    input.addEventListener("focus", show);
    document.addEventListener("click", function (event) {
      if (!document.getElementById("search").contains(event.target)) hide();
    });
    document.addEventListener("keydown", function (event) {
      var typing = /^(INPUT|TEXTAREA)$/.test((event.target.tagName || ""));
      if (event.key === "Escape") { input.value = ""; hide(); input.blur(); }
      else if (event.key === "/" && !typing) { event.preventDefault(); input.focus(); }
    });
  }

  // ---- the page ------------------------------------------------------

  function setupPage(pages) {
    var entry = pages.filter(function (p) { return p.slug === current; })[0];

    var crumbs = document.getElementById("breadcrumbs");
    var parts = current ? current.split("/") : [];
    var prefix = "";
    crumbs.appendChild(el("a", { href: url("") }, "Home"));
    parts.slice(0, -1).forEach(function (part) {
      prefix = prefix ? prefix + "/" + part : part;
      var folder = pages.filter(function (p) { return p.slug === prefix && p.index; })[0];
      crumbs.appendChild(el("a", { href: url(prefix) }, folder ? folder.title : part));
    });

    var meta = document.getElementById("page-meta");
    if (meta && entry) {
      entry.tags.forEach(function (tag) {
        var a = el("a", { class: "tag", href: url("tags/" + tagSlug(tag)) }, tag);
        meta.appendChild(a);
      });
    }

    // the pages that link to this one
    var box = document.getElementById("backlinks");
    var from = pages.filter(function (p) { return p.slug !== current && p.links.indexOf(current) >= 0; });
    if (box && from.length) {
      box.appendChild(el("h2", {}, "Backlinks"));
      var list = el("ul");
      from.forEach(function (p) {
        var li = el("li");
        li.appendChild(el("a", { href: url(p.slug) }, p.title));
        list.appendChild(li);
      });
      box.appendChild(list);
      box.hidden = false;
    }
  }

  // ---- previews ------------------------------------------------------

  // Hovering a link to another page of the site shows the start of that page
  // (or the section the link names), as the page itself has it.
  function setupPopovers() {
    if (!window.matchMedia("(hover: hover)").matches) return;
    var cache = {};
    var popover = null;
    var timer = null;

    function hide() {
      clearTimeout(timer);
      if (popover) popover.remove();
      popover = null;
    }

    function load(path) {
      if (!cache[path]) {
        cache[path] = fetch(path)
          .then(function (response) { return response.ok ? response.text() : ""; })
          .then(function (html) { return new DOMParser().parseFromString(html, "text/html"); });
      }
      return cache[path];
    }

    function preview(doc, hash) {
      var box = el("div", { class: "popover" });
      var section = hash && doc.getElementById(decodeURIComponent(hash.slice(1)));
      if (section) {
        box.appendChild(document.importNode(section, true));
        return box;
      }
      var title = doc.querySelector("article h1");
      var body = doc.querySelector("article .content");
      if (!body) return null;
      if (title) box.appendChild(document.importNode(title, true));
      Array.prototype.slice.call(body.children, 0, 12).forEach(function (node) {
        box.appendChild(document.importNode(node, true));
      });
      return box;
    }

    function place(box, link) {
      var rect = link.getBoundingClientRect();
      var width = Math.min(448, window.innerWidth - 16);
      var left = Math.max(8, Math.min(rect.left, window.innerWidth - width - 8));
      box.style.left = left + "px";
      document.body.appendChild(box);
      var height = box.getBoundingClientRect().height;
      var below = rect.bottom + 6;
      box.style.top = (below + height > window.innerHeight && rect.top - height - 6 > 56 ? rect.top - height - 6 : below) + "px";
    }

    document.addEventListener("mouseover", function (event) {
      var link = event.target.closest ? event.target.closest(".content a[href], #backlinks a[href]") : null;
      if (!link || link.origin !== location.origin || link.pathname === location.pathname) return;
      hide();
      timer = setTimeout(function () {
        load(link.pathname).then(function (doc) {
          var box = preview(doc, link.hash);
          if (box && link.matches(":hover")) { popover = box; place(box, link); }
        });
      }, 300);
    });
    document.addEventListener("mouseout", function (event) {
      if (event.target.closest && event.target.closest("a[href]")) hide();
    });
    window.addEventListener("scroll", hide, { passive: true });
  }

  function setupToggles() {
    var root = document.documentElement;
    var reader = document.getElementById("reader-toggle");
    var menu = document.getElementById("menu-toggle");

    document.getElementById("theme-toggle").addEventListener("click", function () {
      root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
      store("theme", root.dataset.theme);
    });

    reader.setAttribute("aria-pressed", root.dataset.reader === "on" ? "true" : "false");
    reader.addEventListener("click", function () {
      if (root.dataset.reader === "on") delete root.dataset.reader;
      else root.dataset.reader = "on";
      delete root.dataset.menu;
      reader.setAttribute("aria-pressed", root.dataset.reader === "on" ? "true" : "false");
      store("reader", root.dataset.reader || "off");
    });

    // the explorer is a menu on narrow screens
    function setMenu(open) {
      if (open) root.dataset.menu = "open";
      else delete root.dataset.menu;
      menu.setAttribute("aria-expanded", open ? "true" : "false");
    }
    menu.addEventListener("click", function () {
      setMenu(root.dataset.menu !== "open");
    });
    document.getElementById("menu-backdrop").addEventListener("click", function () {
      setMenu(false);
    });

    // the name next to the icon goes when the page is scrolled
    function scrolled() {
      if (window.scrollY > 0) root.dataset.scrolled = "";
      else delete root.dataset.scrolled;
    }
    window.addEventListener("scroll", scrolled, { passive: true });
    scrolled();
  }

  setupToggles();
  setupPopovers();
  fetch(indexLink.href)
    .then(function (response) { return response.json(); })
    .then(function (pages) {
      // the editions of releases (cesiumlang.org#43): the menu and the search
      // keep to the edition of the page, the site's own pages outside one
      var edition = /^v\d+\.\d+\.\d+(?=\/|$)/;
      var here = (current.match(edition) || [""])[0];
      var shown = pages.filter(function (page) {
        var m = page.slug.match(edition);
        return here ? m !== null && m[0] === here : m === null;
      });
      document.getElementById("explorer").appendChild(renderNode(makeTree(shown), 0));
      setupPage(pages);
      setupSearch(shown);
    });
})();
