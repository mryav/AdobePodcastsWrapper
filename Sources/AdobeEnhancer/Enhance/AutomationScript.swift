import Foundation

/// The script injected into podcast.adobe.com. It drives the page the way a
/// person would: drop the file on the upload control, watch for progress, click
/// download, then hand the resulting bytes back to the app.
///
/// Adobe ships an unversioned React bundle, so every lookup here is a heuristic
/// over text/ARIA rather than a brittle CSS path. If Adobe redesigns the page,
/// drop a patched copy at ~/Library/Application Support/AdobeEnhancer/automation.js
/// and it will be used instead of this built-in version.
enum AutomationScript {

    static func load() -> String {
        let override = AppPaths.automationOverride
        if let custom = try? String(contentsOf: override, encoding: .utf8), !custom.isEmpty {
            Log.web("using automation override at \(override.path)")
            return custom
        }
        return builtIn
    }

    static let builtIn: String = #"""
(() => {
"use strict";
if (window.__enhancerInstalled) return;
window.__enhancerInstalled = true;

const post = (m) => { try { window.webkit.messageHandlers.enhancer.postMessage(m); } catch (e) {} };
const log = (m) => post({ type: "log", message: String(m) });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ------------------------------------------------------------------ *
 * DOM helpers. Everything is shadow-DOM aware because Adobe mixes in
 * Spectrum web components alongside plain React markup.
 * ------------------------------------------------------------------ */

function deepQueryAll(selector) {
  const out = [];
  const seen = new Set();
  const visit = (root) => {
    if (!root || seen.has(root)) return;
    seen.add(root);
    try { root.querySelectorAll(selector).forEach((el) => out.push(el)); } catch (e) {}
    let all = [];
    try { all = root.querySelectorAll("*"); } catch (e) {}
    for (const el of all) if (el.shadowRoot) visit(el.shadowRoot);
  };
  visit(document);
  return out;
}

function isVisible(el) {
  if (!el || !el.getBoundingClientRect) return false;
  const rect = el.getBoundingClientRect();
  if (rect.width < 2 || rect.height < 2) return false;
  const style = window.getComputedStyle(el);
  if (!style) return true;
  return style.visibility !== "hidden" && style.display !== "none" && parseFloat(style.opacity || "1") > 0.05;
}

function labelOf(el) {
  const bits = [
    el.innerText || el.textContent || "",
    el.getAttribute && el.getAttribute("aria-label") || "",
    el.getAttribute && el.getAttribute("title") || "",
    el.getAttribute && el.getAttribute("data-testid") || "",
  ];
  return bits.join(" ").replace(/\s+/g, " ").trim();
}

function isDisabled(el) {
  return !!(el.disabled || el.getAttribute("aria-disabled") === "true" || el.classList.contains("is-disabled"));
}

function clickEl(el) {
  try { el.scrollIntoView({ block: "center", behavior: "instant" }); } catch (e) {}
  const opts = { bubbles: true, cancelable: true, composed: true, view: window, button: 0 };
  for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup"]) {
    try {
      const Ctor = type.startsWith("pointer") && window.PointerEvent ? PointerEvent : MouseEvent;
      el.dispatchEvent(new Ctor(type, opts));
    } catch (e) {}
  }
  try { el.click(); } catch (e) {}
}

// Lets the app tell a long-but-healthy wait apart from a dead JS context.
function heartbeat(tick) {
  if (tick % 20 === 0) post({ type: "tick" });
}

async function waitFor(predicate, timeoutMs, onTick) {
  const deadline = Date.now() + timeoutMs;
  let ticks = 0;
  while (Date.now() < deadline) {
    const value = predicate();          // may throw to abort the whole wait
    if (value) return value;
    if (onTick) onTick(ticks);
    ticks++;
    await sleep(500);
  }
  return null;
}

/* ------------------------------------------------------------------ *
 * Download interception. The page hands the finished audio over as a
 * blob: URL on an <a download>; we grab it instead of letting WebKit
 * run its own download UI.
 * ------------------------------------------------------------------ */

const blobRegistry = new Map();
const nativeCreateObjectURL = URL.createObjectURL.bind(URL);
URL.createObjectURL = function (obj) {
  const url = nativeCreateObjectURL(obj);
  try { if (obj instanceof Blob) blobRegistry.set(url, obj); } catch (e) {}
  return url;
};

let downloadWaiter = null;
function armDownloadCapture() {
  return new Promise((resolve) => { downloadWaiter = resolve; });
}
function disarmDownloadCapture() { downloadWaiter = null; }
function offerDownload(url, name) {
  if (!downloadWaiter || !url) return false;
  if (/^(javascript:|#|about:)/i.test(url)) return false;
  const resolve = downloadWaiter;
  downloadWaiter = null;
  log("captured download " + url.slice(0, 60));
  resolve({ url: url, name: name || "" });
  return true;
}

document.addEventListener("click", (ev) => {
  if (!downloadWaiter) return;
  const path = ev.composedPath ? ev.composedPath() : [ev.target];
  for (const node of path) {
    if (node && node.tagName === "A" && node.href) {
      if (offerDownload(node.href, node.getAttribute("download"))) {
        ev.preventDefault();
        ev.stopImmediatePropagation();
      }
      return;
    }
  }
}, true);

const nativeAnchorClick = HTMLAnchorElement.prototype.click;
HTMLAnchorElement.prototype.click = function () {
  if (downloadWaiter && this.href && offerDownload(this.href, this.getAttribute("download"))) return;
  return nativeAnchorClick.apply(this, arguments);
};

const nativeWindowOpen = window.open;
window.open = function (url) {
  if (downloadWaiter && url && offerDownload(String(url), "")) return null;
  return nativeWindowOpen.apply(window, arguments);
};

function base64(bytes) {
  let binary = "";
  const stride = 0x8000;
  for (let i = 0; i < bytes.length; i += stride) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + stride, bytes.length)));
  }
  return btoa(binary);
}

function nameFromURL(url, fallback) {
  if (fallback) return fallback;
  try { return decodeURIComponent(new URL(url, location.href).pathname.split("/").pop() || ""); }
  catch (e) { return ""; }
}

async function deliverDownload(url, suggestedName) {
  const blob = blobRegistry.get(url);

  // Adobe hands back a presigned S3 link. Let the app fetch that itself —
  // pushing hundreds of megabytes through postMessage is slow and would mean
  // holding the whole file in the page's memory.
  if (!blob && /^https?:/i.test(url)) {
    post({ type: "dlUrl", url: url, name: nameFromURL(url, suggestedName) });
    return;
  }

  const source = blob || await (await fetch(url, { credentials: "include" })).blob();
  const total = source.size;
  post({ type: "dlStart", name: nameFromURL(url, suggestedName), mime: source.type || "", size: total });
  const chunk = 768 * 1024;
  for (let offset = 0; offset < total; offset += chunk) {
    // Slice per iteration so only one chunk is resident at a time.
    const slice = source.slice(offset, Math.min(offset + chunk, total));
    post({ type: "dlChunk", b64: base64(new Uint8Array(await slice.arrayBuffer())) });
    post({ type: "progress", phase: "download", value: Math.min(1, (offset + chunk) / total) });
  }
  post({ type: "dlEnd" });
}

/* ------------------------------------------------------------------ *
 * Getting the local file into the page. Preferred path is a fetch()
 * against the app's custom URL scheme; if WebKit blocks that, the app
 * pushes the bytes in through __enhancerPushChunk instead.
 * ------------------------------------------------------------------ */

let chunkParts = null;
let chunkResolve = null;
window.__enhancerPushChunk = function (b64) {
  const binary = atob(b64);
  const arr = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) arr[i] = binary.charCodeAt(i);
  if (chunkParts) chunkParts.push(arr);
};
window.__enhancerFinishChunks = function () {
  const resolve = chunkResolve;
  const parts = chunkParts;
  chunkResolve = null;
  chunkParts = null;
  if (resolve) resolve(parts || []);
};

function requestChunks(name, mime) {
  return new Promise((resolve) => {
    chunkParts = [];
    chunkResolve = (parts) => resolve(new File(parts, name, { type: mime }));
    post({ type: "needChunks" });
  });
}

async function loadLocalFile(url, name, mime) {
  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error("HTTP " + response.status);
    const blob = await response.blob();
    return new File([blob], name, { type: mime || blob.type });
  } catch (e) {
    log("scheme fetch unavailable (" + e + "); falling back to chunked transfer");
    return await requestChunks(name, mime);
  }
}

/* ------------------------------------------------------------------ *
 * Page-specific heuristics.
 * ------------------------------------------------------------------ */

function dismissOverlays() {
  for (const el of deepQueryAll('[data-testid="upsell-dialog-close-button"]')) {
    if (isVisible(el)) { try { el.click(); log("closed upsell dialog"); } catch (e) {} }
  }
  const dismissText = /^(accept all cookies|accept cookies|allow all|got it|ok, got it|no thanks|maybe later|not now|continue with free|skip)$/i;
  for (const el of deepQueryAll('button, [role="button"]')) {
    if (!isVisible(el)) continue;
    if (dismissText.test((el.innerText || "").trim())) { try { el.click(); } catch (e) {} }
  }
}

function findFileInput() {
  const inputs = deepQueryAll('input[type="file"]');
  for (const input of inputs) {
    const accept = (input.getAttribute("accept") || "").toLowerCase();
    if (!accept || /mp3|wav|m4a|aac|flac|ogg|audio/.test(accept)) return input;
  }
  return inputs[0] || null;
}

function signedOut() {
  if (deepQueryAll('[data-testid="user-profile-dropdown-button"]').length) return false;
  if (findFileInput()) return false;
  const text = document.body ? (document.body.innerText || "") : "";
  return /sign in|log in|sign up|create an account/i.test(text);
}

function readProgress() {
  for (const el of deepQueryAll('[role="progressbar"]')) {
    const now = el.getAttribute("aria-valuenow");
    if (now === null || now === "") continue;
    const max = parseFloat(el.getAttribute("aria-valuemax") || "100") || 100;
    const value = parseFloat(now);
    if (isFinite(value)) return Math.max(0, Math.min(1, value / max));
  }
  const text = document.body ? (document.body.innerText || "") : "";
  const match = text.match(/(\d{1,3})\s*%/);
  if (match) {
    const value = parseInt(match[1], 10);
    if (value >= 0 && value <= 100) return value / 100;
  }
  return null;
}

function readPageError() {
  const text = document.body ? (document.body.innerText || "") : "";
  const match = text.match(/(Something went wrong[^\n]{0,120}|Upload failed[^\n]{0,120}|File is too (?:large|long)[^\n]{0,120}|(?:This|That) file (?:type )?is(?:n't| not) supported[^\n]{0,120}|Unsupported file[^\n]{0,120}|We couldn.t process[^\n]{0,120}|exceeds the maximum[^\n]{0,120})/i);
  return match ? match[1].trim() : null;
}

const DOWNLOAD_TEXT = /download|save to|export/i;
const NOT_DOWNLOAD = /premium|upgrade|desktop app|app store|get the app|extension|invite|subscribe|beta|chrome|mobile/i;

function findDownloadControl() {
  for (const el of deepQueryAll('button, a, [role="button"], [role="menuitem"], [role="option"]')) {
    if (isDisabled(el) || !isVisible(el)) continue;
    const label = labelOf(el);
    if (!DOWNLOAD_TEXT.test(label) && !(el.tagName === "A" && el.hasAttribute("download"))) continue;
    if (NOT_DOWNLOAD.test(label)) continue;
    return el;
  }
  return null;
}

// After clicking Download, Adobe may open a format menu (wav / mp3 / "enhanced audio").
function findDownloadMenuItem() {
  const pattern = /(\.wav|\.mp3|wav|mp3|enhanced (?:audio|speech)|audio only|full mix|download)/i;
  for (const el of deepQueryAll('[role="menuitem"], [role="option"], [role="menuitemradio"], li button, [data-testid*="download"]')) {
    if (isDisabled(el) || !isVisible(el)) continue;
    const label = labelOf(el);
    if (pattern.test(label) && !NOT_DOWNLOAD.test(label)) return el;
  }
  return null;
}

function uploadLooksStarted(basename) {
  if (deepQueryAll('[role="progressbar"]').length) return true;
  const text = document.body ? (document.body.innerText || "") : "";
  if (basename && text.indexOf(basename) !== -1) return true;
  return /uploading|processing|enhancing|analy[sz]ing|transcrib|in progress/i.test(text);
}

function attachFile(input, file, basename) {
  const transfer = new DataTransfer();
  transfer.items.add(file);
  try {
    input.files = transfer.files;
  } catch (e) {
    // Some builds define `files` non-writably; fall back to redefining it.
    Object.defineProperty(input, "files", { value: transfer.files, configurable: true });
  }
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  return transfer;
}

function simulateDrop(transfer) {
  const zone = deepQueryAll('[data-testid="dotted-border"]')[0]
    || deepQueryAll('[data-testid*="drop"], [class*="dropzone"], [class*="DropZone"]')[0]
    || document.body;
  for (const type of ["dragenter", "dragover", "drop"]) {
    try {
      zone.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, composed: true, dataTransfer: transfer }));
    } catch (e) {}
  }
  log("dispatched synthetic drop on " + (zone.tagName || "?"));
}

/* ------------------------------------------------------------------ *
 * Main routine, invoked once by the app per file.
 * ------------------------------------------------------------------ */

window.__enhancerRun = async function (fileUrl, fileName, mimeType) {
  if (window.__enhancerRunning) { log("run already in progress; ignoring duplicate start"); return; }
  window.__enhancerRunning = true;
  const basename = fileName.replace(/\.[^.]+$/, "");
  try {
    post({ type: "phase", phase: "upload" });
    dismissOverlays();

    let announcedLogin = false;
    const input = await waitFor(() => { dismissOverlays(); return findFileInput(); }, 15 * 60 * 1000, (tick) => {
      heartbeat(tick);
      if (tick === 6 && signedOut() && !announcedLogin) {
        announcedLogin = true;
        post({ type: "needsLogin" });
      }
    });
    if (!input) throw new Error("Couldn't find the upload control on the Adobe page.");
    if (announcedLogin) post({ type: "loginDone" });
    log("upload control ready");

    const file = await loadLocalFile(fileUrl, fileName, mimeType);
    log("file ready in page: " + file.size + " bytes");
    post({ type: "progress", phase: "upload", value: 0.4 });

    const transfer = attachFile(input, file, basename);
    let started = await waitFor(() => uploadLooksStarted(basename), 12000);
    if (!started) {
      // The change event went nowhere — try the drag-and-drop path instead.
      simulateDrop(transfer);
      started = await waitFor(() => uploadLooksStarted(basename), 15000);
    }
    if (!started && signedOut()) {
      // Some builds render the dropzone to signed-out visitors and only
      // demand credentials once a file is picked.
      post({ type: "needsLogin" });
      started = await waitFor(() => uploadLooksStarted(basename), 15 * 60 * 1000, heartbeat);
      if (started) post({ type: "loginDone" });
    }
    if (!started) throw new Error("Adobe accepted the file but never started processing it.");
    post({ type: "progress", phase: "upload", value: 1 });
    post({ type: "phase", phase: "enhance" });

    const enhanceStarted = Date.now();
    const control = await waitFor(() => {
      dismissOverlays();
      const message = readPageError();
      if (message) throw new Error(message);
      const value = readProgress();
      if (value !== null) post({ type: "progress", phase: "enhance", value: value });
      // Ignore any Download affordance that was on screen before work began.
      if (Date.now() - enhanceStarted < 4000) return null;
      return findDownloadControl();
    }, 45 * 60 * 1000, heartbeat);
    if (!control) throw new Error("Adobe didn't finish enhancing in time.");

    post({ type: "phase", phase: "download" });
    let target = control;
    for (let attempt = 0; attempt < 4; attempt++) {
      const captured = armDownloadCapture();
      clickEl(target);
      const result = await Promise.race([captured, sleep(6000).then(() => null)]);
      if (result) {
        await deliverDownload(result.url, result.name);
        return;
      }
      disarmDownloadCapture();
      const message = readPageError();
      if (message) throw new Error(message);
      const menuItem = findDownloadMenuItem();
      target = (menuItem && menuItem !== target) ? menuItem : (findDownloadControl() || target);
      log("download click produced nothing; retrying with " + labelOf(target).slice(0, 40));
    }
    throw new Error("Clicked Download on the Adobe page but no file came back.");
  } catch (error) {
    window.__enhancerRunning = false;
    post({ type: "error", message: String((error && error.message) || error) });
  }
};

post({ type: "installed" });
})();
"""#
}
