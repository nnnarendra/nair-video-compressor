const PRESET_SPECS = {
  ringan: { label: "libx264 · CRF 20 · medium · AAC 160k" },
  seimbang: { label: "libx264 · CRF 23 · medium · AAC 128k" },
  youtube: { label: "libx264 · CRF 18 · slow · AAC 192k" },
  kecil: { label: "libx264 · CRF 28 · fast · AAC 96k" },
  "265": { label: "libx265 · CRF 26 · medium · AAC 128k" },
};

const state = {
  settings: {
    Preset: "seimbang",
    Resolusi: "",
    OutputDir: "",
    UseGpu: false,
  },
  ffmpegStatus: {
    available: false,
    source: "missing",
    ffmpegPath: null,
    version: null,
    gpuAvailable: false,
  },
  queue: [],
  isCompressing: false,
  isDownloading: false,
  lastOutputDir: "",
};

const el = {};

function getTauri() {
  return window.__TAURI__ || null;
}

function escapeHtml(str) {
  return String(str ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function formatBytes(bytes) {
  const value = Number(bytes) || 0;
  if (value <= 0) return "0.0 MB";
  const mb = value / (1024 * 1024);
  if (mb >= 1024) {
    return `${(mb / 1024).toFixed(2)} GB`;
  }
  return `${mb.toFixed(1)} MB`;
}

function formatDuration(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  if (total <= 0) return "?";
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

function showNotice(message, isError = false) {
  el.noticeText.textContent = message;
  el.noticeBar.classList.toggle("is-error", Boolean(isError));
  el.noticeBar.classList.remove("is-hidden");
}

function hideNotice() {
  el.noticeBar.classList.add("is-hidden");
  el.noticeText.textContent = "";
}

async function persistSettings() {
  const tauri = getTauri();
  if (!tauri?.core?.invoke) return;
  try {
    await tauri.core.invoke("save_settings", { settings: state.settings });
  } catch (err) {
    showNotice(`Failed to save settings: ${err}`, true);
  }
}

function syncConfigUI() {
  const { Preset, Resolusi, OutputDir, UseGpu } = state.settings;
  const locked = state.isCompressing;

  el.presetSelect.value = Preset;
  el.presetSelect.disabled = locked;
  el.presetMeta.textContent = PRESET_SPECS[Preset]?.label || PRESET_SPECS.seimbang.label;

  el.resolusiButtons.forEach((btn) => {
    const active = btn.dataset.res === Resolusi;
    btn.classList.toggle("is-active", active);
    btn.disabled = locked;
  });

  if (Preset === "kecil" && !Resolusi) {
    el.resolusiNote.textContent = "AUTO → 720P (COMPACT PRESET)";
    el.resolusiNote.classList.add("is-accent");
  } else if (Resolusi) {
    el.resolusiNote.textContent = `Target max height ${Resolusi}p`;
    el.resolusiNote.classList.remove("is-accent");
  } else {
    el.resolusiNote.textContent = "Original resolution preserved";
    el.resolusiNote.classList.remove("is-accent");
  }

  el.gpuButtons.forEach((btn) => {
    const isGpuBtn = btn.dataset.gpu === "true";
    btn.classList.toggle("is-active", isGpuBtn === Boolean(UseGpu));
    btn.disabled = locked;
  });

  if (Preset === "265") {
    el.gpuNote.textContent = "H.265 preset always uses CPU (libx265)";
    el.gpuNote.classList.remove("is-accent");
  } else if (UseGpu) {
    el.gpuNote.textContent = state.ffmpegStatus.gpuAvailable
      ? "NVENC active (auto-fallback to CPU)"
      : "NVENC selected (verified on start)";
    el.gpuNote.classList.toggle("is-accent", state.ffmpegStatus.gpuAvailable);
  } else {
    el.gpuNote.textContent = "CPU stable (libx264)";
    el.gpuNote.classList.remove("is-accent");
  }

  if (OutputDir) {
    el.outputPathDisplay.textContent = OutputDir;
    el.outputPathDisplay.title = OutputDir;
  } else {
    el.outputPathDisplay.textContent = "compressed/ (next to source)";
    el.outputPathDisplay.title = "compressed/ subfolder next to each source video";
  }

  el.btnPickOutput.disabled = locked;
  el.btnResetOutput.disabled = locked || !OutputDir;
  el.btnPickFiles.disabled = locked;
  el.btnPickFolder.disabled = locked;
  el.btnRecheck.disabled = locked || state.isDownloading;
}

function syncHeaderAndBanner() {
  const st = state.ffmpegStatus;

  if (st.available) {
    const srcLabel = st.source === "local" ? "LOCAL" : st.source === "appdata" ? "APPDATA" : "PATH";
    el.ffmpegStatusText.textContent = `READY · ${srcLabel}`;
    el.ffmpegStatusText.classList.remove("is-muted", "is-red");

    el.hardwareStatusText.textContent = st.gpuAvailable ? "NVENC READY" : "CPU ONLY";
    el.hardwareStatusText.classList.remove("is-muted");
    el.hardwareStatusText.classList.toggle("is-red", st.gpuAvailable);

    if (!state.isDownloading) {
      el.ffmpegBanner.classList.add("is-hidden");
    }
  } else {
    el.ffmpegStatusText.textContent = "MISSING";
    el.ffmpegStatusText.classList.remove("is-muted");
    el.ffmpegStatusText.classList.add("is-red");

    el.hardwareStatusText.textContent = "—";
    el.hardwareStatusText.classList.add("is-muted");
    el.hardwareStatusText.classList.remove("is-red");

    el.ffmpegBanner.classList.remove("is-hidden");
  }

  syncActionButtons();
}

function syncActionButtons() {
  const hasQueue = state.queue.length > 0;
  el.btnClear.disabled = !hasQueue || state.isCompressing;
  el.btnStart.disabled = !hasQueue || !state.ffmpegStatus.available || state.isCompressing || state.isDownloading;

  el.btnCancel.classList.toggle("is-hidden", !state.isCompressing);
  el.btnStart.classList.toggle("is-hidden", state.isCompressing);
}

function renderFooterSummary() {
  const totalCount = state.queue.length;
  const totalBefore = state.queue.reduce((acc, item) => acc + (item.sizeBytes || 0), 0);
  const doneItems = state.queue.filter((item) => item.status === "done");
  const fileLabel = totalCount === 1 ? "FILE" : "FILES";

  if (doneItems.length > 0) {
    const doneBefore = doneItems.reduce((acc, item) => acc + (item.sizeBytes || 0), 0);
    const doneAfter = doneItems.reduce((acc, item) => acc + (item.afterBytes || 0), 0);
    const savedPct = doneBefore > 0 ? ((1 - doneAfter / doneBefore) * 100).toFixed(1) : "0.0";
    el.footerSummary.textContent = `${doneItems.length}/${totalCount} DONE · ${formatBytes(doneBefore)} → ${formatBytes(doneAfter)} (SAVED ${savedPct}%)`;
  } else {
    el.footerSummary.textContent = `${totalCount} ${fileLabel} · ${formatBytes(totalBefore)}`;
  }
}

function renderRowStatusMeta(item) {
  if (item.status === "pending") {
    return `<span>Queued · ${formatDuration(item.durationSecs)}</span><span>0%</span>`;
  }
  if (item.status === "running") {
    const parts = [];
    if (item.durationSecs > 0) {
      parts.push(`${formatDuration(item.elapsedSecs)} / ${formatDuration(item.durationSecs)}`);
    } else if (item.elapsedSecs > 0) {
      parts.push(formatDuration(item.elapsedSecs));
    } else {
      parts.push("Starting...");
    }
    if (item.fps) parts.push(`${item.fps.toFixed(0)} fps`);
    if (item.speed) parts.push(`${item.speed.toFixed(2)}x`);
    return `<span>${escapeHtml(parts.join(" · "))}</span><span>${Math.round(item.percent || 0)}%</span>`;
  }
  if (item.status === "done") {
    const mode = item.usedGpu ? "NVENC" : "CPU";
    return `<span>Done (${mode})</span><span>100%</span>`;
  }
  if (item.status === "cancelled") {
    return `<span class="is-error">Cancelled</span><span>${Math.round(item.percent || 0)}%</span>`;
  }
  return `<span class="is-error" title="${escapeHtml(item.error || "Failed")}">${escapeHtml(item.error || "Failed")}</span><span>ERROR</span>`;
}

function renderQueue() {
  if (state.queue.length === 0) {
    el.queueList.innerHTML = `
      <div class="queue-empty">
        <p class="empty-title">QUEUE EMPTY</p>
        <p class="empty-sub">Drag and drop video files or folders above to get started.</p>
      </div>
    `;
    renderFooterSummary();
    syncActionButtons();
    return;
  }

  el.queueList.innerHTML = state.queue
    .map((item, idx) => {
      const pct = Math.max(0, Math.min(100, Number(item.percent) || 0));
      const fillClass = item.status === "error" || item.status === "cancelled" ? "progress-fill is-red" : "progress-fill";
      const rowClass = item.status === "running" ? "queue-row is-running" : "queue-row";

      let resultHtml = `<span class="is-muted">—</span>`;
      if (item.status === "done") {
        const sign = item.savedPercent >= 0 ? `-${item.savedPercent.toFixed(1)}%` : `+${Math.abs(item.savedPercent).toFixed(1)}%`;
        resultHtml = `<span class="result-saved">${formatBytes(item.afterBytes)}</span><span class="result-pct">(${sign})</span>`;
      } else if (item.status === "error") {
        resultHtml = `<span class="result-pct">FAILED</span>`;
      } else if (item.status === "cancelled") {
        resultHtml = `<span class="result-pct">CANCELLED</span>`;
      }

      const openBtn = item.status === "done" && item.outputPath
        ? `<button type="button" class="btn-icon" data-action="open" data-index="${idx}" title="Open output folder">↗</button>`
        : "";
      const removeDisabled = state.isCompressing ? "disabled" : "";

      return `
        <div class="${rowClass}" data-index="${idx}">
          <span class="col-num">${String(idx + 1).padStart(2, "0")}</span>
          <div class="col-file">
            <div class="file-name" title="${escapeHtml(item.fileName)}">${escapeHtml(item.fileName)}</div>
            <div class="file-path" title="${escapeHtml(item.path)}">${escapeHtml(item.path)}</div>
          </div>
          <span class="col-size">${formatBytes(item.sizeBytes)}</span>
          <div class="progress-cell">
            <div class="progress-track">
              <div class="${fillClass}" style="width: ${pct}%"></div>
            </div>
            <div class="progress-meta">${renderRowStatusMeta(item)}</div>
          </div>
          <div class="col-result">${resultHtml}</div>
          <div class="col-action">
            ${openBtn}
            <button type="button" class="btn-icon" data-action="remove" data-index="${idx}" title="Remove from queue" ${removeDisabled}>×</button>
          </div>
        </div>
      `;
    })
    .join("");

  renderFooterSummary();
  syncActionButtons();
}

async function addPathsToQueue(paths) {
  const tauri = getTauri();
  if (!tauri?.core?.invoke || !Array.isArray(paths) || paths.length === 0) return;

  try {
    const scanned = await tauri.core.invoke("scan_inputs", { paths });
    if (!Array.isArray(scanned) || scanned.length === 0) {
      showNotice("No supported video files (.mp4, .mov, .mkv, .avi, .webm) found in the selection.", true);
      return;
    }

    const existingPaths = new Set(state.queue.map((q) => q.path.toLowerCase()));
    let addedCount = 0;
    for (const item of scanned) {
      const key = item.path.toLowerCase();
      if (existingPaths.has(key)) continue;
      existingPaths.add(key);
      state.queue.push({
        path: item.path,
        fileName: item.fileName,
        sizeBytes: item.sizeBytes,
        durationSecs: item.durationSecs,
        status: "pending",
        percent: 0,
        elapsedSecs: 0,
        fps: null,
        speed: null,
        outputPath: "",
        afterBytes: 0,
        savedPercent: 0,
        error: "",
        usedGpu: false,
      });
      addedCount++;
    }

    if (addedCount > 0) {
      hideNotice();
    } else {
      showNotice("All selected videos are already in the queue.");
    }
    renderQueue();
  } catch (err) {
    showNotice(`Failed to scan inputs: ${err}`, true);
  }
}

async function refreshFfmpegStatus(testGpu = true) {
  const tauri = getTauri();
  if (!tauri?.core?.invoke) return;

  el.ffmpegStatusText.textContent = "CHECKING...";
  el.ffmpegStatusText.classList.add("is-muted");
  try {
    const status = await tauri.core.invoke("check_ffmpeg", { testGpu });
    state.ffmpegStatus = status;
    syncHeaderAndBanner();
    syncConfigUI();
  } catch (err) {
    showNotice(`Failed to check FFmpeg: ${err}`, true);
  }
}

async function handleDownloadFfmpeg() {
  const tauri = getTauri();
  if (!tauri?.core?.invoke || state.isDownloading) return;

  state.isDownloading = true;
  el.btnDownloadFfmpeg.disabled = true;
  el.downloadProgressWrap.classList.remove("is-hidden");
  el.downloadProgressFill.style.width = "0%";
  el.downloadStageText.textContent = "Starting FFmpeg Essentials download...";
  el.downloadPctText.textContent = "0%";
  syncConfigUI();
  syncActionButtons();

  try {
    const status = await tauri.core.invoke("download_ffmpeg");
    state.ffmpegStatus = status;
    state.isDownloading = false;
    el.downloadProgressWrap.classList.add("is-hidden");
    el.btnDownloadFfmpeg.disabled = false;
    syncHeaderAndBanner();
    syncConfigUI();
    showNotice("FFmpeg Essentials downloaded and ready to use.");
  } catch (err) {
    state.isDownloading = false;
    el.btnDownloadFfmpeg.disabled = false;
    syncConfigUI();
    syncActionButtons();
    showNotice(`Failed to download FFmpeg: ${err}`, true);
  }
}

async function handleStartCompression() {
  const tauri = getTauri();
  if (!tauri?.core?.invoke || state.isCompressing || state.queue.length === 0) return;

  if (!state.ffmpegStatus.available) {
    showNotice("FFmpeg is not available. Please download FFmpeg first.", true);
    return;
  }

  hideNotice();
  const hasUnfinished = state.queue.some((q) => q.status !== "done");
  const targets = state.queue.filter((q) => (hasUnfinished ? q.status !== "done" : true));

  for (const item of targets) {
    item.status = "pending";
    item.percent = 0;
    item.elapsedSecs = 0;
    item.fps = null;
    item.speed = null;
    item.error = "";
    item.outputPath = "";
    item.afterBytes = 0;
    item.savedPercent = 0;
  }

  state.isCompressing = true;
  syncConfigUI();
  renderQueue();

  const itemsPayload = targets.map((item) => ({
    path: item.path,
    fileName: item.fileName,
    sizeBytes: item.sizeBytes,
    durationSecs: item.durationSecs,
  }));

  try {
    await tauri.core.invoke("start_compression", {
      items: itemsPayload,
      settings: state.settings,
    });
  } catch (err) {
    state.isCompressing = false;
    syncConfigUI();
    syncActionButtons();
    showNotice(`Failed to start compression: ${err}`, true);
  }
}

async function handleCancelCompression() {
  const tauri = getTauri();
  if (!tauri?.core?.invoke || !state.isCompressing) return;

  el.btnCancel.disabled = true;
  try {
    await tauri.core.invoke("cancel_compression");
  } catch (err) {
    showNotice(`Failed to cancel compression: ${err}`, true);
  } finally {
    el.btnCancel.disabled = false;
  }
}

async function openOutputFolder(explicitPath = "") {
  const tauri = getTauri();
  if (!tauri?.core?.invoke) return;

  let target = explicitPath || state.settings.OutputDir || state.lastOutputDir;
  if (!target && state.queue.length > 0) {
    const first = state.queue[0];
    if (first.outputPath) {
      target = first.outputPath;
    } else {
      const sepIdx = Math.max(first.path.lastIndexOf("\\"), first.path.lastIndexOf("/"));
      const parent = sepIdx > 0 ? first.path.slice(0, sepIdx) : ".";
      target = `${parent}\\compressed`;
    }
  }

  if (!target) {
    showNotice("No output folder yet. Choose an output folder or add a video first.");
    return;
  }

  try {
    await tauri.core.invoke("open_folder", { path: target });
  } catch (err) {
    showNotice(`${err}`, true);
  }
}

async function registerTauriEvents() {
  const listen = getTauri()?.event?.listen;
  if (!listen) return;

  await listen("tauri://drag-enter", () => {
    if (!state.isCompressing) {
      el.dropZone.classList.add("is-dragover");
    }
  });

  await listen("tauri://drag-leave", () => {
    el.dropZone.classList.remove("is-dragover");
  });

  await listen("tauri://drag-drop", (event) => {
    el.dropZone.classList.remove("is-dragover");
    if (state.isCompressing) return;
    const paths = event.payload?.paths;
    if (Array.isArray(paths) && paths.length > 0) {
      addPathsToQueue(paths);
    }
  });

  await listen("ffmpeg-download-progress", (event) => {
    const p = event.payload || {};
    el.downloadProgressWrap.classList.remove("is-hidden");
    el.downloadStageText.textContent = p.message || "Downloading...";
    if (typeof p.percent === "number") {
      const pctText = `${p.percent.toFixed(1)}%`;
      el.downloadProgressFill.style.width = `${Math.min(100, Math.max(0, p.percent))}%`;
      el.downloadPctText.textContent = p.totalBytes
        ? `${formatBytes(p.downloadedBytes)} / ${formatBytes(p.totalBytes)} (${pctText})`
        : pctText;
    } else if (p.stage === "extracting") {
      el.downloadProgressFill.style.width = "100%";
      el.downloadPctText.textContent = "EXTRACTING";
    }
  });

  await listen("gpu-fallback", (event) => {
    state.settings.UseGpu = false;
    state.ffmpegStatus.gpuAvailable = false;
    syncHeaderAndBanner();
    syncConfigUI();
    showNotice(event.payload?.reason || "GPU NVENC unavailable, switched to CPU.", false);
  });

  await listen("compression-progress", (event) => {
    const p = event.payload || {};
    const item = state.queue.find((q) => q.path === p.path);
    if (!item) return;
    item.status = "running";
    item.percent = p.percent ?? item.percent;
    item.elapsedSecs = p.elapsedSecs ?? item.elapsedSecs;
    item.durationSecs = p.durationSecs || item.durationSecs;
    item.fps = p.fps ?? null;
    item.speed = p.speed ?? null;
    renderQueue();
  });

  await listen("compression-item-done", (event) => {
    const p = event.payload || {};
    const item = state.queue.find((q) => q.path === p.path);
    if (!item) return;
    item.status = "done";
    item.percent = 100;
    item.fps = null;
    item.speed = null;
    item.outputPath = p.outputPath || "";
    item.afterBytes = p.afterBytes || 0;
    item.savedPercent = p.savedPercent ?? 0;
    item.usedGpu = Boolean(p.usedGpu);
    if (item.outputPath) {
      state.lastOutputDir = item.outputPath;
    }
    renderQueue();
  });

  await listen("compression-item-error", (event) => {
    const p = event.payload || {};
    const item = state.queue.find((q) => q.path === p.path);
    if (!item) return;
    item.status = "error";
    item.error = p.error || "Failed to compress video.";
    item.fps = null;
    item.speed = null;
    renderQueue();
  });

  await listen("compression-item-cancelled", (event) => {
    const p = event.payload || {};
    const item = state.queue.find((q) => q.path === p.path);
    if (!item) return;
    item.status = "cancelled";
    item.fps = null;
    item.speed = null;
    renderQueue();
  });

  await listen("compression-finished", (event) => {
    const p = event.payload || {};
    state.isCompressing = false;
    syncConfigUI();
    renderQueue();

    if (p.cancelled) {
      showNotice("Compression cancelled by user.");
    } else if (p.failed > 0) {
      showNotice(`Finished: ${p.succeeded} succeeded, ${p.failed} failed.`, true);
    } else if (p.succeeded > 0) {
      const savedPct =
        p.totalBeforeBytes > 0
          ? ((1 - p.totalAfterBytes / p.totalBeforeBytes) * 100).toFixed(1)
          : "0.0";
      showNotice(
        `Compression complete (${p.succeeded} ${p.succeeded === 1 ? "file" : "files"}): ${formatBytes(p.totalBeforeBytes)} → ${formatBytes(p.totalAfterBytes)} (saved ${savedPct}%).`
      );
    }
  });
}

function bindDomEvents() {
  document.addEventListener("dragover", (e) => e.preventDefault());
  document.addEventListener("drop", (e) => e.preventDefault());

  el.btnDismissNotice.addEventListener("click", hideNotice);
  el.btnRecheck.addEventListener("click", () => refreshFfmpegStatus(true));
  el.btnDownloadFfmpeg.addEventListener("click", handleDownloadFfmpeg);

  el.btnPickFiles.addEventListener("click", async () => {
    const openDialog = getTauri()?.dialog?.open;
    if (!openDialog || state.isCompressing) return;
    const selected = await openDialog({
      multiple: true,
      filters: [{ name: "Video", extensions: ["mp4", "mov", "mkv", "avi", "webm"] }],
    });
    if (Array.isArray(selected) && selected.length > 0) {
      await addPathsToQueue(selected);
    } else if (typeof selected === "string" && selected) {
      await addPathsToQueue([selected]);
    }
  });

  el.btnPickFolder.addEventListener("click", async () => {
    const openDialog = getTauri()?.dialog?.open;
    if (!openDialog || state.isCompressing) return;
    const selected = await openDialog({ directory: true, multiple: false });
    if (typeof selected === "string" && selected) {
      await addPathsToQueue([selected]);
    }
  });

  el.presetSelect.addEventListener("change", () => {
    state.settings.Preset = el.presetSelect.value;
    syncConfigUI();
    persistSettings();
  });

  el.resolusiButtons.forEach((btn) => {
    btn.addEventListener("click", () => {
      if (state.isCompressing) return;
      state.settings.Resolusi = btn.dataset.res ?? "";
      syncConfigUI();
      persistSettings();
    });
  });

  el.gpuButtons.forEach((btn) => {
    btn.addEventListener("click", () => {
      if (state.isCompressing) return;
      state.settings.UseGpu = btn.dataset.gpu === "true";
      syncConfigUI();
      persistSettings();
    });
  });

  el.btnPickOutput.addEventListener("click", async () => {
    const openDialog = getTauri()?.dialog?.open;
    if (!openDialog || state.isCompressing) return;
    const selected = await openDialog({ directory: true, multiple: false });
    if (typeof selected === "string" && selected) {
      state.settings.OutputDir = selected;
      syncConfigUI();
      persistSettings();
    }
  });

  el.btnResetOutput.addEventListener("click", () => {
    if (state.isCompressing) return;
    state.settings.OutputDir = "";
    syncConfigUI();
    persistSettings();
  });

  el.btnOpenOutput.addEventListener("click", () => openOutputFolder());

  el.queueList.addEventListener("click", (event) => {
    const btn = event.target.closest("button[data-action]");
    if (!btn) return;
    const idx = Number(btn.dataset.index);
    const item = state.queue[idx];
    if (!item) return;

    if (btn.dataset.action === "remove" && !state.isCompressing) {
      state.queue.splice(idx, 1);
      renderQueue();
    } else if (btn.dataset.action === "open" && item.outputPath) {
      openOutputFolder(item.outputPath);
    }
  });

  el.btnClear.addEventListener("click", () => {
    if (state.isCompressing) return;
    state.queue = [];
    renderQueue();
  });

  el.btnStart.addEventListener("click", handleStartCompression);
  el.btnCancel.addEventListener("click", handleCancelCompression);
}

function cacheDom() {
  el.appVersion = document.getElementById("app-version");
  el.ffmpegStatusText = document.getElementById("ffmpeg-status-text");
  el.hardwareStatusText = document.getElementById("hardware-status-text");
  el.btnRecheck = document.getElementById("btn-recheck");

  el.ffmpegBanner = document.getElementById("ffmpeg-banner");
  el.btnDownloadFfmpeg = document.getElementById("btn-download-ffmpeg");
  el.downloadProgressWrap = document.getElementById("download-progress-wrap");
  el.downloadProgressFill = document.getElementById("download-progress-fill");
  el.downloadStageText = document.getElementById("download-stage-text");
  el.downloadPctText = document.getElementById("download-pct-text");

  el.noticeBar = document.getElementById("notice-bar");
  el.noticeText = document.getElementById("notice-text");
  el.btnDismissNotice = document.getElementById("btn-dismiss-notice");

  el.dropZone = document.getElementById("drop-zone");
  el.btnPickFiles = document.getElementById("btn-pick-files");
  el.btnPickFolder = document.getElementById("btn-pick-folder");

  el.presetSelect = document.getElementById("preset-select");
  el.presetMeta = document.getElementById("preset-meta");
  el.resolusiButtons = Array.from(document.querySelectorAll("#resolusi-group .seg-btn"));
  el.resolusiNote = document.getElementById("resolusi-note");
  el.gpuButtons = Array.from(document.querySelectorAll("#gpu-group .seg-btn"));
  el.gpuNote = document.getElementById("gpu-note");

  el.outputPathDisplay = document.getElementById("output-path-display");
  el.btnPickOutput = document.getElementById("btn-pick-output");
  el.btnResetOutput = document.getElementById("btn-reset-output");
  el.btnOpenOutput = document.getElementById("btn-open-output");

  el.queueList = document.getElementById("queue-list");
  el.footerSummary = document.getElementById("footer-summary");
  el.btnClear = document.getElementById("btn-clear");
  el.btnCancel = document.getElementById("btn-cancel");
  el.btnStart = document.getElementById("btn-start");
}

async function init() {
  cacheDom();
  bindDomEvents();
  syncConfigUI();
  renderQueue();

  const tauri = getTauri();
  if (!tauri?.core?.invoke) {
    el.ffmpegStatusText.textContent = "PREVIEW";
    el.hardwareStatusText.textContent = "BROWSER";
    showNotice("Browser preview mode — run via the Tauri desktop app to access FFmpeg and drag & drop.");
    return;
  }

  try {
    const [info, savedSettings] = await Promise.all([
      tauri.core.invoke("get_app_info"),
      tauri.core.invoke("load_settings"),
    ]);
    if (info?.version) {
      el.appVersion.textContent = `v${info.version}`;
    }
    if (savedSettings) {
      state.settings = {
        Preset: savedSettings.Preset || "seimbang",
        Resolusi: savedSettings.Resolusi ?? "",
        OutputDir: savedSettings.OutputDir ?? "",
        UseGpu: Boolean(savedSettings.UseGpu),
      };
    }
  } catch (err) {
    showNotice(`Failed to load initial settings: ${err}`, true);
  }

  syncConfigUI();
  await registerTauriEvents();
  await refreshFfmpegStatus(true);
}

window.addEventListener("DOMContentLoaded", init);
