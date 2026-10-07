document.addEventListener("DOMContentLoaded", function () {
  var root = document.getElementById("posts");
  if (!root) return;

  var tech = "";
  var kind = "";
  var page = 1;
  var pageSize = 10;
  var input = document.getElementById("search");
  var empty = document.getElementById("empty");
  var count = document.getElementById("result-count");
  var mobile = document.getElementById("mobile-tech");
  var pager = document.getElementById("pager");

  function tagsOf(el) {
    return (el.getAttribute("data-tags") || "").split("|").filter(Boolean);
  }

  function windowOf(current, total) {
    if (total <= 6) {
      var all = [];
      for (var i = 1; i <= total; i += 1) all.push(i);
      return all;
    }
    if (current <= 4) return [1, 2, 3, 4, 5, "…", total];
    if (current >= total - 3) return [1, "…", total - 4, total - 3, total - 2, total - 1, total];
    return [1, "…", current - 1, current, current + 1, "…", total];
  }

  function drawPager(pages) {
    if (!pager) return;
    pager.hidden = pages < 2;
    pager.replaceChildren();
    windowOf(page, pages).forEach(function (item) {
      if (item === "…") {
        var gap = document.createElement("span");
        gap.textContent = "…";
        pager.appendChild(gap);
        return;
      }
      var button = document.createElement("button");
      button.type = "button";
      button.textContent = String(item);
      if (item === page) button.setAttribute("aria-current", "page");
      button.addEventListener("click", function () {
        page = item;
        update();
        var browse = document.getElementById("browse");
        if (browse) browse.scrollIntoView({ block: "start" });
      });
      pager.appendChild(button);
    });
  }

  function update() {
    var query = (input && input.value ? input.value : "").trim().toLowerCase();
    var matches = [];
    root.querySelectorAll(".post").forEach(function (el) {
      var haystack = (el.getAttribute("data-search") || "").toLowerCase();
      var ok =
        (!tech || tagsOf(el).indexOf(tech) !== -1) &&
        (!kind || el.getAttribute("data-kind") === kind) &&
        (!query || haystack.indexOf(query) !== -1);
      if (ok) matches.push(el);
      el.hidden = true;
    });
    var pages = Math.max(1, Math.ceil(matches.length / pageSize));
    if (page > pages) page = pages;
    var start = (page - 1) * pageSize;
    matches.forEach(function (el, index) {
      el.hidden = index < start || index >= start + pageSize;
    });
    var visible = matches.length;
    if (empty) empty.hidden = visible > 0;
    if (count) count.textContent = visible + "개 글";
    drawPager(pages);
    document.querySelectorAll("[data-tech-filter]").forEach(function (button) {
      var on = button.getAttribute("data-tech-filter") === tech && tech !== "";
      button.classList.toggle("active", on);
      button.setAttribute("aria-pressed", String(on));
    });
    document.querySelectorAll("[data-kind-filter]").forEach(function (button) {
      button.setAttribute("aria-pressed", String(button.getAttribute("data-kind-filter") === kind));
    });
    if (mobile && mobile.value !== tech) mobile.value = tech;
  }

  document.querySelectorAll("[data-tech-filter]").forEach(function (button) {
    button.addEventListener("click", function () {
      var next = button.getAttribute("data-tech-filter");
      tech = tech === next ? "" : next;
      page = 1;
      update();
      var browse = document.getElementById("browse");
      if (browse) browse.scrollIntoView({ block: "start" });
    });
  });

  document.querySelectorAll("[data-kind-filter]").forEach(function (button) {
    button.addEventListener("click", function () {
      kind = button.getAttribute("data-kind-filter") || "";
      page = 1;
      update();
    });
  });

  if (input) input.addEventListener("input", function () { page = 1; update(); });
  if (mobile) {
    mobile.addEventListener("change", function () {
      tech = mobile.value;
      page = 1;
      update();
    });
  }
  var reset = document.getElementById("reset");
  if (reset) {
    reset.addEventListener("click", function () {
      tech = "";
      kind = "";
      page = 1;
      if (input) input.value = "";
      if (mobile) mobile.value = "";
      update();
    });
  }
  update();
});
