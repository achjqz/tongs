// Runs before first paint. People landing on the English home page with a Chinese browser, or who chose
// a language before, go to their page. Crawlers and direct links to /zh/ stay where they are.
(function () {
  var root = document.documentElement;
  root.classList.add("js");
  var saved = null;
  try { saved = localStorage.getItem("tongs-lang"); } catch (e) {}
  var onZh = root.lang.indexOf("zh") === 0;
  var wantsZh = saved ? saved.indexOf("zh") === 0 : (navigator.language || "").toLowerCase().indexOf("zh") === 0;
  if (!onZh && wantsZh) location.replace("/zh/" + location.hash);
  else if (onZh && saved && !wantsZh) location.replace("/" + location.hash);
})();
