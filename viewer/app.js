const urlParams = new URLSearchParams(window.location.search);

const state = {
  dives: [],
  importStatus: null,
  selected: null,
  loadingSummaries: true,
  view: urlParams.get("view") || localStorage.getItem("dclvView") || "dives",
  query: "",
  computer: "",
  sortKey: localStorage.getItem("dclvSortKey") || "displayNumber",
  sortDir: localStorage.getItem("dclvSortDir") || "asc",
  units: urlParams.get("units") || localStorage.getItem("perdixUnits") || "metric",
  theme: urlParams.get("theme") || localStorage.getItem("perdixTheme") || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"),
  visibleSeries: new Set(["depth", "temperature"]),
};

if (state.sortKey === "number") {
  state.sortKey = "displayNumber";
}
if (!["dives", "summary"].includes(state.view)) {
  state.view = "dives";
}
if (!["metric", "imperial"].includes(state.units)) {
  state.units = "metric";
}
if (!["light", "dark"].includes(state.theme)) {
  state.theme = "light";
}

const els = {
  status: document.getElementById("status"),
  refresh: document.getElementById("refresh"),
  search: document.getElementById("search"),
  computerFilter: document.getElementById("computer-filter"),
  divesView: document.getElementById("dives-view"),
  summaryView: document.getElementById("summary-view"),
  splitter: document.getElementById("splitter"),
  metric: document.getElementById("metric"),
  imperial: document.getElementById("imperial"),
  lightTheme: document.getElementById("light-theme"),
  darkTheme: document.getElementById("dark-theme"),
  dives: document.getElementById("dives"),
  empty: document.getElementById("empty"),
  detail: document.getElementById("detail"),
  title: document.getElementById("detail-title"),
  subtitle: document.getElementById("detail-subtitle"),
  metrics: document.getElementById("metrics"),
  tanks: document.getElementById("tanks"),
  scrubber: document.getElementById("scrubber"),
  samples: document.getElementById("samples"),
  xmlLink: document.getElementById("xml-link"),
  seriesControls: document.getElementById("series-controls"),
  profileChart: document.getElementById("profile-chart"),
  summarySubtitle: document.getElementById("summary-subtitle"),
  summaryMetrics: document.getElementById("summary-metrics"),
  summaryHighlights: document.getElementById("summary-highlights"),
  summaryBreakdown: document.getElementById("summary-breakdown"),
  summaryImportStatus: document.getElementById("summary-import-status"),
};

function fmt(value, suffix = "") {
  if (value === null || value === undefined || value === "") return "—";
  return `${value}${suffix}`;
}

function fmtNum(value, digits = 1, suffix = "") {
  if (typeof value !== "number" || Number.isNaN(value)) return "—";
  return `${value.toFixed(digits)}${suffix}`;
}

function isImperial() {
  return state.units === "imperial";
}

function depthValue(meters) {
  return isImperial() && typeof meters === "number" ? meters * 3.28084 : meters;
}

function pressureValue(bar) {
  return isImperial() && typeof bar === "number" ? bar * 14.5038 : bar;
}

function temperatureValue(celsius) {
  return isImperial() && typeof celsius === "number" ? (celsius * 9) / 5 + 32 : celsius;
}

function depthLabel() {
  return isImperial() ? "ft" : "m";
}

function pressureLabel() {
  return isImperial() ? "psi" : "bar";
}

function temperatureLabel() {
  return isImperial() ? "°F" : "°C";
}

function fmtDepth(meters, digits = 1) {
  return fmtNum(depthValue(meters), digits, ` ${depthLabel()}`);
}

function fmtPressure(bar, digits = 1) {
  return fmtNum(pressureValue(bar), digits, ` ${pressureLabel()}`);
}

function fmtTemperature(celsius, digits = 1) {
  return fmtNum(temperatureValue(celsius), digits, ` ${temperatureLabel()}`);
}

function volumeValue(liters) {
  return isImperial() && typeof liters === "number" ? liters / 28.3168 : liters;
}

function volumeLabel() {
  return isImperial() ? "cu ft" : "L";
}

function fmtVolume(liters, digits = 1) {
  return fmtNum(volumeValue(liters), digits, ` ${volumeLabel()}`);
}

function fmtRmv(litersPerMin, digits = 1) {
  const value = isImperial() && typeof litersPerMin === "number" ? litersPerMin / 28.3168 : litersPerMin;
  return fmtNum(value, digits, isImperial() ? " cu ft/min" : " L/min");
}

function fmtSeconds(seconds) {
  if (typeof seconds !== "number" || Number.isNaN(seconds)) return "—";
  const minutes = Math.floor(seconds / 60);
  const remainder = Math.round(seconds % 60);
  return `${minutes}:${String(remainder).padStart(2, "0")}`;
}

function fmtTotalTime(seconds) {
  if (typeof seconds !== "number" || Number.isNaN(seconds)) return "—";
  const totalMinutes = Math.round(seconds / 60);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return hours ? `${hours}h ${String(minutes).padStart(2, "0")}m` : `${minutes}m`;
}

function fmtDate(value) {
  if (!value) return "—";
  const date = new Date(value.replace(" ", "T"));
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

function diveNumber(dive) {
  return dive?.displayNumber ?? dive?.number;
}

function recordNumberText(dive) {
  if (!dive?.recordNumber || dive.recordNumber === diveNumber(dive)) return "";
  return `Record ${dive.recordNumber}`;
}

function updateUnitToggle() {
  els.metric.classList.toggle("active", state.units === "metric");
  els.imperial.classList.toggle("active", state.units === "imperial");
}

function applyView() {
  document.body.dataset.view = state.view;
  els.divesView.classList.toggle("active", state.view === "dives");
  els.summaryView.classList.toggle("active", state.view === "summary");
  if (state.view === "summary") renderSummary();
}

function themeColor(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function applyTheme() {
  document.documentElement.dataset.theme = state.theme;
  els.lightTheme.classList.toggle("active", state.theme === "light");
  els.darkTheme.classList.toggle("active", state.theme === "dark");
}

function setListWidth(width) {
  const min = 280;
  const max = Math.max(320, window.innerWidth - 520);
  const clamped = Math.max(min, Math.min(max, width));
  document.documentElement.style.setProperty("--list-width", `${clamped}px`);
  localStorage.setItem("dclvListWidth", String(clamped));
}

function initSplitter() {
  const saved = Number(localStorage.getItem("dclvListWidth"));
  if (Number.isFinite(saved) && saved > 0) {
    setListWidth(saved);
  }

  let dragging = false;
  const update = (clientX) => {
    const left = els.splitter.parentElement.getBoundingClientRect().left;
    setListWidth(clientX - left);
  };

  els.splitter.addEventListener("pointerdown", (event) => {
    dragging = true;
    els.splitter.setPointerCapture(event.pointerId);
    document.body.classList.add("resizing");
    update(event.clientX);
  });

  els.splitter.addEventListener("pointermove", (event) => {
    if (dragging) update(event.clientX);
  });

  els.splitter.addEventListener("pointerup", (event) => {
    dragging = false;
    els.splitter.releasePointerCapture(event.pointerId);
    document.body.classList.remove("resizing");
  });

  els.splitter.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    const current = Number.parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--list-width")) || 420;
    setListWidth(current + (event.key === "ArrowLeft" ? -32 : 32));
  });
}

function gasLabel(dive) {
  return (dive.gasmixes || []).slice(0, 2).join(", ") || "—";
}

function matchesQuery(dive) {
  if (state.computer && dive.computer !== state.computer) return false;
  if (!state.query) return true;
  const haystack = [
    dive.computer,
    dive.displayNumber,
    dive.number,
    dive.recordNumber,
    dive.datetime,
    dive.divetime,
    dive.maxDepth,
    dive.mode,
    gasLabel(dive),
    dive.fingerprint,
  ].join(" ").toLowerCase();
  return haystack.includes(state.query);
}

function sortValue(dive, key) {
  if (key === "gas") return gasLabel(dive);
  if (key === "datetime") return dive.datetime || "";
  if (key === "displayNumber") return diveNumber(dive);
  return dive[key];
}

function compareDives(a, b) {
  const av = sortValue(a, state.sortKey);
  const bv = sortValue(b, state.sortKey);
  const direction = state.sortDir === "desc" ? -1 : 1;

  if (typeof av === "number" && typeof bv === "number") {
    return (av - bv) * direction;
  }

  if (av === null || av === undefined || av === "") return 1;
  if (bv === null || bv === undefined || bv === "") return -1;
  return String(av).localeCompare(String(bv), undefined, { numeric: true, sensitivity: "base" }) * direction;
}

function filteredDives() {
  return state.dives.filter(matchesQuery);
}

function updateSortHeaders() {
  document.querySelectorAll("button.sort").forEach((button) => {
    button.classList.toggle("asc", button.dataset.sort === state.sortKey && state.sortDir === "asc");
    button.classList.toggle("desc", button.dataset.sort === state.sortKey && state.sortDir === "desc");
  });
}

async function loadSummaries() {
  state.loadingSummaries = true;
  els.status.textContent = "Refreshing...";
  renderSummary();
  try {
    const response = await fetch("/api/dives", { cache: "no-store" });
    if (!response.ok) throw new Error(`Failed to load dives: ${response.status}`);
    const data = await response.json();
    state.dives = data.dives || [];
    state.importStatus = data.status || null;
    state.loadingSummaries = false;
    renderComputerFilter();
    renderList();
    renderSummary();
    const errors = data.errors?.length ? `, ${data.errors.length} parse errors` : "";
    els.status.textContent = `${data.xmlCount} XML dives, ${data.rawCount} raw dives${errors}. Last refreshed ${new Date().toLocaleTimeString()}`;
    if (!state.selected && urlParams.get("select") === "first") {
      const first = filteredDives().sort(compareDives)[0];
      if (first) await selectDive(first.id);
    }
  } catch (error) {
    state.loadingSummaries = false;
    renderSummary();
    throw error;
  }
}

function renderComputerFilter() {
  const computers = [...new Set(state.dives.map((dive) => dive.computer).filter(Boolean))].sort();
  const current = state.computer;
  els.computerFilter.innerHTML = [
    `<option value="">All Computers</option>`,
    ...computers.map((computer) => `<option value="${computer}">${computer}</option>`),
  ].join("");
  els.computerFilter.value = computers.includes(current) ? current : "";
  state.computer = els.computerFilter.value;
}

function renderList() {
  updateSortHeaders();
  const rows = filteredDives().sort(compareDives).map((dive) => {
    const selected = state.selected && state.selected.summary.id === dive.id ? " class=\"selected\"" : "";
    return `
      <tr data-id="${dive.id}"${selected}>
        <td title="${recordNumberText(dive)}">${fmt(diveNumber(dive))}</td>
        <td>${fmt(dive.computer).replace("Shearwater ", "")}</td>
        <td>${fmt(dive.datetime)}</td>
        <td>${fmt(dive.divetime)}</td>
        <td>${fmtDepth(dive.maxDepth, 1)}</td>
        <td>${fmt(dive.mode)}</td>
        <td>${gasLabel(dive)}</td>
        <td>${fmt(dive.sampleCount)}</td>
      </tr>
    `;
  }).join("");
  els.dives.innerHTML = rows || `<tr><td colspan="8">No matching dives.</td></tr>`;
}

function countBy(dives, getter) {
  const counts = new Map();
  for (const dive of dives) {
    const key = getter(dive) || "Unknown";
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || String(a[0]).localeCompare(String(b[0])));
}

function summaryRow(label, value) {
  return `<div class="summary-row"><span>${label}</span><span>${value}</span></div>`;
}

const diveTimestampCache = new WeakMap();
const diveSourceCache = new WeakMap();
const maxReasonableDiveSeconds = 6 * 60 * 60;

function diveTimestamp(dive) {
  if (diveTimestampCache.has(dive)) return diveTimestampCache.get(dive);
  if (!dive.datetime) return null;
  const normalized = String(dive.datetime)
    .replace(" ", "T")
    .replace(/T(\d\d:\d\d:\d\d)\s+([+-]\d\d:\d\d)$/, "T$1$2");
  const value = new Date(normalized).getTime();
  const timestamp = Number.isNaN(value) ? null : value;
  diveTimestampCache.set(dive, timestamp);
  return timestamp;
}

function diveSource(dive) {
  if (diveSourceCache.has(dive)) return diveSourceCache.get(dive);
  const source = String(dive.computer || "").startsWith("MacDive -") || String(dive.file || "").startsWith("macdive/")
    ? "MacDive"
    : "Direct Bluetooth";
  diveSourceCache.set(dive, source);
  return source;
}

function sameDiveEstimate(a, b) {
  const at = diveTimestamp(a);
  const bt = diveTimestamp(b);
  if (at === null || bt === null) return false;
  const timeClose = Math.abs(at - bt) <= 20 * 60 * 1000;
  const durationClose = Math.abs((a.divetimeSeconds || 0) - (b.divetimeSeconds || 0)) <= 5 * 60;
  const maxDepthClose = typeof a.maxDepth === "number" && typeof b.maxDepth === "number"
    ? Math.abs(a.maxDepth - b.maxDepth) <= 4
    : true;
  const avgDepthClose = typeof a.avgDepth === "number" && typeof b.avgDepth === "number"
    ? Math.abs(a.avgDepth - b.avgDepth) <= 5
    : true;
  return timeClose && durationClose && maxDepthClose && avgDepthClose;
}

function compareSummaryPreference(a, b) {
  const sampleDiff = (b.sampleCount || 0) - (a.sampleCount || 0);
  if (sampleDiff) return sampleDiff;
  const sourceDiff = (diveSource(a) === "MacDive" ? 0 : 1) - (diveSource(b) === "MacDive" ? 0 : 1);
  if (sourceDiff) return sourceDiff;
  return String(a.id).localeCompare(String(b.id));
}

function estimateUniqueDiveGroups(dives) {
  const timeWindow = 20 * 60 * 1000;
  const groups = [];
  const sorted = [...dives].sort((a, b) => (diveTimestamp(a) ?? Number.MAX_SAFE_INTEGER) - (diveTimestamp(b) ?? Number.MAX_SAFE_INTEGER));

  for (const dive of sorted) {
    const timestamp = diveTimestamp(dive);
    let matched = null;

    for (let index = groups.length - 1; index >= 0; index -= 1) {
      const group = groups[index];
      if (timestamp !== null && group.maxTimestamp !== null && group.maxTimestamp < timestamp - timeWindow) break;
      if (group.dives.some((candidate) => sameDiveEstimate(candidate, dive))) {
        matched = group;
        break;
      }
    }

    if (matched) {
      matched.dives.push(dive);
      if (timestamp !== null) {
        matched.minTimestamp = matched.minTimestamp === null ? timestamp : Math.min(matched.minTimestamp, timestamp);
        matched.maxTimestamp = matched.maxTimestamp === null ? timestamp : Math.max(matched.maxTimestamp, timestamp);
      }
      if (compareSummaryPreference(dive, matched.representative) < 0) matched.representative = dive;
    } else {
      groups.push({
        representative: dive,
        dives: [dive],
        minTimestamp: timestamp,
        maxTimestamp: timestamp,
      });
    }
  }

  return groups;
}

function hasReasonableDiveTime(dive) {
  return typeof dive.divetimeSeconds === "number"
    && dive.divetimeSeconds > 0
    && dive.divetimeSeconds <= maxReasonableDiveSeconds;
}

function formatNumberRange(numbers) {
  if (!numbers?.length) return "—";
  const sorted = [...numbers].sort((a, b) => a - b);
  const ranges = [];
  let start = sorted[0];
  let previous = sorted[0];
  for (const number of sorted.slice(1)) {
    if (number === previous + 1) {
      previous = number;
      continue;
    }
    ranges.push(start === previous ? `${start}` : `${start}-${previous}`);
    start = previous = number;
  }
  ranges.push(start === previous ? `${start}` : `${start}-${previous}`);
  return ranges.join(", ");
}

function renderSummary() {
  if (!els.summaryMetrics) return;
  const dives = filteredDives();
  if (state.loadingSummaries && !dives.length) {
    els.summarySubtitle.textContent = "Loading dive summaries...";
    els.summaryMetrics.innerHTML = [
      metric("Estimated Unique Dives", "—"),
      metric("Imported Records", "—"),
      metric("Likely Duplicate Records", "—"),
      metric("Unique Time Underwater", "—"),
    ].join("");
    els.summaryHighlights.innerHTML = summaryRow("Status", "Refreshing XML index");
    els.summaryBreakdown.innerHTML = summaryRow("Status", "Waiting for data");
    els.summaryImportStatus.innerHTML = summaryRow("Status", "Waiting for import status");
    return;
  }
  const uniqueGroups = estimateUniqueDiveGroups(dives);
  const uniqueDives = uniqueGroups.map((group) => group.representative);
  const durationDives = uniqueDives.filter(hasReasonableDiveTime);
  const ignoredDurationOutliers = uniqueDives.length - durationDives.length;
  const duplicateRecords = Math.max(dives.length - uniqueGroups.length, 0);
  const totalTime = durationDives.reduce((sum, dive) => sum + (dive.divetimeSeconds || 0), 0);
  const totalSamples = uniqueDives.reduce((sum, dive) => sum + (dive.sampleCount || 0), 0);
  const deepest = uniqueDives.reduce((best, dive) => (dive.maxDepth || 0) > (best?.maxDepth || 0) ? dive : best, null);
  const longest = durationDives.reduce((best, dive) => (dive.divetimeSeconds || 0) > (best?.divetimeSeconds || 0) ? dive : best, null);
  const depthValues = uniqueDives.map((dive) => dive.maxDepth).filter((value) => typeof value === "number");
  const timeValues = durationDives.map((dive) => dive.divetimeSeconds);
  const avgMaxDepth = depthValues.length
    ? depthValues.reduce((sum, value) => sum + value, 0) / depthValues.length
    : null;
  const avgDiveTime = timeValues.length
    ? timeValues.reduce((sum, value) => sum + value, 0) / timeValues.length
    : null;
  const dates = uniqueDives
    .map((dive) => dive.datetime)
    .filter(Boolean)
    .sort((a, b) => String(a).localeCompare(String(b)));
  const scope = state.computer || "All computers";
  const query = state.query ? ` matching "${state.query}"` : "";

  els.summarySubtitle.textContent = `${fmt(uniqueGroups.length)} estimated unique dives from ${fmt(dives.length)} imported records · ${scope}${query}`;
  els.summaryMetrics.innerHTML = [
    metric("Estimated Unique Dives", fmt(uniqueGroups.length)),
    metric("Imported Records", fmt(dives.length)),
    metric("Likely Duplicate Records", fmt(duplicateRecords)),
    metric("Unique Time Underwater", fmtTotalTime(totalTime)),
    metric("Longest Dive", longest ? `${fmtSeconds(longest.divetimeSeconds)} · Dive ${fmt(diveNumber(longest))}` : "—"),
    metric("Deepest Dive", deepest ? `${fmtDepth(deepest.maxDepth, 1)} · Dive ${fmt(diveNumber(deepest))}` : "—"),
    metric("Average Dive Time", fmtTotalTime(avgDiveTime)),
    metric("Average Max Depth", fmtDepth(avgMaxDepth, 1)),
    metric("First Dive", fmtDate(dates[0])),
    metric("Most Recent Dive", fmtDate(dates[dates.length - 1])),
    metric("Samples", fmt(totalSamples)),
  ].join("");

  els.summaryHighlights.innerHTML = [
    summaryRow("Longest dive", longest ? `Dive ${fmt(diveNumber(longest))} · ${fmtSeconds(longest.divetimeSeconds)} · ${fmtDate(longest.datetime)}` : "—"),
    summaryRow("Deepest dive", deepest ? `Dive ${fmt(diveNumber(deepest))} · ${fmtDepth(deepest.maxDepth, 1)} · ${fmtDate(deepest.datetime)}` : "—"),
    summaryRow("Unique profile samples", fmt(totalSamples)),
    summaryRow("Visible computer groups", fmt(countBy(dives, (dive) => dive.computer).length)),
    summaryRow("Largest duplicate group", fmt(Math.max(0, ...uniqueGroups.map((group) => group.dives.length)))),
    summaryRow("Ignored duration outliers", fmt(ignoredDurationOutliers)),
    summaryRow("Duplicate estimate basis", "time, duration, depth"),
  ].join("");

  const modeRows = countBy(uniqueDives, (dive) => dive.mode).slice(0, 4)
    .map(([mode, count]) => summaryRow(`Mode: ${mode}`, count))
    .join("");
  const gasRows = countBy(uniqueDives, gasLabel).slice(0, 4)
    .map(([gas, count]) => summaryRow(`Gas: ${gas}`, count))
    .join("");
  const sourceRows = countBy(dives, diveSource)
    .map(([source, count]) => summaryRow(`Source: ${source}`, count))
    .join("");
  els.summaryBreakdown.innerHTML = sourceRows + modeRows + gasRows || summaryRow("No dives", "—");

  const status = state.importStatus || {};
  const failedNumbers = (status.failedDives || []).map((dive) => dive.number);
  const directXmlCount = dives.filter((dive) => diveSource(dive) === "Direct Bluetooth").length;
  const macDiveXmlCount = dives.filter((dive) => diveSource(dive) === "MacDive").length;
  els.summaryImportStatus.innerHTML = [
    summaryRow("Manifest records", fmt(status.manifestCount)),
    summaryRow("Raw dives downloaded", fmt(status.downloadedRawCount)),
    summaryRow("Visible direct XML records", fmt(directXmlCount)),
    summaryRow("Visible MacDive XML records", fmt(macDiveXmlCount)),
    summaryRow("All XML records", fmt(state.dives.length)),
    summaryRow("Missing raw records", fmt(status.missingRawCount)),
    summaryRow("Known failed records", formatNumberRange(failedNumbers)),
    summaryRow("Last failure", status.lastFailure || "—"),
  ].join("");
}

async function selectDive(id) {
  els.status.textContent = `Loading dive ${id}...`;
  const response = await fetch(`/api/dive/${encodeURIComponent(id)}`, { cache: "no-store" });
  if (!response.ok) throw new Error(`Failed to load dive ${id}: ${response.status}`);
  state.selected = await response.json();
  renderList();
  renderDetail(state.selected);
  els.status.textContent = `Loaded dive ${diveNumber(state.selected.summary)}.`;
}

function metric(label, value) {
  return `<div class="metric"><span class="label">${label}</span><span class="value">${value}</span></div>`;
}

function renderDetail(detail) {
  const dive = detail.summary;
  const decoText = dive.deco?.last
    ? `${dive.deco.last.type || "—"} ${fmtSeconds(dive.deco.last.time)} @ ${fmtDepth(dive.deco.last.depth, 0)}`
    : "—";
  const sacText = dive.sac?.available
    ? fmtRmv(dive.sac.rmvLitersPerMin)
    : dive.sac?.gasUsedLiters
      ? `${fmtVolume(dive.sac.gasUsedLiters)} used`
      : "Unavailable";
  els.empty.classList.add("hidden");
  els.detail.classList.remove("hidden");
  els.title.textContent = `Dive ${diveNumber(dive)}`;
  els.subtitle.textContent = [dive.datetime || "Unknown date", recordNumberText(dive), dive.fingerprint || ""].filter(Boolean).join(" · ");
  els.xmlLink.href = `/xml/${dive.file}`;

  els.metrics.innerHTML = [
    metric("Duration", fmt(dive.divetime)),
    metric("Max Depth", fmtDepth(dive.maxDepth, 2)),
    metric("Avg Depth", fmtDepth(dive.avgDepth, 2)),
    metric("Mode", fmt(dive.mode)),
    metric("Deco", [dive.decoModel, dive.gf].filter(Boolean).join(" ") || "—"),
    metric("Current Deco", decoText),
    metric("Max TTS", fmtSeconds(dive.deco?.maxTts)),
    metric("SAC/RMV", sacText),
    metric("Samples", fmt(dive.sampleCount)),
    metric("Salinity", fmt(dive.salinity)),
    metric("Atmospheric", fmtPressure(dive.atmospheric, 2)),
  ].join("");

  els.tanks.innerHTML = (dive.tanks || []).map((tank, index) => `
    <div class="tank">
      <span class="label">Tank ${index + 1}</span>
      <span class="value">${fmt(tank.usage)}</span>
      <span class="label">${fmtPressure(tank.beginPressure, 1)} → ${fmtPressure(tank.endPressure, 1)}</span>
    </div>
  `).join("");

  renderSamples(detail.samples || []);
  drawCharts(detail.samples || []);
  setScrubIndex(0);
}

function renderSamples(samples) {
  const rows = samples.slice(0, 1200).map((sample) => {
    const pressures = sample.pressures
      ? Object.entries(sample.pressures).map(([tank, value]) => `T${tank}: ${fmtPressure(value, 1)}`).join(", ")
      : "—";
    const ppo2 = sample.ppo2
      ? sample.ppo2.map((reading) => `${reading.sensor ?? "avg"}: ${fmtNum(reading.value, 2)}`).join(", ")
      : "—";
    const deco = sample.deco
      ? `${sample.deco.type || "—"} ${fmtSeconds(sample.deco.time)} @ ${fmtDepth(sample.deco.depth, 0)}`
      : "—";
    return `
      <tr>
        <td>${fmt(sample.time)}</td>
        <td>${fmtDepth(sample.depth, 2)}</td>
        <td>${fmtTemperature(sample.temperature, 1)}</td>
        <td>${fmtNum(sample.setpoint, 2)}</td>
        <td>${fmtSeconds(sample.tts)}</td>
        <td>${deco}</td>
        <td>${ppo2}</td>
        <td>${pressures}</td>
      </tr>
    `;
  }).join("");
  els.samples.innerHTML = rows || `<tr><td colspan="8">No samples.</td></tr>`;
}

function series(samples, key, transform = (value) => value) {
  return samples
    .filter((sample) => typeof sample.timeSeconds === "number" && typeof sample[key] === "number")
    .map((sample) => ({ x: sample.timeSeconds / 60, y: transform(sample[key]) }));
}

function pressureSeries(samples) {
  const tanks = new Map();
  for (const sample of samples) {
    if (typeof sample.timeSeconds !== "number" || !sample.pressures) continue;
    for (const [tank, value] of Object.entries(sample.pressures)) {
      if (typeof value !== "number") continue;
      if (!tanks.has(tank)) tanks.set(tank, []);
      tanks.get(tank).push({ x: sample.timeSeconds / 60, y: pressureValue(value) });
    }
  }
  return tanks;
}

function ppo2Series(samples) {
  const sensors = new Map();
  for (const sample of samples) {
    if (typeof sample.timeSeconds !== "number" || !sample.ppo2) continue;
    for (const reading of sample.ppo2) {
      if (typeof reading.value !== "number") continue;
      const sensor = reading.sensor ?? "avg";
      if (!sensors.has(sensor)) sensors.set(sensor, []);
      sensors.get(sensor).push({ x: sample.timeSeconds / 60, y: reading.value });
    }
  }
  return sensors;
}

function availableSeries(samples) {
  const controls = [
    { id: "depth", name: `Depth (${depthLabel()})`, color: "#0077b6", points: series(samples, "depth", depthValue), invert: true, unit: depthLabel() },
    { id: "temperature", name: `Temperature (${temperatureLabel()})`, color: "#d97706", points: series(samples, "temperature", temperatureValue), unit: temperatureLabel() },
    { id: "tts", name: "TTS (min)", color: "#6d597a", points: series(samples, "tts", (value) => value / 60), unit: "min" },
  ];
  const colors = ["#2a9d8f", "#9b5de5", "#ef476f", "#4cc9f0"];
  [...pressureSeries(samples)].forEach(([tank, points], index) => {
    controls.push({
      id: `pressure-${tank}`,
      name: `Tank ${tank} (${pressureLabel()})`,
      color: colors[index % colors.length],
      points,
      unit: pressureLabel(),
    });
  });
  const ppo2Colors = ["#e63946", "#f4a261", "#a7c957", "#00b4d8"];
  [...ppo2Series(samples)].forEach(([sensor, points], index) => {
    controls.push({
      id: `ppo2-${sensor}`,
      name: `PPO2 ${sensor}`,
      color: ppo2Colors[index % ppo2Colors.length],
      points,
      unit: "ata",
    });
  });
  return controls.filter((item) => item.points.length);
}

function renderSeriesControls(seriesItems) {
  for (const item of seriesItems) {
    if (!state.visibleSeries.has(item.id) && item.id.startsWith("pressure-") && state.visibleSeries.size < 3) {
      state.visibleSeries.add(item.id);
    }
  }
  els.seriesControls.innerHTML = seriesItems.map((item) => `
    <label style="border-color: ${item.color}">
      <input type="checkbox" value="${item.id}" ${state.visibleSeries.has(item.id) ? "checked" : ""}>
      ${item.name}
    </label>
  `).join("");
}

function drawCharts(samples) {
  state.chartSamples = samples.filter((sample) => typeof sample.timeSeconds === "number");
  const allSeries = availableSeries(samples);
  renderSeriesControls(allSeries);
  const visible = allSeries.filter((item) => state.visibleSeries.has(item.id));
  drawLineChart(els.profileChart, visible.length ? visible : allSeries.slice(0, 1), { yLabel: "value" });
}

function drawLineChart(canvas, datasets, options = {}) {
  const ctx = canvas.getContext("2d");
  const width = canvas.width;
  const height = canvas.height;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = themeColor("--chart-bg");
  ctx.fillRect(0, 0, width, height);

  const all = datasets.flatMap((dataset) => dataset.points);
  if (!all.length) {
    ctx.fillStyle = themeColor("--chart-text");
    ctx.font = "18px system-ui";
    ctx.fillText("No data", 24, 40);
    canvas._chart = null;
    return;
  }

  const pad = { left: 58, right: 18, top: 20, bottom: 38 };
  const minX = Math.min(...all.map((p) => p.x));
  const maxX = Math.max(...all.map((p) => p.x));

  const plotW = width - pad.left - pad.right;
  const plotH = height - pad.top - pad.bottom;
  const xScale = (x) => pad.left + ((x - minX) / Math.max(maxX - minX, 1)) * plotW;
  const xUnscale = (px) => minX + ((px - pad.left) / Math.max(plotW, 1)) * Math.max(maxX - minX, 1);

  ctx.strokeStyle = themeColor("--chart-grid");
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(pad.left, pad.top);
  ctx.lineTo(pad.left, pad.top + plotH);
  ctx.lineTo(pad.left + plotW, pad.top + plotH);
  ctx.stroke();

  ctx.fillStyle = themeColor("--chart-text");
  ctx.font = "13px system-ui";
  ctx.fillText(`${minX.toFixed(0)} min`, pad.left, height - 12);
  ctx.fillText(`${maxX.toFixed(0)} min`, width - 72, height - 12);

  datasets.forEach((dataset, datasetIndex) => {
    if (!dataset.points.length) return;
    let minY = Math.min(...dataset.points.map((p) => p.y));
    let maxY = Math.max(...dataset.points.map((p) => p.y));
    if (minY === maxY) {
      minY -= 1;
      maxY += 1;
    }
    const yScale = (y) => {
      const ratio = (y - minY) / Math.max(maxY - minY, 1);
      return dataset.invert ? pad.top + ratio * plotH : pad.top + (1 - ratio) * plotH;
    };

    ctx.strokeStyle = dataset.color;
    ctx.lineWidth = 2;
    ctx.beginPath();
    dataset.points.forEach((point, index) => {
      const x = xScale(point.x);
      const y = yScale(point.y);
      if (index === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.stroke();

    const sideLeft = datasetIndex % 2 === 0;
    const x = sideLeft ? 8 : width - 126;
    const y = pad.top + 18 + Math.floor(datasetIndex / 2) * 34;
    ctx.fillStyle = dataset.color;
    ctx.fillText(`${dataset.name}`, x, y);
    ctx.fillText(`${minY.toFixed(1)}-${maxY.toFixed(1)} ${dataset.unit || ""}`, x, y + 15);
  });

  let legendX = pad.left + 8;
  for (const dataset of datasets) {
    ctx.fillStyle = dataset.color;
    ctx.fillRect(legendX, 10, 10, 10);
    ctx.fillStyle = themeColor("--text");
    ctx.fillText(dataset.name, legendX + 14, 20);
    legendX += ctx.measureText(dataset.name).width + 34;
  }

  canvas._chart = { datasets, options, minX, maxX, pad, plotW, plotH, xScale, xUnscale };
  drawScrubLine(canvas);
}

function nearestSampleIndex(minutes) {
  const samples = state.chartSamples || [];
  if (!samples.length) return null;
  let best = 0;
  let bestDistance = Infinity;
  for (let index = 0; index < samples.length; index += 1) {
    const distance = Math.abs(samples[index].timeSeconds / 60 - minutes);
    if (distance < bestDistance) {
      best = index;
      bestDistance = distance;
    }
  }
  return best;
}

function setScrubIndex(index) {
  const samples = state.chartSamples || [];
  if (!samples.length || index === null || index === undefined) {
    els.scrubber.classList.add("hidden");
    state.scrubIndex = null;
    return;
  }
  state.scrubIndex = Math.max(0, Math.min(index, samples.length - 1));
  renderScrubber(samples[state.scrubIndex]);
  drawChartsWithoutReset();
}

function renderScrubber(sample) {
  const pressures = sample.pressures
    ? Object.entries(sample.pressures).map(([tank, value]) => `T${tank}: ${fmtPressure(value, 1)}`).join(", ")
    : "—";
  const ppo2 = sample.ppo2
    ? sample.ppo2.map((reading) => `${reading.sensor ?? "avg"}: ${fmtNum(reading.value, 2)}`).join(", ")
    : "—";
  const deco = sample.deco
    ? `${sample.deco.type || "—"} ${fmtSeconds(sample.deco.time)} @ ${fmtDepth(sample.deco.depth, 0)}`
    : "—";
  els.scrubber.classList.remove("hidden");
  els.scrubber.innerHTML = [
    `<div class="scrub-item"><span class="label">Time</span><span class="value">${fmt(sample.time)}</span></div>`,
    `<div class="scrub-item"><span class="label">Depth</span><span class="value">${fmtDepth(sample.depth, 2)}</span></div>`,
    `<div class="scrub-item"><span class="label">Temp</span><span class="value">${fmtTemperature(sample.temperature, 1)}</span></div>`,
    `<div class="scrub-item"><span class="label">Setpoint</span><span class="value">${fmtNum(sample.setpoint, 2)}</span></div>`,
    `<div class="scrub-item"><span class="label">Deco</span><span class="value">${deco}</span></div>`,
    `<div class="scrub-item"><span class="label">TTS</span><span class="value">${fmtSeconds(sample.tts)}</span></div>`,
    `<div class="scrub-item"><span class="label">Pressure</span><span class="value">${pressures}</span></div>`,
    `<div class="scrub-item"><span class="label">PPO2</span><span class="value">${ppo2}</span></div>`,
  ].join("");
}

function drawChartsWithoutReset() {
  if (!state.selected) return;
  const samples = state.selected.samples || [];
  const allSeries = availableSeries(samples);
  const visible = allSeries.filter((item) => state.visibleSeries.has(item.id));
  drawLineChart(els.profileChart, visible.length ? visible : allSeries.slice(0, 1), { yLabel: "value" });
}

function drawScrubLine(canvas) {
  const chart = canvas._chart;
  const samples = state.chartSamples || [];
  if (!chart || state.scrubIndex === null || state.scrubIndex === undefined || !samples[state.scrubIndex]) return;
  const ctx = canvas.getContext("2d");
  const minutes = samples[state.scrubIndex].timeSeconds / 60;
  const x = chart.xScale(minutes);
  ctx.save();
  ctx.strokeStyle = themeColor("--chart-cursor");
  ctx.lineWidth = 1;
  ctx.setLineDash([4, 4]);
  ctx.beginPath();
  ctx.moveTo(x, chart.pad.top);
  ctx.lineTo(x, chart.pad.top + chart.plotH);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.fillStyle = themeColor("--chart-cursor");
  ctx.beginPath();
  ctx.arc(x, chart.pad.top + 8, 4, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}

function scrubFromPointer(canvas, event) {
  const chart = canvas._chart;
  if (!chart) return;
  const rect = canvas.getBoundingClientRect();
  const scaleX = canvas.width / rect.width;
  const canvasX = (event.clientX - rect.left) * scaleX;
  const clampedX = Math.max(chart.pad.left, Math.min(chart.pad.left + chart.plotW, canvasX));
  const minutes = chart.xUnscale(clampedX);
  const index = nearestSampleIndex(minutes);
  if (index !== null) {
    setScrubIndex(index);
  }
}

els.profileChart.addEventListener("pointermove", (event) => scrubFromPointer(els.profileChart, event));
els.profileChart.addEventListener("pointerdown", (event) => scrubFromPointer(els.profileChart, event));

els.refresh.addEventListener("click", () => {
  loadSummaries().catch((error) => {
    els.status.innerHTML = `<span class="error">${error.message}</span>`;
  });
});

els.search.addEventListener("input", (event) => {
  state.query = event.target.value.trim().toLowerCase();
  renderList();
  renderSummary();
});

els.computerFilter.addEventListener("change", (event) => {
  state.computer = event.target.value;
  renderList();
  renderSummary();
});

els.divesView.addEventListener("click", () => {
  state.view = "dives";
  localStorage.setItem("dclvView", state.view);
  applyView();
});

els.summaryView.addEventListener("click", () => {
  state.view = "summary";
  localStorage.setItem("dclvView", state.view);
  applyView();
});

document.querySelectorAll("button.sort").forEach((button) => {
  button.addEventListener("click", () => {
    const key = button.dataset.sort;
    if (state.sortKey === key) {
      state.sortDir = state.sortDir === "asc" ? "desc" : "asc";
    } else {
      state.sortKey = key;
      state.sortDir = key === "datetime" ? "desc" : "asc";
    }
    localStorage.setItem("dclvSortKey", state.sortKey);
    localStorage.setItem("dclvSortDir", state.sortDir);
    renderList();
  });
});

els.metric.addEventListener("click", () => {
  state.units = "metric";
  localStorage.setItem("perdixUnits", state.units);
  updateUnitToggle();
  renderList();
  renderSummary();
  if (state.selected) renderDetail(state.selected);
});

els.imperial.addEventListener("click", () => {
  state.units = "imperial";
  localStorage.setItem("perdixUnits", state.units);
  updateUnitToggle();
  renderList();
  renderSummary();
  if (state.selected) renderDetail(state.selected);
});

els.seriesControls.addEventListener("change", (event) => {
  if (event.target.type !== "checkbox") return;
  if (event.target.checked) {
    state.visibleSeries.add(event.target.value);
  } else {
    state.visibleSeries.delete(event.target.value);
  }
  drawChartsWithoutReset();
});

els.lightTheme.addEventListener("click", () => {
  state.theme = "light";
  localStorage.setItem("perdixTheme", state.theme);
  applyTheme();
  if (state.selected) drawChartsWithoutReset();
});

els.darkTheme.addEventListener("click", () => {
  state.theme = "dark";
  localStorage.setItem("perdixTheme", state.theme);
  applyTheme();
  if (state.selected) drawChartsWithoutReset();
});

els.dives.addEventListener("click", (event) => {
  const row = event.target.closest("tr[data-id]");
  if (!row) return;
  selectDive(row.dataset.id).catch((error) => {
    els.status.innerHTML = `<span class="error">${error.message}</span>`;
  });
});

applyTheme();
applyView();
initSplitter();
updateUnitToggle();
loadSummaries().catch((error) => {
  els.status.innerHTML = `<span class="error">${error.message}</span>`;
});
