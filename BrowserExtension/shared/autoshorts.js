"use strict";

const STORAGE_KEY = "autoShortsEnabled";
const YT_SHORTS_PATH_PREFIX = "/shorts/";
const SCAN_INTERVAL_MS = 500;
const ADVANCE_GUARD_MS = 900;
const NEAR_END_SECONDS = 0.2;
const LOOP_WRAP_WINDOW_SECONDS = 0.75;

let enabled = false;
let scanTimer = null;
let lastAdvanceAt = 0;
const boundVideos = new WeakSet();
const lastPlaybackTimes = new WeakMap();

const api = globalThis.chrome ?? globalThis.browser;

function isShortsUrl() {
  return location.pathname.startsWith(YT_SHORTS_PATH_PREFIX);
}

function isUserTyping() {
  const element = document.activeElement;
  if (!element) return false;
  if (element.isContentEditable) return true;

  const tagName = (element.tagName || "").toLowerCase();
  if (["input", "textarea", "select"].includes(tagName)) return true;

  return (element.getAttribute?.("role") || "").toLowerCase() === "textbox";
}

function isVisible(element) {
  if (!element) return false;
  const rect = element.getBoundingClientRect?.();
  if (!rect || rect.width <= 0 || rect.height <= 0) return false;

  if (typeof getComputedStyle === "function") {
    const style = getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden") return false;
  }
  return true;
}

function getActiveVideo() {
  const videos = [...document.querySelectorAll("video")].filter(isVisible);
  if (videos.length === 0) return null;

  const playingVideo = videos.find((video) => !video.paused && !video.ended);
  if (playingVideo) return playingVideo;

  return videos.reduce((largest, video) => {
    const rect = video.getBoundingClientRect();
    const largestRect = largest.getBoundingClientRect();
    return rect.width * rect.height > largestRect.width * largestRect.height
      ? video
      : largest;
  });
}

function findNextButton() {
  const selectors = [
    "#navigation-button-down button",
    "button[aria-label='다음 동영상']",
    "button[aria-label='Next video']"
  ];

  for (const selector of selectors) {
    const button = [...document.querySelectorAll(selector)].find(
      (candidate) => isVisible(candidate) && !candidate.disabled
    );
    if (button) return button;
  }
  return null;
}

function dispatchArrowDown() {
  const target = document.body || document.documentElement;
  const options = {
    key: "ArrowDown",
    code: "ArrowDown",
    keyCode: 40,
    which: 40,
    bubbles: true,
    cancelable: true
  };
  target.dispatchEvent(new KeyboardEvent("keydown", options));
  target.dispatchEvent(new KeyboardEvent("keyup", options));
}

function advanceToNextShort() {
  if (!enabled || !isShortsUrl() || isUserTyping()) return false;

  const now = Date.now();
  if (now - lastAdvanceAt < ADVANCE_GUARD_MS) {
    return false;
  }

  lastAdvanceAt = now;

  const nextButton = findNextButton();
  if (nextButton) {
    nextButton.click();
  } else {
    dispatchArrowDown();
  }
  return true;
}

function onVideoEnded(event) {
  const activeVideo = getActiveVideo();
  if (activeVideo && event.currentTarget !== activeVideo) return;
  advanceToNextShort();
}

function onVideoTimeUpdate(event) {
  const video = event.currentTarget;
  const activeVideo = getActiveVideo();
  if (activeVideo && video !== activeVideo) return;

  const duration = Number(video.duration);
  const currentTime = Number(video.currentTime);
  if (!Number.isFinite(duration) || duration <= 0 || !Number.isFinite(currentTime)) return;

  const previousTime = lastPlaybackTimes.get(video);
  lastPlaybackTimes.set(video, currentTime);

  const isNearEnd = duration - currentTime <= NEAR_END_SECONDS;
  const loopWrapped =
    Number.isFinite(previousTime) &&
    previousTime >= duration - LOOP_WRAP_WINDOW_SECONDS &&
    currentTime <= Math.min(LOOP_WRAP_WINDOW_SECONDS, duration * 0.15);

  if (isNearEnd || loopWrapped) advanceToNextShort();
}

function bindAvailableVideos() {
  if (!enabled || !isShortsUrl()) return;

  for (const video of document.querySelectorAll("video")) {
    if (boundVideos.has(video)) continue;
    boundVideos.add(video);
    video.addEventListener("ended", onVideoEnded);
    video.addEventListener("timeupdate", onVideoTimeUpdate);
  }
}

function onStorageChanged(changes, areaName) {
  if (areaName !== "local" || !changes[STORAGE_KEY]) return;
  enabled = !!changes[STORAGE_KEY].newValue;
  if (enabled) bindAvailableVideos();
}

function install() {
  if (!api?.storage?.local) return;
  api.storage.local.get({ [STORAGE_KEY]: true }, (state) => {
    enabled = !!state?.[STORAGE_KEY];
    if (enabled) bindAvailableVideos();
  });

  api.storage.onChanged?.addListener(onStorageChanged);
  window.addEventListener("popstate", bindAvailableVideos);
  window.addEventListener("yt-navigate-finish", bindAvailableVideos);
  scanTimer = window.setInterval(bindAvailableVideos, SCAN_INTERVAL_MS);
}

function uninstall() {
  if (scanTimer !== null) {
    window.clearInterval(scanTimer);
    scanTimer = null;
  }
  api?.storage?.onChanged?.removeListener(onStorageChanged);
  window.removeEventListener("popstate", bindAvailableVideos);
  window.removeEventListener("yt-navigate-finish", bindAvailableVideos);
}

if (window.top === window) {
  install();
  window.addEventListener("beforeunload", uninstall);
}
