// The edition selector: the latest release at the root of the
// site, each earlier one under /vX.Y.Z/. A choice opens the same page in
// that edition where it has one, else the edition's front page.
// editions.json and site-index.json (site/gen) list them.
// From skein's site/assets (chasingdaylight/skein@1e2695e), itself from
// cesiumlang.org's site/assets/editions.js
// (cesiumlang/cesiumlang.org@c657aa2), without its development site: no
// page names a domain the site is served under.
(function () {
  "use strict";

  var select = document.getElementById("edition");
  var editionsLink = document.getElementById("editions");
  var indexLink = document.getElementById("site-index");
  if (!select || !editionsLink || !indexLink) return;

  var base = indexLink.href.slice(0, indexLink.href.lastIndexOf("/") + 1);
  var current = location.pathname.replace(/^\/+|\/+$/g, "");
  var rootPath = new URL(base).pathname.replace(/^\/+|\/+$/g, "");
  if (rootPath && current.indexOf(rootPath) === 0) current = current.slice(rootPath.length).replace(/^\/+/, "");

  var edition = /^v(\d+\.\d+\.\d+)(?:\/|$)/;
  var match = current.match(edition);
  // the page's path within its edition: guides/quickstart
  var rest = match ? current.slice(match[0].length) : current;

  function json(response) { return response.json(); }

  Promise.all([fetch(editionsLink.href).then(json), fetch(indexLink.href).then(json)]).then(function (data) {
    var releases = data[0].releases || [];
    var latest = releases[0];
    if (!latest) return;
    var slugs = {};
    data[1].forEach(function (page) { slugs[page.slug] = true; });

    releases.forEach(function (release) {
      var option = document.createElement("option");
      option.value = release;
      option.textContent = "v" + release + (release === latest ? " (latest)" : "");
      select.appendChild(option);
    });
    select.value = match ? match[1] : latest;
    select.hidden = false;

    // where a release's page is: the latest at the root, the others under vX.Y.Z/
    function prefix(release) { return release === latest ? "" : "v" + release + "/"; }

    select.addEventListener("change", function () {
      var choice = select.value;
      var slug = (prefix(choice) + rest).replace(/\/+$/, "");
      location.href = base + (slugs[slug] ? (slug ? slug + "/" : "") : prefix(choice)) + location.hash;
    });
  });
})();
