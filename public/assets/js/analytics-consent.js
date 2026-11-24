(() => {
  'use strict';

  const script = document.currentScript;
  const key = 'crewsignal.analytics-consent.v1';
  const production = 'https://crewsignal.org';
  const framePath = '/assets/analytics-frame.html';
  const disableKey = 'ga-disable-G-JM4GBY4EQY';
  const measurementEnabled = script.dataset.measurement === 'on' && location.origin === production;
  let frame;
  let choice;
  let openedFromPreferences = false;

  function readChoice() {
    try {
      const value = localStorage.getItem(key);
      if (value === 'accepted') {
        // A read-only store cannot reliably record a later withdrawal.
        localStorage.setItem(key, value);
        return value;
      }
      return value === 'declined' ? value : null;
    } catch {
      return null;
    }
  }

  function writeChoice(value) {
    try {
      localStorage.setItem(key, value);
      if (localStorage.getItem(key) === value) return true;
    } catch {
      // Try clearing a stale accepted value below.
    }
    if (value === 'declined') {
      try {
        localStorage.removeItem(key);
      } catch {
        // The current document still stops measurement.
      }
    }
    return false;
  }

  function clearAnalyticsCookies() {
    for (const name of ['_ga', '_ga_JM4GBY4EQY']) {
      try {
        const expired = `${name}=; Max-Age=0; Path=/; Secure; SameSite=Strict`;
        document.cookie = expired;
        if (location.origin === production) document.cookie = expired + '; Domain=crewsignal.org';
      } catch {
        // Cookie access may be disabled by the browser.
      }
    }
  }

  function stopAnalytics() {
    if (frame) {
      const child = frame.contentWindow;
      if (child) child[disableKey] = true;
      frame.remove();
      frame = undefined;
    }
  }

  function startAnalytics() {
    if (frame || !measurementEnabled) return;
    const child = document.createElement('iframe');
    child.hidden = true;
    child.title = 'CrewSignal readership measurement';
    child.referrerPolicy = 'no-referrer';
    child.src = framePath;
    child.addEventListener('load', () => {
      if (frame !== child || readChoice() !== 'accepted') return;
      child.contentWindow.postMessage({ page: script.dataset.page }, production);
    }, { once: true });
    frame = child;
    document.body.append(child);
  }

  const panel = document.createElement('section');
  panel.className = 'cs-analytics-panel';
  panel.id = 'cs-analytics-panel';
  panel.setAttribute('aria-labelledby', 'cs-analytics-heading');
  panel.innerHTML = `
    <h2 id="cs-analytics-heading" tabindex="-1">Analytics preferences</h2>
    <p>May we use optional analytics cookies to measure readership? You can use the full site either way and change your choice in Privacy Preferences. <a href="/privacy/">Privacy Policy</a></p>
    <div class="cs-analytics-actions">
      <button type="button" data-choice="accepted">Accept analytics</button>
      <button type="button" data-choice="declined">Decline analytics</button>
    </div>`;

  const preferences = document.createElement('div');
  preferences.className = 'cs-analytics-preferences';
  preferences.innerHTML = `
    <button type="button" aria-controls="cs-analytics-panel" aria-expanded="false">Privacy Preferences</button>
    <p role="status"></p>`;
  const preferencesButton = preferences.querySelector('button');
  const status = preferences.querySelector('[role="status"]');
  const heading = panel.querySelector('h2');
  const skip = document.body.querySelector(':scope > a[href^="#"]:first-child');
  if (skip) skip.after(panel);
  else document.body.prepend(panel);
  document.body.append(preferences);

  function showPanel(show) {
    panel.hidden = !show;
    preferencesButton.setAttribute('aria-expanded', String(show));
  }

  function returnFocus() {
    const destination = openedFromPreferences ? preferencesButton : document.querySelector('main, [role="main"], h1');
    if (destination && !destination.hasAttribute('tabindex') && destination !== preferencesButton) {
      destination.tabIndex = -1;
    }
    (destination || preferencesButton).focus();
    openedFromPreferences = false;
  }

  function applyChoice(value) {
    choice = value;
    if (value === 'accepted' && measurementEnabled) {
      startAnalytics();
    } else {
      stopAnalytics();
      clearAnalyticsCookies();
    }
    const focusInPanel = panel.contains(document.activeElement);
    showPanel(!value);
    if (value && focusInPanel) returnFocus();
  }

  preferencesButton.addEventListener('click', () => {
    if (panel.hidden) {
      openedFromPreferences = true;
      showPanel(true);
      heading.focus();
    } else {
      showPanel(false);
      openedFromPreferences = false;
    }
  });
  panel.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      showPanel(false);
      returnFocus();
    }
  });

  for (const button of panel.querySelectorAll('button')) {
    button.addEventListener('click', () => {
      const value = button.dataset.choice;
      if (value === 'declined') stopAnalytics();
      const saved = writeChoice(value);
      applyChoice(saved ? value : null);
      if (saved) {
        status.textContent = value === 'accepted' ? 'Analytics accepted.' : 'Analytics declined.';
      } else {
        showPanel(false);
        preferencesButton.focus();
        status.textContent = 'Analytics is off. Your browser could not save your preference.';
      }
    });
  }

  function syncChoice() {
    const value = readChoice();
    if (value !== choice) applyChoice(value);
    else if (value === 'accepted') startAnalytics();
  }

  window.addEventListener('storage', (event) => {
    if (event.key === key || event.key === null) syncChoice();
  });
  window.addEventListener('pageshow', syncChoice);
  window.addEventListener('pagehide', (event) => {
    if (event.persisted) stopAnalytics();
  });
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) syncChoice();
  });

  applyChoice(readChoice());
})();
