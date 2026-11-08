// Runs before first paint so a Chinese reader never sees a flash of English.
(function () {
  var saved = null;
  try { saved = localStorage.getItem("tongs-lang"); } catch (e) {}
  var wanted = saved || ((navigator.language || "").toLowerCase().indexOf("zh") === 0 ? "zh-CN" : "en");
  document.documentElement.lang = wanted;
})();
