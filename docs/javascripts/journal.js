document.addEventListener("DOMContentLoaded", function () {
  var root = document.getElementById("posts");
  if (!root) return;

  var tech = "";
  var kind = "";
  var input = document.getElementById("search");
  var empty = document.getElementById("empty");
  var count = document.getElementById("result-count");
  var mobile = document.getElementById("mobile-tech");

  function tagsOf(el) {
    return (el.getAttribute("data-tags") || "").split("|").filter(Boolean);
  }

  function update() {
    var query = (input && input.value ? input.value : "").trim().toLowerCase();
    var visible = 0;
    root.querySelectorAll(".post").forEach(function (el) {
      var haystack = (el.getAttribute("data-search") || "").toLowerCase();
      var ok =
        (!tech || tagsOf(el).indexOf(tech) !== -1) &&
        (!kind || el.getAttribute("data-kind") === kind) &&
        (!query || haystack.indexOf(query) !== -1);
      el.hidden = !ok;
      if (ok) visible += 1;
    });
    if (empty) empty.hidden = visible > 0;
    if (count) count.textContent = visible + "개 글";
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
      update();
      var browse = document.getElementById("browse");
      if (browse) browse.scrollIntoView({ block: "start" });
    });
  });

  document.querySelectorAll("[data-kind-filter]").forEach(function (button) {
    button.addEventListener("click", function () {
      kind = button.getAttribute("data-kind-filter") || "";
      update();
    });
  });

  if (input) input.addEventListener("input", update);
  if (mobile) {
    mobile.addEventListener("change", function () {
      tech = mobile.value;
      update();
    });
  }
  var reset = document.getElementById("reset");
  if (reset) {
    reset.addEventListener("click", function () {
      tech = "";
      kind = "";
      if (input) input.value = "";
      if (mobile) mobile.value = "";
      update();
    });
  }
  update();
});
