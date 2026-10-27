/**
 * PsychAudio - Background Service Worker (Manifest V3)
 * Maintains a persistent WebSocket connection to the native macOS PsychAudio daemon,
 * streams audible tab status changes, and executes targeted media play/pause commands.
 */

const DAEMON_WS_URL = 'ws://127.0.0.1:49281';

let ws = null;
let reconnectAttempts = 0;
let reconnectTimeout = null;
let keepaliveInterval = null;

const INITIAL_RECONNECT_DELAY_MS = 1000;
const MAX_RECONNECT_DELAY_MS = 15000;
const KEEPALIVE_INTERVAL_MS = 20000;

// Queue to hold events if triggered while the WebSocket is connecting
const pendingEventQueue = [];

// ---------------------------------------------------------------------------
// WebSocket Lifecycle & Connection Management
// ---------------------------------------------------------------------------

function connectToDaemon() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    return;
  }

  if (reconnectTimeout) {
    clearTimeout(reconnectTimeout);
    reconnectTimeout = null;
  }

  try {
    console.log(`[PsychAudio] Connecting to native daemon at ${DAEMON_WS_URL}...`);
    ws = new WebSocket(DAEMON_WS_URL);

    ws.onopen = async () => {
      console.log('[PsychAudio] Connected to native PsychAudio daemon.');
      reconnectAttempts = 0;

      // Start periodic keepalive heartbeat
      startKeepalive();

      // Flush any queued events
      flushPendingQueue();

      // Synchronize currently audible tabs
      await syncAudibleTabs();
    };

    ws.onmessage = async (event) => {
      try {
        const message = JSON.parse(event.data);
        console.log('[PsychAudio] Received command:', message);

        if (message.action === 'toggle_playback' && typeof message.tabId === 'number') {
          await handleTogglePlayback(message.tabId);
        }
      } catch (err) {
        console.error('[PsychAudio] Failed to parse daemon message:', err);
      }
    };

    ws.onclose = (event) => {
      console.warn(`[PsychAudio] WebSocket disconnected (code: ${event.code}). Scheduling reconnect...`);
      cleanupSocket();
      scheduleReconnect();
    };

    ws.onerror = (err) => {
      console.error('[PsychAudio] WebSocket connection error:', err);
      // onerror is immediately followed by onclose in standard WebSocket
    };
  } catch (err) {
    console.error('[PsychAudio] Unexpected error creating WebSocket:', err);
    scheduleReconnect();
  }
}

function cleanupSocket() {
  stopKeepalive();
  if (ws) {
    ws.onopen = null;
    ws.onmessage = null;
    ws.onclose = null;
    ws.onerror = null;
    ws = null;
  }
}

function scheduleReconnect() {
  if (reconnectTimeout) return;

  const delay = Math.min(
    INITIAL_RECONNECT_DELAY_MS * Math.pow(1.5, reconnectAttempts),
    MAX_RECONNECT_DELAY_MS
  );
  reconnectAttempts++;
  console.log(`[PsychAudio] Reconnecting in ${Math.round(delay)}ms (attempt #${reconnectAttempts})...`);

  reconnectTimeout = setTimeout(() => {
    reconnectTimeout = null;
    connectToDaemon();
  }, delay);
}

function startKeepalive() {
  stopKeepalive();
  keepaliveInterval = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ event: 'ping' }));
    }
  }, KEEPALIVE_INTERVAL_MS);
}

function stopKeepalive() {
  if (keepaliveInterval) {
    clearInterval(keepaliveInterval);
    keepaliveInterval = null;
  }
}

function sendDaemonEvent(eventPayload) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(eventPayload));
  } else {
    // Queue payload and attempt connection if disconnected
    pendingEventQueue.push(eventPayload);
    if (!ws || ws.readyState === WebSocket.CLOSED) {
      connectToDaemon();
    }
  }
}

function flushPendingQueue() {
  while (pendingEventQueue.length > 0 && ws && ws.readyState === WebSocket.OPEN) {
    const payload = pendingEventQueue.shift();
    ws.send(JSON.stringify(payload));
  }
}

// ---------------------------------------------------------------------------
// Tab Audio State Synchronization
// ---------------------------------------------------------------------------

async function syncAudibleTabs() {
  try {
    const audibleTabs = await chrome.tabs.query({ audible: true });
    for (const tab of audibleTabs) {
      if (tab.id !== undefined) {
        sendDaemonEvent({ event: 'tab_playing', tabId: tab.id });
      }
    }
  } catch (err) {
    console.error('[PsychAudio] Error querying audible tabs:', err);
  }
}

// ---------------------------------------------------------------------------
// Chrome Tab Event Listeners
// ---------------------------------------------------------------------------

// Monitor tab audio changes (audible: true -> playing, audible: false -> paused)
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.audible !== undefined) {
    if (changeInfo.audible) {
      console.log(`[PsychAudio] Tab ${tabId} started emitting audio.`);
      sendDaemonEvent({ event: 'tab_playing', tabId: tabId });
    } else {
      console.log(`[PsychAudio] Tab ${tabId} stopped emitting audio.`);
      sendDaemonEvent({ event: 'tab_paused', tabId: tabId });
    }
  }
});

// Handle tab removal to prevent stale routing in daemon
chrome.tabs.onRemoved.addListener((tabId) => {
  console.log(`[PsychAudio] Tab ${tabId} closed.`);
  sendDaemonEvent({ event: 'tab_closed', tabId: tabId });
});

// ---------------------------------------------------------------------------
// Targeted Media Playback Control
// ---------------------------------------------------------------------------

async function handleTogglePlayback(tabId) {
  try {
    const tab = await chrome.tabs.get(tabId).catch(() => null);
    if (!tab) {
      console.warn(`[PsychAudio] Target tab ${tabId} not found.`);
      sendDaemonEvent({ event: 'tab_closed', tabId: tabId });
      return;
    }

    const executionResults = await chrome.scripting.executeScript({
      target: { tabId: tabId },
      func: injectedMediaPlaybackToggle
    });

    console.log(`[PsychAudio] Playback toggle executed on tab ${tabId}:`, executionResults);
  } catch (err) {
    console.error(`[PsychAudio] Failed to execute playback script on tab ${tabId}:`, err);
  }
}

/**
 * Injected script that queries media elements, finds the element that is
 * paused or was recently playing, and toggles its playback state.
 * Fallbacks to web player controls and standard keyboard actions if needed.
 */
function injectedMediaPlaybackToggle() {
  // Helper to query all audio and video elements, including those in shadow DOM
  function collectAllMediaElements(root = document) {
    let elements = Array.from(root.querySelectorAll('video, audio'));
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, null);
    let node;
    while ((node = walker.nextNode())) {
      if (node.shadowRoot) {
        elements = elements.concat(collectAllMediaElements(node.shadowRoot));
      }
    }
    return elements;
  }

  const mediaElements = collectAllMediaElements();

  // 1. If any media element is actively playing, pause it
  const activePlaying = mediaElements.filter((el) => !el.paused && !el.ended && el.readyState > 1);
  if (activePlaying.length > 0) {
    for (const el of activePlaying) {
      el.pause();
    }
    return { status: 'paused', count: activePlaying.length };
  }

  // 2. If elements exist and are paused, resume the one with active playback progress
  if (mediaElements.length > 0) {
    const resumeCandidate = mediaElements.find((el) => el.currentTime > 0 && !el.ended) || mediaElements[0];
    if (resumeCandidate) {
      const playPromise = resumeCandidate.play();
      if (playPromise && typeof playPromise.catch === 'function') {
        playPromise.catch((err) => console.warn('[PsychAudio] play() rejected:', err));
      }
      return { status: 'resumed', tagName: resumeCandidate.tagName, currentTime: resumeCandidate.currentTime };
    }
  }

  // 3. Fallback: Trigger common web player play/pause buttons
  const knownPlayerControls = [
    '.ytp-play-button',                          // YouTube
    '[data-testid="control-button-playpause"]',   // Spotify Web
    '.playControl',                               // SoundCloud
    '[data-a-target="player-play-pause-button"]', // Twitch
    'button.play-button',
    'button[aria-label*="Play" i]',
    'button[aria-label*="Pause" i]'
  ];

  for (const selector of knownPlayerControls) {
    const btn = document.querySelector(selector);
    if (btn) {
      btn.click();
      return { status: 'player_button_clicked', selector: selector };
    }
  }

  // 4. Fallback: Trigger spacebar keyboard event on the active element or document body
  try {
    const target = document.activeElement || document.body;
    const eventDown = new KeyboardEvent('keydown', { key: ' ', code: 'Space', keyCode: 32, which: 32, bubbles: true });
    const eventUp = new KeyboardEvent('keyup', { key: ' ', code: 'Space', keyCode: 32, which: 32, bubbles: true });
    target.dispatchEvent(eventDown);
    target.dispatchEvent(eventUp);
    return { status: 'simulated_space_event' };
  } catch (err) {
    return { status: 'fallback_error', message: err.toString() };
  }
}

// ---------------------------------------------------------------------------
// Extension Startup
// ---------------------------------------------------------------------------

// Immediately initiate connection on script evaluation
connectToDaemon();
