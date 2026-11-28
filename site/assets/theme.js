// Sets the color theme and the reader mode before the page paints.
(function () {
  var root = document.documentElement;
  var theme = null;
  var reader = null;
  try {
    theme = localStorage.getItem("theme");
    reader = localStorage.getItem("reader");
  } catch (e) {}
  if (!theme) {
    theme = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  root.dataset.theme = theme;
  if (reader === "on") root.dataset.reader = "on";
})();
