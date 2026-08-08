/* ==========================================================================
   DSMT - front end.

   Every row this file renders came from Active Directory over /api/*. There
   is no demo array, no sample record and no offline fallback anywhere in
   this file: when a call fails the UI shows the error the directory gave,
   never invented data. (CLAUDE.md, "No fake/placeholder data".)

   The version string is read from the API and painted into the login footer
   and the About dialog. It is never written as a literal here.
   ========================================================================== */
'use strict';

(function () {

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

var TOKEN_KEY = 'dsmt.token';
var COLS_KEY  = 'dsmt.columns';

var state = {
  token: null,
  user: null,
  version: '',
  domain: '',
  domainInfo: null,
  tab: 'users',
  query: '',
  rows: [],
  loadError: '',
  selectedId: null,
  detail: null,
  checked: {},
  visibleCols: null,
  // True once the CSV import dialog has shown a dry-run result for exactly
  // the CSV and OU currently in the form. Reset on open and on any edit.
  csvPreviewed: false,
  ous: null,
  auditRows: [],
  auditTotal: 0,
  auditFilter: 'All',
  auditQuery: '',
  auditRange: 'all',
  auditFrom: null,
  auditTo: null,
  auditSource: '',
  notifications: [],
  pageLimitHit: false,
  storage: null,
  identity: null,
  settings: null,
  sessionMinutes: 0,
  publisher: '',
  adAlert: null,
  adAlertTimer: null,
  busy: 0
};

// How often the console ASKS the server about AD health. Not how often the
// check runs - the server decides that from its own interval (default hourly)
// and answers from cache in between, so polling more often costs one small
// JSON response, not a directory sweep. Five minutes is short enough that a
// problem found by another operator's poll reaches this bell quickly.
var ALERT_POLL_MS = 5 * 60 * 1000;

// Column definitions are the app's own fixed UI config - not directory data -
// so they are legitimately defined here. (CLAUDE.md audit step 1.)
var USER_COLS = [
  { key: 'name',    label: 'Display name',   on: true },
  { key: 'sam',     label: 'samAccountName', on: true },
  { key: 'upn',     label: 'UPN / email',    on: true },
  { key: 'ou',      label: 'OU / container', on: true },
  { key: 'status',  label: 'Status',         on: true },
  { key: 'logon',   label: 'Last logon',     on: true },
  { key: 'dept',    label: 'Department',     on: false },
  { key: 'title',   label: 'Title',          on: false },
  { key: 'pwd',     label: 'Password expiry',on: false },
  { key: 'groups',  label: 'Groups',         on: false },
  { key: 'manager', label: 'Manager',        on: false }
];
var GROUP_COLS = [
  { key: 'name',    label: 'Group name',  on: true },
  { key: 'sam',     label: 'samAccountName', on: true },
  { key: 'type',    label: 'Type / scope',on: true },
  { key: 'ou',      label: 'Container',   on: true },
  { key: 'members', label: 'Members',     on: true }
];

/* Audit filters. 'System' is what was done to DSMT itself rather than to the
   directory; 'Failed' is everything that did not succeed, including Denied -
   which is an AD permissions problem, not a DSMT one. Both are answered
   identically by the SQL and the file-log readers. */
var AUDIT_FILTERS = ['All', 'System', 'Failed', 'Users', 'Groups', 'Passwords', 'Deletions'];

/* Audit time windows. `hours` is how far back to look; null means no bound.
   'custom' is driven by the two datetime inputs instead. */
var AUDIT_RANGES = [
  { key: '24h',    label: 'Last 24 hours', hours: 24 },
  { key: '48h',    label: 'Last 48 hours', hours: 48 },
  { key: '7d',     label: 'Last 7 days',   hours: 24 * 7 },
  { key: '30d',    label: 'Last 30 days',  hours: 24 * 30 },
  { key: 'all',    label: 'All time',      hours: null },
  { key: 'custom', label: 'Custom range',  hours: null }
];

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function $(id) { return document.getElementById(id); }
function el(sel, root) { return (root || document).querySelector(sel); }
function els(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

function esc(value) {
  if (value === null || value === undefined) { return ''; }
  return String(value)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/* PowerShell's ConvertTo-Json collapses a one-element array into a bare
   object. Everything that should be a list goes through here so a domain
   with exactly one match does not break the table. */
function asArray(value) {
  if (value === null || value === undefined) { return []; }
  if (Object.prototype.toString.call(value) === '[object Array]') { return value; }
  return [value];
}

function busy(on) {
  state.busy += (on ? 1 : -1);
  if (state.busy < 0) { state.busy = 0; }
  $('busy').hidden = (state.busy === 0);
}

function toast(message, kind) {
  var box = document.createElement('div');
  box.className = 'toast ' + (kind === 'bad' ? 'toast-bad' : 'toast-ok');
  box.textContent = message;
  $('toasts').appendChild(box);
  window.setTimeout(function () {
    if (box.parentNode) { box.parentNode.removeChild(box); }
  }, kind === 'bad' ? 9000 : 5000);
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

function api(path, options) {
  var opts = options || {};
  var headers = { 'Accept': 'application/json' };
  if (state.token) { headers['Authorization'] = 'Bearer ' + state.token; }
  if (opts.body !== undefined) { headers['Content-Type'] = 'application/json'; }

  // A background poll must not flash the busy bar. Without this the bell's
  // five-minute check makes the whole console blink as if the operator had
  // started something, which is how a quiet feature becomes an irritating one.
  var quiet = !!opts.quiet;
  if (!quiet) { busy(true); }

  return fetch(path, {
    method: opts.method || 'GET',
    headers: headers,
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    cache: 'no-store'
  }).then(function (res) {
    return res.text().then(function (text) {
      var data = null;
      if (text) {
        try { data = JSON.parse(text); } catch (e) { data = null; }
      }
      if (res.status === 401 && !opts.allow401) {
        signOutLocal();
        throw new Error((data && data.error) ? data.error : 'Your session has expired. Sign in again.');
      }
      if (!res.ok) {
        throw new Error((data && data.error) ? data.error : ('Request failed (' + res.status + ')'));
      }
      return data;
    });
  }).then(function (data) {
    if (!quiet) { busy(false); }
    return data;
  }, function (err) {
    if (!quiet) { busy(false); }
    throw err;
  });
}

// ---------------------------------------------------------------------------
// Session - survives a refresh (F5) because the token lives in localStorage
// and is revalidated against the server on every load.
// ---------------------------------------------------------------------------

function saveToken(token) {
  state.token = token;
  try { window.localStorage.setItem(TOKEN_KEY, token); } catch (e) { /* private mode */ }
}

function loadToken() {
  try { return window.localStorage.getItem(TOKEN_KEY); } catch (e) { return null; }
}

function clearToken() {
  state.token = null;
  try { window.localStorage.removeItem(TOKEN_KEY); } catch (e) { /* ignore */ }
}

function signOutLocal() {
  stopIdleWatch();
  stopAdAlertWatch();
  state.adAlert = null;
  clearToken();
  state.user = null;
  showLogin();
}

// ---------------------------------------------------------------------------
// Idle timeout
//
// The server is the enforcement: it drops a session that has not been used for
// SessionMinutes, and nothing the browser does can extend that. This timer
// exists so the operator is WARNED before it happens, instead of discovering
// it as a failed action mid-task.
//
// Only real interaction counts as activity. Background work does not reset the
// clock - otherwise a page left open on a dashboard would keep a session alive
// forever, which defeats the point of having a timeout at all.
// ---------------------------------------------------------------------------

var IDLE_WARN_SECONDS = 60;

var idle = {
  minutes: 0,
  lastActivity: 0,
  tick: null,
  warning: false,
  countdown: 0
};

function startIdleWatch(minutes) {
  idle.minutes = minutes || 0;
  stopIdleWatch();
  if (!idle.minutes) { return; }

  noteActivity();

  ['mousedown', 'keydown', 'touchstart', 'wheel', 'focus'].forEach(function (name) {
    document.addEventListener(name, noteActivity, true);
  });

  idle.tick = window.setInterval(checkIdle, 1000);
}

function stopIdleWatch() {
  if (idle.tick) { window.clearInterval(idle.tick); idle.tick = null; }
  ['mousedown', 'keydown', 'touchstart', 'wheel', 'focus'].forEach(function (name) {
    document.removeEventListener(name, noteActivity, true);
  });
  idle.warning = false;
}

function noteActivity() {
  idle.lastActivity = Date.now();

  // Dismissing the warning by moving the mouse is deliberate: the operator is
  // demonstrably there. The server is told, so its clock agrees with ours.
  if (idle.warning) {
    idle.warning = false;
    if (!$('dialogBackdrop').hidden && dialogState.isIdleWarning) { closeDialog(); }
    api('/api/session', { allow401: true }).catch(function () { /* the timer keeps running */ });
  }
}

function checkIdle() {
  if (!idle.minutes || !state.token) { return; }

  var idleSeconds = Math.floor((Date.now() - idle.lastActivity) / 1000);
  var limit = idle.minutes * 60;
  var remaining = limit - idleSeconds;

  if (remaining <= 0) {
    stopIdleWatch();
    signOutIdle();
    return;
  }

  if (remaining <= IDLE_WARN_SECONDS) {
    idle.countdown = remaining;
    if (!idle.warning) {
      idle.warning = true;
      showIdleWarning();
    } else {
      var span = $('idleCountdown');
      if (span) { span.textContent = String(remaining); }
    }
  }
}

function showIdleWarning() {
  openDialog({
    title: 'Still there?',
    confirmLabel: 'Stay signed in',
    cancelLabel: 'Sign out now',
    isIdleWarning: true,
    body: '<p class="dialog-note">You have not used DSMT for ' + idle.minutes +
          ' minutes. For security, you will be signed out in ' +
          '<strong id="idleCountdown">' + idle.countdown + '</strong> seconds.</p>' +
          '<p class="dialog-note">Anything you have typed into an open dialog will be lost.</p>',
    onConfirm: function () { noteActivity(); closeDialog(); },
    onCancel: function () { stopIdleWatch(); signOutIdle(); }
  });
}

function signOutIdle() {
  api('/api/session', { method: 'DELETE', allow401: true })
    .catch(function () { /* signing out locally regardless */ })
    .then(function () {
      signOutLocal();
      var err = $('loginError');
      err.textContent = 'You were signed out after ' + idle.minutes + ' minutes without activity.';
      err.hidden = false;
    });
}

function showLogin() {
  $('appView').hidden = true;
  $('loginView').hidden = false;
  $('loginPass').value = '';
  window.setTimeout(function () {
    var user = $('loginUser');
    if (user && !user.value) { user.focus(); }
  }, 30);
}

function showApp() {
  $('loginView').hidden = true;
  $('appView').hidden = false;
}

// ---------------------------------------------------------------------------
// Version - one value, from the API, painted everywhere it is shown
// ---------------------------------------------------------------------------

function applyInsecureBar(data) {
  // Painted from /api/meta and from /api/session, so it is up before anyone
  // types a password and stays up afterwards. Reading both is deliberate:
  // the sign-in screen is exactly where the warning matters most.
  var bar = $('insecureBar');
  if (!bar || !data) { return; }

  if (!data.httpsDegraded) {
    bar.hidden = true;
    bar.innerHTML = '';
    return;
  }

  bar.innerHTML =
    '<strong>This connection is not encrypted.</strong> ' +
    'HTTPS is configured on this server but is not working, so DSMT fell back to plain HTTP - ' +
    'domain passwords and directory data cross the network in clear text. ' +
    '<span class="insecure-cause">' + esc(data.httpsDegradedCause || '') + '</span> ' +
    '<span class="insecure-fix">' + esc(data.httpsDegradedFix || '') + '</span>';
  bar.hidden = false;
}

function applyVersion(version, publisher) {
  if (version) {
    state.version = version;
    var badge = $('loginVersion');
    if (badge) { badge.textContent = 'v' + version; }
  }
  if (publisher) {
    state.publisher = publisher;
    var by = $('loginPublisher');
    if (by) { by.textContent = 'by ' + publisher; }
  }
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

function boot() {
  wireEvents();

  api('/api/meta', { allow401: true }).then(function (meta) {
    if (meta) {
      applyVersion(meta.version, meta.publisher);
      applyInsecureBar(meta);
      state.storage = meta.storage || null;
      state.identity = meta.identity || null;
      if (meta.sessionMinutes) { state.sessionMinutes = meta.sessionMinutes; }
      state.domain = meta.domain || '';
      var dom = $('loginDomain');
      if (dom && state.domain) { dom.textContent = state.domain; }
      renderNotifications();
    }
  }).catch(function () { /* the login form still works */ });

  var token = loadToken();
  if (!token) { showLogin(); return; }

  state.token = token;
  api('/api/session', { allow401: true }).then(function (data) {
    if (!data || !data.ok) { signOutLocal(); return; }
    applyVersion(data.version, data.publisher);
    applyInsecureBar(data);
    if (data.sessionMinutes) { state.sessionMinutes = data.sessionMinutes; }
    state.user = data.user;
    enterApp();
  }).catch(function () {
    signOutLocal();
  });
}

function enterApp() {
  showApp();
  paintIdentity();
  loadDomainInfo();
  setTab(state.tab, true);
  startIdleWatch(state.sessionMinutes);
  startAdAlertWatch();
}

function paintIdentity() {
  if (!state.user) { return; }
  $('menuSignedIn').textContent = 'Signed in as ' + (state.user.account || state.user.sam);
}

function loadDomainInfo() {
  api('/api/domain').then(function (data) {
    state.domainInfo = data.domain;

    // The header carries the auto-detected domain name only. The controller
    // count lives in About and in the menu, where there is room for it.
    $('domainLine').textContent = data.domain.domain;

    // Just the domain name; the controller count lives in About, where it
    // is information rather than clutter.
    $('menuDomain').textContent = data.domain.domain;
    renderNotifications();
  }).catch(function (err) {
    $('domainLine').textContent = 'Domain unavailable';
    toast('Could not read the domain: ' + err.message, 'bad');
  });
}

// ---------------------------------------------------------------------------
// Notifications
//
// Every notification is derived from real server state - there is no seeded
// or sample notification. If the list is empty, the bell says so rather than
// inventing something to show.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Scheduled AD health
//
// The server runs the checks at most once per interval and serves the cached
// verdict in between, so this poll is cheap. It is only started once signed
// in: the checks run as the signed-in operator, and there is nobody to show a
// bell to before that.
// ---------------------------------------------------------------------------

function pollAdAlerts(force) {
  if (!state.token) { return; }

  var url = '/api/alerts' + (force ? '?force=1' : '');
  api(url, { quiet: true }).then(function (data) {
    if (!data || !data.ok) { return; }
    state.adAlert = data.alert || null;
    renderNotifications();
  }).catch(function () {
    // Deliberately silent. This runs on a timer in the background, and a
    // toast every five minutes because a controller is briefly unreachable
    // would train the operator to ignore toasts. The failure still shows in
    // the bell, because the server records a failed check as a problem.
  });
}

function startAdAlertWatch() {
  stopAdAlertWatch();
  pollAdAlerts(false);
  state.adAlertTimer = setInterval(function () { pollAdAlerts(false); }, ALERT_POLL_MS);
}

function stopAdAlertWatch() {
  if (state.adAlertTimer) { clearInterval(state.adAlertTimer); state.adAlertTimer = null; }
}

function ackAdAlerts() {
  if (!state.adAlert || !state.adAlert.unread) { return; }
  api('/api/alerts/ack', { method: 'POST', body: {}, quiet: true }).then(function (data) {
    if (data && data.ok) {
      state.adAlert = data.alert || state.adAlert;
      renderNotifications();
    }
  }).catch(function () { /* the panel is already open; nothing to report */ });
}

function buildNotifications() {
  var list = [];
  var storage = state.storage;

  // AD health first, and always first: a replication failure outranks every
  // piece of console advice below it.
  var alert = state.adAlert;
  if (alert && alert.problems && alert.problems.length) {
    var when = alert.checkedUtc ? new Date(alert.checkedUtc).toLocaleString() : 'just now';
    asArray(alert.problems).forEach(function (line) {
      list.push({
        kind: alert.overall === 'bad' ? 'bad' : 'warn',
        title: 'Active Directory health',
        body: line + '  (checked ' + when + ')',
        actionLabel: 'Open AD health',
        action: function () { closeBell(); openAdHealthTool(); }
      });
    });
  }

  if (storage && !storage.sqlEnabled) {
    list.push({
      kind: 'advice',
      title: 'No SQL database configured',
      body: 'Operators, sessions and the directory snapshot are not being stored, ' +
            'and the audit log is only written to files on the server. Create a ' +
            'database to keep this history in SQL Server.',
      actionLabel: 'Create database',
      action: function () { closeBell(); actionSettings(); }
    });
  }

  if (storage && storage.sqlEnabled && storage.sqlError) {
    list.push({
      kind: 'advice',
      title: 'SQL Server reported a problem',
      body: storage.sqlError,
      actionLabel: 'Open settings',
      action: function () { closeBell(); actionSettings(); }
    });
  }

  var identity = state.identity;

  if (identity && identity.accountKind === 'user') {
    list.push({
      kind: 'advice',
      title: 'Running under a personal account',
      body: 'DSMT runs as ' + (identity.serviceUser || 'an interactive account') +
            '. Personal accounts have passwords that expire and leave with the person. ' +
            'Move it to a dedicated service account or a gMSA when convenient.',
      actionLabel: 'How',
      action: function () {
        closeBell();
        openDialog({
          title: 'Move DSMT to a service account',
          hideConfirm: true,
          cancelLabel: 'Close',
          body: '<p class="dialog-note">Run this on the DSMT host, elevated. It updates the service or ' +
                'scheduled task, the URL reservation, the data folder permissions and the saved settings ' +
                'in one go, and prints the SQL grant you still need to run.</p>' +
                '<div class="secret">.\\server\\Install-DSMT.ps1 -ChangeServiceAccount "DOMAIN\\svc-dsmt"</div>' +
                '<p class="dialog-note">For a group managed service account, end the name with a dollar ' +
                'sign and no password is asked for:</p>' +
                '<div class="secret">.\\server\\Install-DSMT.ps1 -ChangeServiceAccount "DOMAIN\\gmsa-dsmt$"</div>' +
                '<p class="dialog-note">Restart DSMT afterwards for the change to take effect.</p>'
        });
      }
    });
  }

  if (identity && identity.mode === 'hybrid') {
    list.push({
      kind: 'info',
      title: 'Hybrid identity mode is on',
      body: 'Directory reads run as ' + (identity.serviceUser || 'the service account') +
            ', so every operator can see everything that account can see. Writes still run as ' +
            'the signed-in operator, so the domain controller records who made each change.',
      actionLabel: 'Open settings',
      action: function () { closeBell(); actionSettings(); }
    });
  }

  if (state.pageLimitHit) {
    list.push({
      kind: 'info',
      title: 'Result limit reached',
      body: 'The last directory search returned the maximum of ' + state.limit +
            ' objects, so there may be more that are not shown. Narrow the search, ' +
            'or raise the page size on the server.',
      actionLabel: '',
      action: null
    });
  }

  return list;
}

function renderNotifications() {
  var list = buildNotifications();
  state.notifications = list;

  var badge = $('bellBadge');
  badge.textContent = String(list.length);
  badge.hidden = (list.length === 0);

  $('bellCount').textContent = list.length
    ? (list.length + (list.length === 1 ? ' item' : ' items'))
    : '';

  if (!list.length) {
    $('bellList').innerHTML = '<p class="note-empty">Nothing needs attention. ' +
      'Notifications appear here when the console finds something worth telling you about.</p>';
    return;
  }

  $('bellList').innerHTML = list.map(function (n, i) {
    var action = n.actionLabel
      ? '<button class="btn btn-primary note-action" type="button" data-note="' + i + '">' +
        esc(n.actionLabel) + '</button>'
      : '';
    return '<div class="note-item note-' + esc(n.kind) + '">' +
             '<span class="note-title"><span class="note-dot"></span>' + esc(n.title) + '</span>' +
             '<span class="note-body">' + esc(n.body) + '</span>' + action +
           '</div>';
  }).join('');
}

function openBell() {
  renderNotifications();
  // Opening the panel IS reading them. The server acknowledges the exact set
  // of problems on screen, so a new or changed fault lights the badge again
  // rather than staying silenced by an earlier glance.
  ackAdAlerts();
  $('bellPanel').hidden = false;
  $('bellBtn').setAttribute('aria-expanded', 'true');
}

function closeBell() {
  $('bellPanel').hidden = true;
  $('bellBtn').setAttribute('aria-expanded', 'false');
}

// ---------------------------------------------------------------------------
// Columns
// ---------------------------------------------------------------------------

function colDefs() { return state.tab === 'groups' ? GROUP_COLS : USER_COLS; }

function visibleCols() {
  var defs = colDefs();
  var saved = null;
  try { saved = JSON.parse(window.localStorage.getItem(COLS_KEY) || 'null'); } catch (e) { saved = null; }
  var keys = (saved && saved[state.tab]) ? saved[state.tab] : null;
  if (!keys) {
    keys = defs.filter(function (c) { return c.on; }).map(function (c) { return c.key; });
  }
  var out = defs.filter(function (c) { return keys.indexOf(c.key) !== -1; });
  return out.length ? out : defs.slice(0, 4);
}

function toggleCol(key) {
  var current = visibleCols().map(function (c) { return c.key; });
  var idx = current.indexOf(key);
  if (idx === -1) { current.push(key); } else { current.splice(idx, 1); }

  var saved = {};
  try { saved = JSON.parse(window.localStorage.getItem(COLS_KEY) || '{}'); } catch (e) { saved = {}; }
  saved[state.tab] = current;
  try { window.localStorage.setItem(COLS_KEY, JSON.stringify(saved)); } catch (e) { /* ignore */ }

  renderColPicker();
  renderTable();
}

function renderColPicker() {
  var box = $('colPicker');
  if (box.hidden) { return; }
  var active = visibleCols().map(function (c) { return c.key; });
  box.innerHTML = colDefs().map(function (c) {
    var on = active.indexOf(c.key) !== -1;
    return '<button class="chip" type="button" aria-pressed="' + on + '" data-col="' + esc(c.key) + '">' +
           esc(c.label) + '</button>';
  }).join('');
}

// ---------------------------------------------------------------------------
// Tabs / views
// ---------------------------------------------------------------------------

function setTab(tab, force) {
  if (!force && state.tab === tab) { return; }
  state.tab = tab;
  state.checked = {};
  state.selectedId = null;
  state.detail = null;

  els('.tab').forEach(function (b) {
    b.setAttribute('aria-selected', String(b.getAttribute('data-tab') === tab));
  });

  var isAudit    = (tab === 'audit');
  var isSettings = (tab === 'settings');
  var isTools    = (tab === 'tools');
  var isFullView = (isAudit || isSettings || isTools);

  $('directoryView').hidden = isFullView;
  $('auditView').hidden     = !isAudit;
  $('settingsView').hidden  = !isSettings;
  $('toolsView').hidden     = !isTools;

  // The detail pane belongs to the directory views only.
  $('detailPane').hidden = isFullView;
  closeDetail();

  if (isSettings) {
    loadSettings();
    return;
  }

  if (isTools) {
    loadTools();
    return;
  }

  if (isAudit) {
    renderAuditFilters();
    loadAudit();
    return;
  }

  $('search').placeholder = tab === 'groups'
    ? 'Search groups, description or container'
    : 'Search users, UPN, department or OU';
  $('createBtn').textContent = tab === 'groups' ? 'New group' : 'New user';
  $('importBtn').hidden = (tab === 'groups');
  $('colsBtn').hidden = false;
  $('groupFilters').hidden = (tab !== 'groups');

  renderColPicker();
  loadRows();
}

// ---------------------------------------------------------------------------
// Directory list
// ---------------------------------------------------------------------------

function loadRows() {
  var tab = state.tab;
  var path = (tab === 'groups' ? '/api/groups' : '/api/users');
  var query = [];
  if (state.query) { query.push('q=' + encodeURIComponent(state.query)); }
  if (tab === 'groups' && state.groupFilter && state.groupFilter !== 'all') {
    query.push('filter=' + encodeURIComponent(state.groupFilter));
  }
  if (query.length) { path += '?' + query.join('&'); }

  state.loadError = '';
  api(path).then(function (data) {
    if (state.tab !== tab) { return; }
    state.rows = asArray(data.items);
    state.limit = data.limit;

    if (tab === 'groups') {
      state.groupFilters = asArray(data.filters);
      state.groupTotal = data.total || 0;
      renderGroupFilters();
    }

    renderTable();
    if (state.rows.length && !state.selectedId) {
      selectRow(state.rows[0].id, true);
    }
  }).catch(function (err) {
    if (state.tab !== tab) { return; }
    state.rows = [];
    state.loadError = err.message;
    renderTable();
  });
}

/* ---------------------------------------------------------------------------
   Group filters.

   The chips are built from what the SERVER reports, not from a list in this
   file, so a filter an administrator adds in Settings appears here with no
   code change. "Privileged" is decided by SID on the server - see
   Test-DsmtPrivilegedGroup - because group names are renameable and localised.
   --------------------------------------------------------------------------- */

function renderGroupFilters() {
  var box = $('groupFilters');
  var list = asArray(state.groupFilters);
  if (!list.length) { box.hidden = true; return; }

  box.hidden = false;
  box.innerHTML = list.map(function (f) {
    var on = (f.key === state.groupFilter) || (!state.groupFilter && f.key === 'all');
    return '<button class="chip" type="button" data-gfilter="' + esc(f.key) + '" aria-pressed="' +
           (on ? 'true' : 'false') + '">' + esc(f.label) + '</button>';
  }).join('');

  var chips = box.querySelectorAll('[data-gfilter]');
  for (var i = 0; i < chips.length; i++) {
    chips[i].onclick = function () {
      state.groupFilter = this.getAttribute('data-gfilter');
      state.selectedId = null;
      closeDetail();
      loadRows();
    };
  }
}

function renderTable() {
  var cols = visibleCols();
  var wrap = $('tableWrap');
  var table = $('table');

  // Error and empty states replace the table entirely - they never leave a
  // stale row set on screen pretending to be current.
  var existingMsg = el('.error-box, .empty', wrap);
  if (existingMsg) { existingMsg.parentNode.removeChild(existingMsg); }

  if (state.loadError) {
    table.hidden = true;
    $('resultLine').textContent = '';
    var box = document.createElement('div');
    box.className = 'error-box';
    box.innerHTML = '<strong>The directory could not be read.</strong>' + esc(state.loadError);
    wrap.insertBefore(box, wrap.firstChild);
    updateBulkBar();
    return;
  }

  table.hidden = false;

  $('thead').innerHTML = '<tr><th class="col-check">' +
    '<input type="checkbox" class="check" id="checkAll" aria-label="Select all"></th>' +
    cols.map(function (c) { return '<th>' + esc(c.label) + '</th>'; }).join('') + '</tr>';

  if (!state.rows.length) {
    $('tbody').innerHTML = '';
    $('resultLine').textContent = '';
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = state.query
      ? 'No ' + (state.tab === 'groups' ? 'groups' : 'users') + ' in the directory match "' + state.query + '".'
      : 'The directory returned no ' + (state.tab === 'groups' ? 'groups' : 'users') + '.';
    wrap.insertBefore(empty, wrap.firstChild);
    updateBulkBar();
    return;
  }

  $('tbody').innerHTML = state.rows.map(function (row) {
    var checked = state.checked[row.id] ? ' checked' : '';
    var selected = (row.id === state.selectedId);
    var cells = cols.map(function (c) {
      var raw = row[c.key];
      var text = (raw === null || raw === undefined) ? '' : String(raw);
      var cls = 'cell-muted';
      if (c.key === 'name') { cls = 'cell-name'; }
      if (c.key === 'status') {
        if (row.status === 'Locked out') { cls = 'cell-locked'; }
        else if (row.status === 'Disabled') { cls = 'cell-disabled'; }
      }
      if (c.key === 'ou' || c.key === 'upn') { cls += ' cell-wrap'; }

      // A privileged group is marked on the row, not only reachable through
      // the filter chip - the whole point is that it should be impossible to
      // scroll past one without noticing.
      var badge = '';
      if (c.key === 'name' && row.privileged) {
        badge = ' <span class="tag-priv" title="A well-known privileged group, matched on its SID">Privileged</span>';
      }

      // The name opens the full profile. The rest of the row still selects,
      // so the detail pane keeps working exactly as it did - this adds a way
      // in, it does not replace one.
      if (c.key === 'name' && text) {
        return '<td class="' + cls + '" data-label="' + esc(c.label) + '">' +
               '<button class="name-link" type="button" data-profile="' + esc(row.id) + '">' +
               esc(text) + '</button>' + badge + '</td>';
      }
      return '<td class="' + cls + '" data-label="' + esc(c.label) + '">' + esc(text) + badge + '</td>';
    }).join('');

    return '<tr data-id="' + esc(row.id) + '" aria-selected="' + selected + '">' +
           '<td class="col-check" data-label="Select">' +
           '<input type="checkbox" class="check row-check" data-id="' + esc(row.id) + '"' + checked + '></td>' +
           cells + '</tr>';
  }).join('');

  var noun = (state.tab === 'groups' ? 'groups' : 'users');
  var line = state.rows.length + ' ' + noun + ' from ' + (state.domainInfo ? state.domainInfo.domain : 'the directory');

  // Say so when a filter is hiding rows. A filtered count that looks like a
  // total is how someone concludes the directory has three groups.
  if (state.tab === 'groups' && state.groupFilter && state.groupFilter !== 'all') {
    var chip = asArray(state.groupFilters).filter(function (f) { return f.key === state.groupFilter; })[0];
    line += ' - filtered to "' + (chip ? chip.label : state.groupFilter) + '"';
    if (state.groupTotal) { line += ' out of ' + state.groupTotal + ' read'; }
  }

  state.pageLimitHit = !!(state.limit && state.rows.length >= state.limit);
  if (state.pageLimitHit) {
    line += ' - result limit of ' + state.limit + ' reached, narrow the search to see the rest';
  }
  $('resultLine').textContent = line;
  renderNotifications();

  updateBulkBar();
}

function selectRow(id, skipScroll) {
  state.selectedId = id;
  els('#tbody tr').forEach(function (tr) {
    tr.setAttribute('aria-selected', String(tr.getAttribute('data-id') === id));
  });

  var row = state.rows.filter(function (r) { return r.id === id; })[0];
  if (!row) { return; }

  openDetail();
  $('detailBody').innerHTML = '<div class="detail"><p class="muted-sm">Loading ' + esc(row.name) + '...</p></div>';

  var path = (state.tab === 'groups' ? '/api/groups/' : '/api/users/') + encodeURIComponent(row.sam || row.dn);
  api(path).then(function (data) {
    if (state.selectedId !== id) { return; }
    state.detail = data.item;
    renderDetail();
  }).catch(function (err) {
    if (state.selectedId !== id) { return; }
    $('detailBody').innerHTML = '<div class="detail"><div class="error-box"><strong>Could not load details.</strong>' +
                                esc(err.message) + '</div></div>';
  });
}

function openDetail() {
  $('detailPane').hidden = false;
  if (window.matchMedia('(max-width: 1180px)').matches) {
    $('detailBackdrop').hidden = false;
  }
}

function closeDetail() {
  $('detailBackdrop').hidden = true;
  if (window.matchMedia('(max-width: 1180px)').matches) {
    $('detailPane').hidden = true;
  } else {
    $('detailPane').hidden = false;
  }
}

function renderDetail() {
  var d = state.detail;
  if (!d) { return; }
  var isGroup = (state.tab === 'groups');

  var fields = isGroup ? [
    ['samAccountName', d.sam, false],
    ['Type / scope', d.type, false],
    ['Container', d.ou, false],
    ['Members', String(d.members), false],
    ['Managed by', d.managedBy, false],
    ['Description', d.description, false],
    ['Created', d.created, false]
  ] : [
    ['samAccountName', d.sam, false],
    ['UPN', d.upn, true],
    ['Email', d.mail, false],
    ['OU / container', d.ou, false],
    ['Department', d.dept, false],
    ['Title', d.title, false],
    ['Manager', d.manager, false],
    ['Office', d.office, false],
    ['Phone', d.phone, false],
    ['Last logon', d.logon, false],
    ['Password expiry', d.pwd, false],
    ['Created', d.created, false]
  ];

  var rows = fields.filter(function (f) {
    return f[1] !== undefined && f[1] !== null && String(f[1]).length > 0;
  }).map(function (f) {
    return '<div class="detail-row"><dt>' + esc(f[0]) + '</dt>' +
           '<dd class="' + (f[2] ? 'accent' : '') + '">' + esc(f[1]) + '</dd></div>';
  }).join('');

  var members = asArray(d.memberships);
  var memberLabel = isGroup ? 'Members (' + members.length + ')' : 'Group memberships (' + members.length + ')';
  var memberHtml;
  if (!members.length) {
    memberHtml = '<p class="muted-sm">' + (isGroup ? 'This group has no members.' : 'This account is in no groups.') + '</p>';
  } else {
    memberHtml = '<ul class="member-list">' + members.map(function (m) {
      var remove = '<button class="member-remove" type="button" data-member="' + esc(m.dn) + '">Remove</button>';
      return '<li><span class="member-dot"></span>' +
             '<span class="member-name" title="' + esc(m.dn) + '">' + esc(m.name) + '</span>' +
             '<span class="member-meta">' + esc(m.meta) + '</span>' + remove + '</li>';
    }).join('') + '</ul>';
  }

  var actions = isGroup
    ? [['add-members', 'Add members'], ['move-ou', 'Move OU'], ['export-members', 'Export members']]
    : [['reset-password', 'Reset password'], ['unlock', 'Unlock'],
       [d.enabled ? 'disable' : 'enable', d.enabled ? 'Disable' : 'Enable'],
       ['move-ou', 'Move OU'], ['group-add', 'Add to group']];

  var tags = isGroup
    ? ['<span class="tag tag-outline">' + esc(d.scope) + '</span>',
       '<span class="tag tag-neutral">' + esc(d.members) + ' members</span>']
    : ['<span class="tag tag-outline">' + esc(d.source) + '</span>',
       '<span class="tag tag-neutral">' + esc(d.status) + '</span>'];

  $('detailBody').innerHTML =
    '<div class="detail">' +
      '<div class="detail-head">' +
        '<span class="kicker">' + (isGroup ? 'Group' : 'User') + '</span>' +
        '<h2 class="detail-title">' + esc(d.name) + '</h2>' +
        '<div class="detail-tags">' + tags.join('') + '</div>' +
      '</div>' +
      '<hr class="rule">' +
      '<dl class="detail-fields">' + rows + '</dl>' +
      '<hr class="rule">' +
      '<div class="detail-fields">' +
        '<span class="detail-section-label">' + esc(memberLabel) + '</span>' + memberHtml +
      '</div>' +
      '<div class="detail-actions">' +
        actions.map(function (a) {
          return '<button class="btn btn-secondary" type="button" data-action="' + a[0] + '">' + esc(a[1]) + '</button>';
        }).join('') +
        '<button class="btn btn-ghost bulk-danger" type="button" data-action="delete">Delete</button>' +
      '</div>' +
    '</div>';
}

function updateBulkBar() {
  var ids = Object.keys(state.checked).filter(function (k) { return state.checked[k]; });
  $('bulkBar').hidden = (ids.length === 0);
  $('bulkCount').textContent = ids.length + ' selected';

  var isGroup = (state.tab === 'groups');
  els('#bulkBar [data-bulk]').forEach(function (b) {
    var kind = b.getAttribute('data-bulk');
    // Enable/Disable and Add-to-group are user-only operations.
    var userOnly = (kind === 'enable' || kind === 'disable' || kind === 'group-add');
    b.hidden = (isGroup && userOnly);
  });

  var all = $('checkAll');
  if (all) {
    all.checked = state.rows.length > 0 && state.rows.every(function (r) { return state.checked[r.id]; });
  }
}

function checkedRows() {
  return state.rows.filter(function (r) { return state.checked[r.id]; });
}

function targetsFrom(rows) {
  return rows.map(function (r) { return r.sam || r.dn; });
}

// ---------------------------------------------------------------------------
// Audit
// ---------------------------------------------------------------------------

function renderAuditFilters() {
  $('auditFilters').innerHTML = AUDIT_FILTERS.map(function (f) {
    return '<button class="chip" type="button" data-filter="' + f + '" aria-pressed="' +
           (state.auditFilter === f) + '">' + f + '</button>';
  }).join('');

  $('auditRanges').innerHTML = AUDIT_RANGES.map(function (r) {
    return '<button class="chip" type="button" data-range="' + r.key + '" aria-pressed="' +
           (state.auditRange === r.key) + '">' + esc(r.label) + '</button>';
  }).join('');

  $('auditCustom').hidden = (state.auditRange !== 'custom');
}

/* Resolves the selected chip into an absolute {from, to} window.
   Computed in the browser, so "last 24 hours" means 24 hours in the
   operator's own timezone; the ISO strings carry the offset and the server
   converts them to UTC for the SQL query. */
function auditWindow() {
  if (state.auditRange === 'custom') {
    return { from: state.auditFrom, to: state.auditTo };
  }

  var range = AUDIT_RANGES.filter(function (r) { return r.key === state.auditRange; })[0];
  if (!range || range.hours === null) { return { from: null, to: null }; }

  var from = new Date(Date.now() - (range.hours * 3600 * 1000));
  return { from: from.toISOString(), to: null };
}

function loadAudit() {
  var path = '/api/audit?filter=' + encodeURIComponent(state.auditFilter);
  if (state.auditQuery) { path += '&q=' + encodeURIComponent(state.auditQuery); }

  var window_ = auditWindow();
  if (window_.from) { path += '&from=' + encodeURIComponent(window_.from); }
  if (window_.to)   { path += '&to=' + encodeURIComponent(window_.to); }

  setAuditBusy(true);

  api(path).then(function (data) {
    state.auditRows = asArray(data.items);
    state.auditTotal = data.total || 0;
    state.auditSource = data.source || '';
    setAuditBusy(false);
    stampAudit();
    renderAudit();
  }).catch(function (err) {
    state.auditRows = [];
    state.auditTotal = 0;
    $('auditBody').innerHTML = '';
    $('auditLine').textContent = '';
    setAuditBusy(false);
    $('auditStamp').textContent = 'Not updated';
    renderAudit();
    toast('Could not read the audit log: ' + err.message, 'bad');
  });
}

/* The refresh button doubles as the progress indicator - there is no spinner
   anywhere else in the console, and a button that does nothing visible when
   pressed reads as a broken button. */
function setAuditBusy(busy) {
  var btn = $('auditRefresh');
  if (!btn) { return; }
  btn.disabled = busy;
  btn.textContent = busy ? 'Refreshing...' : 'Refresh';
}

/* How stale the table is. Local clock time, not "5 minutes ago": a relative
   label needs a timer to stay honest, and a wrong one on an audit screen is
   worse than none. */
function stampAudit() {
  var el = $('auditStamp');
  if (!el) { return; }
  var d = new Date();
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  el.textContent = 'Updated ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

/* Plain-language description of the window currently in force, so the count
   below the table is never ambiguous about what it counted. */
function windowLabel() {
  if (state.auditRange === 'custom') {
    if (!state.auditFrom && !state.auditTo) { return 'no range set'; }
    var parts = [];
    if (state.auditFrom) { parts.push('from ' + formatStamp(state.auditFrom)); }
    if (state.auditTo)   { parts.push('to ' + formatStamp(state.auditTo)); }
    return parts.join(' ');
  }
  var range = AUDIT_RANGES.filter(function (r) { return r.key === state.auditRange; })[0];
  if (!range) { return ''; }
  return range.label.toLowerCase();
}

function renderAudit() {
  if (!state.auditRows.length) {
    // Say which window came back empty - "nothing in the last 24 hours" and
    // "nothing at all" are very different answers for an auditor.
    var scope = 'No audit entries in ' + windowLabel();
    if (state.auditRange === 'all') { scope = 'No audit entries'; }
    if (state.auditFilter !== 'All') { scope += ' for the ' + state.auditFilter + ' filter'; }
    if (state.auditQuery) { scope += ' matching "' + state.auditQuery + '"'; }

    $('auditBody').innerHTML = '<tr><td colspan="8" data-label="">' +
      '<span class="muted-sm">' + esc(scope) + '. Entries are written here as changes are made.</span>' +
      '</td></tr>';
    $('auditLine').textContent = '';
    return;
  }

  $('auditBody').innerHTML = state.auditRows.map(function (r, i) {
    var cls = (r.result === 'Success') ? 'res-success' : 'res-other';
    var plan = undoPlan(r);
    var undoCell = plan.ok
      ? '<button class="btn btn-ghost btn-undo" type="button" data-undo="' + i + '">Undo</button>'
      : '<span class="cell-disabled undo-no" title="' + esc(plan.reason) + '">-</span>';

    return '<tr>' +
      '<td data-label="Time" class="cell-muted">' + esc(formatStamp(r.time)) + '</td>' +
      '<td data-label="Action" class="cell-name">' + esc(r.action) + '</td>' +
      '<td data-label="Target">' + esc(r.target) + '</td>' +
      '<td data-label="Operator" class="cell-muted">' + esc(r.operator) + '</td>' +
      '<td data-label="Controller" class="cell-disabled">' + esc(r.dc) + '</td>' +
      '<td data-label="Reason" class="cell-muted cell-wrap">' + esc(r.reason) + '</td>' +
      '<td data-label="Result" class="' + cls + '">' + esc(r.result) + '</td>' +
      '<td data-label="Undo">' + undoCell + '</td>' +
      '</tr>';
  }).join('');

  var undoButtons = $('auditBody').querySelectorAll('[data-undo]');
  for (var u = 0; u < undoButtons.length; u++) {
    undoButtons[u].onclick = function () {
      askUndo(state.auditRows[parseInt(this.getAttribute('data-undo'), 10)]);
    };
  }

  var line = state.auditRows.length + ' of ' + state.auditTotal + ' entries in ' + windowLabel() +
             ' - written by this console, newest first';
  if (state.auditSource === 'sql') { line += ' - stored in SQL Server'; }
  else if (state.auditSource === 'file') { line += ' - stored in files on the server (no SQL configured)'; }
  $('auditLine').textContent = line;
}

// ---------------------------------------------------------------------------
// Undo
//
// This mirrors Get-DsmtUndoPlan in server/lib/DsmtHttp.ps1, and the SERVER IS
// AUTHORITATIVE: it recomputes the plan and refuses anything not on its own
// list. This copy exists only to decide whether to paint a button, and to say
// why when it does not. If the two ever disagree, fix this one - a button that
// appears and then fails is worse than no button.
// ---------------------------------------------------------------------------

function undoPlan(r) {
  function no(why) { return { ok: false, reason: why, what: '' }; }

  if (!r) { return no('No entry.'); }

  // Only a change that actually happened can be put back. A Failed or Denied
  // record changed nothing, so there is nothing to reverse.
  if (r.result !== 'Success') {
    return no('This action did not succeed, so there is nothing to undo.');
  }

  var detail = r.detail || '';
  var m;

  if (r.action === 'Disable user') { return { ok: true, reason: '', what: 'enable ' + r.target + ' again' }; }
  if (r.action === 'Enable user')  { return { ok: true, reason: '', what: 'disable ' + r.target + ' again' }; }

  if (r.action === 'Add to group') {
    m = /^into\s+(.+)$/.exec(detail);
    if (!m) { return no('The record does not name the group that was joined.'); }
    return { ok: true, reason: '', what: 'remove ' + r.target + ' from ' + m[1] };
  }

  if (r.action === 'Remove from group') {
    m = /^from\s+(.+)$/.exec(detail);
    if (!m) { return no('The record does not name the group that was left.'); }
    return { ok: true, reason: '', what: 'add ' + r.target + ' back to ' + m[1] };
  }

  if (r.action === 'Move OU') {
    m = /^from\s+(.+?)\s+into\s+(.+)$/.exec(detail);
    if (!m) {
      return no('The record does not say which OU the object came from. Moves recorded from 1.11.0 onwards can be undone.');
    }
    return { ok: true, reason: '', what: 'move ' + r.target + ' back to ' + m[1] };
  }

  if (r.action === 'Reset password') {
    return no('A password cannot be undone - DSMT never knew the previous one.');
  }
  if (r.action === 'Unlock account') {
    return no('An unlock cannot be undone: a lockout comes from failed sign-ins, not from an administrator.');
  }
  if (/^(Create|Delete) (user|group)$/.test(r.action) || r.action === 'Bulk CSV import') {
    return no('Creating and deleting are not reversible here - a recreated object gets a new SID, so every permission that pointed at the old one stays broken. Use the AD Recycle Bin.');
  }

  return no('There is no defined way to reverse "' + (r.action || '') + '".');
}

function askUndo(r) {
  var plan = undoPlan(r);
  if (!plan.ok) { toast(plan.reason, 'bad'); return; }

  openDialog({
    title: 'Undo ' + r.action,
    confirmLabel: 'Undo it',
    body:
      '<p class="dialog-note">This will <strong>' + esc(plan.what) + '</strong>.</p>' +
      '<dl class="detail-fields">' +
        '<div class="detail-row"><dt>Original action</dt><dd>' + esc(r.action) + '</dd></div>' +
        '<div class="detail-row"><dt>Performed by</dt><dd>' + esc(r.operator) + '</dd></div>' +
        '<div class="detail-row"><dt>When</dt><dd>' + esc(formatStamp(r.time)) + '</dd></div>' +
      '</dl>' +
      // Said plainly, because an "undo" that quietly rewrote history would be
      // the single worst thing this tool could do.
      '<p class="dialog-note">The original entry stays in the audit log exactly as it is. ' +
      'This is recorded as a new change, made by you, now - and it runs with your own ' +
      'directory rights, like any other action here.</p>' +
      reasonField(),
    onConfirm: function () {
      var reason = readReason();
      if (!reason) { dialogError('Give a reason for the undo.'); return; }

      api('/api/audit/undo', {
        method: 'POST',
        body: { action: r.action, target: r.target, detail: r.detail || '', reason: reason }
      }).then(function (res) {
        closeDialog();
        if (res.ok) {
          toast('Undone: ' + plan.what + '.', 'good');
        } else {
          toast('The undo did not succeed. See the audit log for the reason.', 'bad');
        }
        loadAudit();
      }).catch(function (err) {
        dialogError(err.message);
      });
    }
  });
}

/* Formats a Date for a <input type="datetime-local">, which wants local time
   with no timezone suffix. */
function toLocalInput(date) {
  function pad(n) { return ('0' + n).slice(-2); }
  return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) +
         'T' + pad(date.getHours()) + ':' + pad(date.getMinutes());
}

function formatStamp(iso) {
  if (!iso) { return ''; }
  var d = new Date(iso);
  if (isNaN(d.getTime())) { return iso; }
  var today = new Date(); today.setHours(0, 0, 0, 0);
  var day = new Date(d.getTime()); day.setHours(0, 0, 0, 0);
  var hm = ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
  if (day.getTime() === today.getTime()) { return 'Today ' + hm; }
  if (day.getTime() === today.getTime() - 86400000) { return 'Yesterday ' + hm; }
  return d.toLocaleDateString(undefined, { day: '2-digit', month: 'short' }) + ' ' + hm;
}

// ---------------------------------------------------------------------------
// CSV export
// ---------------------------------------------------------------------------

function csvCell(value) {
  var text = (value === null || value === undefined) ? '' : String(value);
  if (/[",\r\n]/.test(text)) { return '"' + text.replace(/"/g, '""') + '"'; }
  return text;
}

function downloadCsv(filename, header, rows) {
  var lines = [header.map(csvCell).join(',')];
  rows.forEach(function (r) { lines.push(r.map(csvCell).join(',')); });
  // BOM so Excel opens UTF-8 correctly.
  var blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  var url = URL.createObjectURL(blob);
  var a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  window.setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
}

function stampName() {
  var d = new Date();
  return d.getFullYear() + ('0' + (d.getMonth() + 1)).slice(-2) + ('0' + d.getDate()).slice(-2) +
         '-' + ('0' + d.getHours()).slice(-2) + ('0' + d.getMinutes()).slice(-2);
}

function exportCurrent() {
  if (!state.rows.length) { toast('There is nothing to export.', 'bad'); return; }
  var cols = visibleCols();
  downloadCsv(
    'dsmt-' + state.tab + '-' + stampName() + '.csv',
    cols.map(function (c) { return c.label; }),
    state.rows.map(function (r) { return cols.map(function (c) { return r[c.key]; }); })
  );
  toast('Exported ' + state.rows.length + ' rows.');
}

function exportAudit() {
  if (!state.auditRows.length) { toast('There is nothing to export.', 'bad'); return; }
  downloadCsv(
    'dsmt-audit-' + stampName() + '.csv',
    ['Time', 'Action', 'Target', 'Operator', 'Controller', 'Reason', 'Result', 'Detail'],
    state.auditRows.map(function (r) {
      return [r.time, r.action, r.target, r.operator, r.dc, r.reason, r.result, r.detail];
    })
  );
  toast('Exported ' + state.auditRows.length + ' audit entries.');
}

// ---------------------------------------------------------------------------
// Dialog engine
// ---------------------------------------------------------------------------

var dialogState = { onConfirm: null, onCancel: null, isIdleWarning: false };

function openDialog(config) {
  dialogState.onCancel = config.onCancel || null;
  dialogState.isIdleWarning = !!config.isIdleWarning;
  $('dialogTitle').textContent = config.title;
  $('dialogBody').innerHTML = config.body;
  $('dialogConfirm').textContent = config.confirmLabel || 'Apply';
  $('dialogConfirm').hidden = !!config.hideConfirm;
  $('dialogCancel').textContent = config.cancelLabel || 'Cancel';
  $('dialogError').hidden = true;
  $('dialogError').textContent = '';
  $('dialogBackdrop').hidden = false;
  dialogState.onConfirm = config.onConfirm || null;

  if (config.onOpen) { config.onOpen(); }

  window.setTimeout(function () {
    var first = el('#dialogBody input:not([type=hidden]), #dialogBody select, #dialogBody textarea');
    if (first) { first.focus(); }
  }, 40);
}

function closeDialog() {
  $('dialogBackdrop').hidden = true;
  dialogState.onConfirm = null;
  dialogState.onCancel = null;
  dialogState.isIdleWarning = false;
}

function dialogError(message) {
  $('dialogError').textContent = message;
  $('dialogError').hidden = false;
}

function reasonField() {
  return '<div class="field"><label for="dlgReason">Reason for the audit log (required)</label>' +
         '<input class="input" id="dlgReason" placeholder="Ticket ID or justification" autocomplete="off"></div>';
}

function readReason() {
  var input = $('dlgReason');
  if (!input) { return ''; }
  return input.value.trim();
}

function ouSelect(selectedDn) {
  var options = asArray(state.ous).map(function (o) {
    var sel = (o.dn === selectedDn) ? ' selected' : '';
    return '<option value="' + esc(o.dn) + '"' + sel + '>' + esc(o.path) + '</option>';
  }).join('');
  return '<div class="field"><label for="dlgOu">Target OU</label>' +
         '<select class="input" id="dlgOu">' + options + '</select></div>';
}

function withOus(then) {
  if (state.ous) { then(); return; }
  api('/api/ous').then(function (data) {
    state.ous = asArray(data.items);
    then();
  }).catch(function (err) {
    toast('Could not read the OU list: ' + err.message, 'bad');
  });
}

/* Runs a write, then reports what actually happened per target. A partial
   result is shown as a partial result - never rounded up to "done". */
function runAction(path, payload, label, afterOk) {
  return api(path, { method: 'POST', body: payload }).then(function (res) {
    var results = asArray(res.results);
    var failed = results.filter(function (r) { return !r.ok; });

    if (res.result === 'Success') {
      toast(label + ': ' + res.succeeded + ' succeeded.');
      closeDialog();
    } else if (res.result === 'Partial') {
      toast(label + ': ' + res.succeeded + ' succeeded, ' + res.failed + ' failed.', 'bad');
      showResults(label, results);
    } else {
      var first = failed.length ? failed[0].error : 'The directory rejected the change.';
      dialogError(first);
      toast(label + ' failed.', 'bad');
    }

    if (res.generatedPassword) { showGeneratedPassword(res.generatedPassword); }
    if (afterOk && res.ok) { afterOk(res); }
    return res;
  }).catch(function (err) {
    dialogError(err.message);
    toast(label + ' failed: ' + err.message, 'bad');
  });
}

function showResults(label, results) {
  openDialog({
    title: label + ' - results',
    hideConfirm: true,
    cancelLabel: 'Close',
    body: '<ul class="result-list">' + results.map(function (r) {
      return '<li class="' + (r.ok ? 'result-ok' : 'result-bad') + '">' +
             '<strong>' + esc(r.target) + '</strong><span>' + esc(r.ok ? 'OK' : r.error) + '</span></li>';
    }).join('') + '</ul>'
  });
}

function showGeneratedPassword(password) {
  openDialog({
    title: 'Generated password',
    hideConfirm: true,
    cancelLabel: 'Done',
    body: '<p class="dialog-note">DSMT generated this password because none was supplied. ' +
          '<strong>It is shown once</strong> and is deliberately never written to the audit log - ' +
          'copy it now and hand it over securely.</p>' +
          '<div class="secret" id="genPassword">' + esc(password) + '</div>' +
          '<div class="set-actions">' +
            '<button class="btn btn-primary" type="button" id="copyGenPassword">Copy password</button>' +
          '</div>' +
          '<div class="set-result" id="genPasswordResult"></div>',
    onOpen: function () {
      $('copyGenPassword').addEventListener('click', function () {
        // Reads the element rather than closing over the string, so what is
        // copied is provably what is on screen.
        copyText($('genPassword').textContent, 'genPasswordResult');
      });
    }
  });
}

function refreshAfterWrite() {
  loadRows();
  if (state.selectedId) {
    var keep = state.selectedId;
    window.setTimeout(function () { selectRow(keep, true); }, 400);
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

function actionResetPassword(rows) {
  openDialog({
    title: targetTitle('Reset password', rows),
    confirmLabel: 'Reset',
    body: targetBlock(rows) +
          '<p class="dialog-note">The new password is written to the directory and the change is ' +
          'recorded in the audit log with your account and the reason below.</p>' +
          '<div class="field"><label for="dlgPw">New password (leave blank to generate one)</label>' +
          '<input class="input" id="dlgPw" type="text" autocomplete="new-password" placeholder="Generate automatically"></div>' +
          '<label class="checkline"><input type="checkbox" class="check" id="dlgMustChange" checked> ' +
          'User must change password at next sign-in</label>' +
          reasonField(),
    onConfirm: function () {
      var reason = readReason();
      if (!reason) { dialogError('A reason is required.'); return; }
      runAction('/api/actions/reset-password', {
        targets: targetsFrom(rows),
        password: $('dlgPw').value,
        mustChange: $('dlgMustChange').checked,
        reason: reason
      }, 'Reset password', refreshAfterWrite);
    }
  });
}

/* ---------------------------------------------------------------------------
   WHO an action applies to.

   "Disable account - 1 object" says nothing about which object, and the
   detail pane can be showing a different user than the one ticked in the
   grid. Someone confirming a destructive change has to be able to see the
   target without leaving the dialog.
   --------------------------------------------------------------------------- */

function targetTitle(verb, rows) {
  if (rows.length === 1) { return verb + ' - ' + (rows[0].name || rows[0].sam); }
  return verb + ' - ' + rows.length + ' objects';
}

/* Named in the body too, not only in the title: a long name is truncated by
   the title's width, and this is the one place it must be unambiguous. */
function targetBlock(rows) {
  if (!rows.length) { return ''; }

  if (rows.length === 1) {
    var r = rows[0];
    var sub = r.sam && r.sam !== r.name ? ' <span class="target-sub">' + esc(r.sam) + '</span>' : '';
    return '<div class="target-box"><span class="target-label">Applies to</span>' +
           '<span class="target-name">' + esc(r.name || r.sam) + '</span>' + sub + '</div>';
  }

  // Every name, not "and 12 more" - a bulk action the operator cannot fully
  // read is a bulk action they cannot check.
  return '<div class="target-box"><span class="target-label">Applies to ' + rows.length + ' objects</span>' +
         '<ul class="target-list">' +
         rows.map(function (r) {
           return '<li>' + esc(r.name || r.sam) +
                  (r.sam && r.sam !== r.name ? ' <span class="target-sub">' + esc(r.sam) + '</span>' : '') +
                  '</li>';
         }).join('') + '</ul></div>';
}

function actionSimple(kind, rows) {
  var config = {
    'unlock':  { path: '/api/actions/unlock', title: 'Unlock account', label: 'Unlock', extra: {} },
    'enable':  { path: '/api/actions/set-enabled', title: 'Enable account', label: 'Enable', extra: { enabled: true } },
    'disable': { path: '/api/actions/set-enabled', title: 'Disable account', label: 'Disable', extra: { enabled: false } }
  }[kind];

  openDialog({
    title: targetTitle(config.title, rows),
    confirmLabel: config.label,
    body: targetBlock(rows) +
          '<p class="dialog-note">This change is written to the directory and recorded in the audit log ' +
          'with your account and the reason below.</p>' + reasonField(),
    onConfirm: function () {
      var reason = readReason();
      if (!reason) { dialogError('A reason is required.'); return; }
      var payload = { targets: targetsFrom(rows), reason: reason };
      Object.keys(config.extra).forEach(function (k) { payload[k] = config.extra[k]; });
      runAction(config.path, payload, config.title, refreshAfterWrite);
    }
  });
}

function actionMoveOu(rows) {
  withOus(function () {
    openDialog({
      title: targetTitle('Move OU', rows),
      confirmLabel: 'Move',
      body: targetBlock(rows) +
            '<p class="dialog-note">Moving replicates to every domain controller.</p>' +
            ouSelect(rows[0].ouDn) + reasonField(),
      onConfirm: function () {
        var reason = readReason();
        if (!reason) { dialogError('A reason is required.'); return; }
        runAction('/api/actions/move-ou', {
          targets: targetsFrom(rows),
          ou: $('dlgOu').value,
          type: (state.tab === 'groups' ? 'group' : 'user'),
          reason: reason
        }, 'Move OU', refreshAfterWrite);
      }
    });
  });
}

function actionAddToGroup(rows) {
  openDialog({
    title: targetTitle('Add to group', rows),
    confirmLabel: 'Add',
    body: targetBlock(rows) +
          '<div class="field"><label for="dlgGroupSearch">Find the group</label>' +
          '<input class="input" id="dlgGroupSearch" placeholder="Type at least two characters" autocomplete="off"></div>' +
          '<div class="field"><label for="dlgGroup">Group</label>' +
          '<select class="input" id="dlgGroup"><option value="">Search for a group first</option></select></div>' +
          reasonField(),
    onOpen: function () {
      wirePicker('dlgGroupSearch', 'dlgGroup', '/api/groups');
    },
    onConfirm: function () {
      var reason = readReason();
      var group = $('dlgGroup').value;
      if (!group) { dialogError('Choose a group.'); return; }
      if (!reason) { dialogError('A reason is required.'); return; }
      runAction('/api/actions/group-add', {
        targets: targetsFrom(rows), group: group, reason: reason
      }, 'Add to group', refreshAfterWrite);
    }
  });
}

function actionAddMembers(group) {
  openDialog({
    title: 'Add members - ' + group.name,
    confirmLabel: 'Add',
    body: '<div class="field"><label for="dlgUserSearch">Find users</label>' +
          '<input class="input" id="dlgUserSearch" placeholder="Type at least two characters" autocomplete="off"></div>' +
          '<div class="field"><label for="dlgUsers">Users (Ctrl or Shift to pick several)</label>' +
          '<select class="input" id="dlgUsers" multiple size="6"><option value="">Search for a user first</option></select></div>' +
          reasonField(),
    onOpen: function () {
      wirePicker('dlgUserSearch', 'dlgUsers', '/api/users');
    },
    onConfirm: function () {
      var reason = readReason();
      var picked = Array.prototype.slice.call($('dlgUsers').selectedOptions)
                        .map(function (o) { return o.value; }).filter(Boolean);
      if (!picked.length) { dialogError('Choose at least one user.'); return; }
      if (!reason) { dialogError('A reason is required.'); return; }
      runAction('/api/actions/group-add', {
        targets: picked, group: group.sam || group.dn, reason: reason
      }, 'Add members', refreshAfterWrite);
    }
  });
}

function actionRemoveMember(memberDn) {
  var group = state.detail;
  openDialog({
    title: 'Remove from ' + group.name,
    confirmLabel: 'Remove',
    body: '<p class="dialog-note">Removing <strong>' + esc(memberDn) + '</strong> from ' +
          esc(group.name) + '.</p>' + reasonField(),
    onConfirm: function () {
      var reason = readReason();
      if (!reason) { dialogError('A reason is required.'); return; }
      runAction('/api/actions/group-remove', {
        targets: [memberDn], group: group.sam || group.dn, reason: reason
      }, 'Remove from group', refreshAfterWrite);
    }
  });
}

function actionDelete(rows) {
  var isGroup = (state.tab === 'groups');
  openDialog({
    title: 'Delete ' + rows.length + ' ' + (isGroup ? 'group' : 'user') + (rows.length === 1 ? '' : 's'),
    confirmLabel: 'Delete',
    body: '<p class="dialog-note">This removes the object from the directory. Deletions replicate to all ' +
          'controllers and are recorded in the audit log.</p>' +
          '<ul class="result-list">' + rows.map(function (r) {
            return '<li class="result-bad"><strong>' + esc(r.name) + '</strong><span>' + esc(r.sam) + '</span></li>';
          }).join('') + '</ul>' + reasonField(),
    onConfirm: function () {
      var reason = readReason();
      if (!reason) { dialogError('A reason is required.'); return; }
      runAction('/api/actions/delete', {
        targets: targetsFrom(rows),
        type: (isGroup ? 'group' : 'user'),
        reason: reason
      }, 'Delete', function () {
        state.selectedId = null;
        state.detail = null;
        state.checked = {};
        $('detailBody').innerHTML = '';
        closeDetail();
        loadRows();
      });
    }
  });
}

function actionCreateUser() {
  withOus(function () {
    openDialog({
      title: 'New user',
      confirmLabel: 'Create',
      body: '<div class="row-2">' +
              '<div class="field"><label for="dlgGiven">First name</label><input class="input" id="dlgGiven"></div>' +
              '<div class="field"><label for="dlgSur">Last name</label><input class="input" id="dlgSur"></div>' +
            '</div>' +
            '<div class="field"><label for="dlgDisplay">Display name</label><input class="input" id="dlgDisplay"></div>' +
            '<div class="field"><label for="dlgSam">samAccountName</label><input class="input" id="dlgSam" autocomplete="off"></div>' +
            '<div class="row-2">' +
              '<div class="field"><label for="dlgDept">Department</label><input class="input" id="dlgDept"></div>' +
              '<div class="field"><label for="dlgTitle">Title</label><input class="input" id="dlgTitle"></div>' +
            '</div>' +
            ouSelect(null) +
            '<div class="field"><label for="dlgPw">Password (leave blank to generate one)</label>' +
            '<input class="input" id="dlgPw" type="text" autocomplete="new-password"></div>' +
            '<label class="checkline"><input type="checkbox" class="check" id="dlgMustChange" checked> ' +
            'User must change password at next sign-in</label>' +
            '<label class="checkline"><input type="checkbox" class="check" id="dlgEnabled" checked> ' +
            'Enable the account</label>' +
            reasonField(),
      onOpen: function () {
        // Fill display name and samAccountName as the names are typed, but
        // stop as soon as the operator edits either one by hand.
        var given = $('dlgGiven'), sur = $('dlgSur'), display = $('dlgDisplay'), sam = $('dlgSam');
        var autoDisplay = true, autoSam = true;
        display.addEventListener('input', function () { autoDisplay = false; });
        sam.addEventListener('input', function () { autoSam = false; });
        function sync() {
          var full = (given.value + ' ' + sur.value).trim();
          if (autoDisplay) { display.value = full; }
          if (autoSam && given.value && sur.value) {
            sam.value = (given.value.charAt(0) + sur.value).toLowerCase().replace(/[^a-z0-9._-]/g, '');
          }
        }
        given.addEventListener('input', sync);
        sur.addEventListener('input', sync);
      },
      onConfirm: function () {
        var reason = readReason();
        var display = $('dlgDisplay').value.trim();
        var sam = $('dlgSam').value.trim();
        if (!display || !sam) { dialogError('Display name and samAccountName are required.'); return; }
        if (!reason) { dialogError('A reason is required.'); return; }

        runAction('/api/users', {
          displayName: display, sam: sam, ou: $('dlgOu').value,
          givenName: $('dlgGiven').value.trim(), surname: $('dlgSur').value.trim(),
          department: $('dlgDept').value.trim(), title: $('dlgTitle').value.trim(),
          password: $('dlgPw').value, mustChange: $('dlgMustChange').checked,
          enabled: $('dlgEnabled').checked, reason: reason
        }, 'Create user', refreshAfterWrite);
      }
    });
  });
}

function actionCreateGroup() {
  withOus(function () {
    openDialog({
      title: 'New group',
      confirmLabel: 'Create',
      body: '<div class="field"><label for="dlgName">Group name</label><input class="input" id="dlgName" autocomplete="off"></div>' +
            '<div class="row-2">' +
              '<div class="field"><label for="dlgCategory">Category</label>' +
              '<select class="input" id="dlgCategory"><option>Security</option><option>Distribution</option></select></div>' +
              '<div class="field"><label for="dlgScope">Scope</label>' +
              '<select class="input" id="dlgScope"><option>Global</option><option>Universal</option><option value="DomainLocal">Domain local</option></select></div>' +
            '</div>' +
            ouSelect(null) +
            '<div class="field"><label for="dlgDesc">Description</label><input class="input" id="dlgDesc"></div>' +
            reasonField(),
      onConfirm: function () {
        var reason = readReason();
        var name = $('dlgName').value.trim();
        if (!name) { dialogError('A group name is required.'); return; }
        if (!reason) { dialogError('A reason is required.'); return; }
        runAction('/api/groups', {
          name: name, ou: $('dlgOu').value,
          category: $('dlgCategory').value, scope: $('dlgScope').value,
          description: $('dlgDesc').value.trim(), reason: reason
        }, 'Create group', refreshAfterWrite);
      }
    });
  });
}

function importPreviewHtml(res) {
  var rows = asArray(res.rows);

  var body = rows.map(function (r) {
    var ok = (r.verdict === 'create');
    return '<li>' +
      '<span class="' + (ok ? 'result-ok' : 'result-bad') + '">' + (ok ? 'create' : 'skip') + '</span>' +
      '<span><strong>' + esc(r.sam || '(blank)') + '</strong>' +
      (ok ? ' &rarr; ' + esc(r.ou) + (r.generated ? ' (password generated)' : '') : '') +
      (r.why ? ' - ' + esc(r.why) : '') +
      '</span></li>';
  }).join('');

  return '<div class="set-state' + (res.wouldSkip ? ' set-state-off' : ' set-state-on') + '">' +
           '<div class="set-state-head"><span class="set-state-dot"></span>' +
           '<span>' + res.wouldCreate + ' of ' + res.total + ' rows would be created' +
           (res.wouldSkip ? ', ' + res.wouldSkip + ' skipped' : '') + '</span></div>' +
         '</div>' +
         '<ul class="result-list">' + body + '</ul>' +
         '<p class="dialog-note"><strong>Nothing has been written yet.</strong> This is a preview, not a ' +
         'guarantee: the directory can change between this check and the import, and Active Directory ' +
         'still has the last word on the password policy and on whether you may create accounts in ' +
         'that OU.</p>';
}

function actionImportCsv() {
  state.csvPreviewed = false;
  withOus(function () {
    openDialog({
      title: 'Bulk CSV import',
      confirmLabel: 'Preview',
      body: '<p class="dialog-note">Header row required. Recognised columns: ' +
            '<strong>SamAccountName</strong> (required), DisplayName, GivenName, Surname, ' +
            'Department, Title, Password, OU. A row without a Password gets a generated one; ' +
            'a row without an OU uses the OU chosen here.</p>' +
            '<div class="field"><label for="dlgFile">CSV file</label>' +
            '<input class="input" id="dlgFile" type="file" accept=".csv,text/csv"></div>' +
            '<div class="field"><label for="dlgCsv">or paste the CSV</label>' +
            '<textarea class="input" id="dlgCsv" placeholder="SamAccountName,DisplayName,Department"></textarea></div>' +
            ouSelect(null) + reasonField() +
            '<div id="dlgPreview"></div>',
      onOpen: function () {
        // Any edit invalidates the preview. Without this, changing the CSV
        // after previewing would arm the write button for a file nobody has
        // seen checked - which is the exact failure the preview exists to
        // prevent, just one step later.
        var invalidate = function () {
          if (!state.csvPreviewed) { return; }
          state.csvPreviewed = false;
          $('dlgPreview').innerHTML = '';
          $('dialogConfirm').hidden = false;
          $('dialogConfirm').textContent = 'Preview';
        };

        $('dlgCsv').addEventListener('input', invalidate);
        $('dlgOu').addEventListener('change', invalidate);

        $('dlgFile').addEventListener('change', function (e) {
          var file = e.target.files && e.target.files[0];
          if (!file) { return; }
          var reader = new FileReader();
          reader.onload = function () {
            $('dlgCsv').value = String(reader.result);
            invalidate();
          };
          reader.readAsText(file);
        });
      },
      // Two steps, and the first one is not optional. An import that
      // half-succeeds with no preview means the operator finds out what it
      // was going to do by reading what it already did. The confirm button
      // says "Preview" until a preview has been seen; only then does it
      // become the button that writes.
      onConfirm: function () {
        var reason = readReason();
        var csv = $('dlgCsv').value.trim();
        if (!csv) { dialogError('Choose a file or paste the CSV.'); return; }
        if (!reason) { dialogError('A reason is required.'); return; }

        if (!state.csvPreviewed) {
          api('/api/users/import', {
            method: 'POST',
            body: { csv: csv, ou: $('dlgOu').value, reason: reason, dryRun: true }
          }).then(function (res) {
            $('dlgPreview').innerHTML = importPreviewHtml(res);
            state.csvPreviewed = true;

            if (!res.wouldCreate) {
              $('dialogConfirm').hidden = true;
              dialogError('Nothing in this file would be created. Fix the rows above and preview again.');
            } else {
              $('dialogConfirm').textContent = 'Create ' + res.wouldCreate + ' user(s)';
            }
          }).catch(function (err) { dialogError(err.message); });
          return;
        }

        runAction('/api/users/import', {
          csv: csv, ou: $('dlgOu').value, reason: reason
        }, 'Bulk CSV import', refreshAfterWrite);
      }
    });
  });
}

/* Says plainly where operators, sessions, the directory snapshot and the
   audit log are being written - including when SQL is off, so nobody assumes
   a database is recording things that are only in a local file. */
function storageLine() {
  var s = state.storage;
  if (!s) { return ''; }
  if (s.sqlEnabled) {
    return 'SQL Server ' + s.sqlServer + ', database ' + s.sqlDatabase;
  }
  return 'No SQL Server configured - audit log written to files on the server only';
}

// ---------------------------------------------------------------------------
// Tools
//
// Same layout as Settings: a rail of tools, one open at a time. The rail is
// data, so adding the next tool is one entry here plus its render function.
//
// EVERY TOOL MUST READ ITS STATE LIVE. None of them may remember what the
// operator clicked and paint a tick from it. A wizard that shows step 3 as
// done because the button was pressed - rather than because the directory
// says so - is the fake-data failure in CLAUDE.md wearing a different hat,
// and on this screen it would send someone away believing a gMSA works when
// it does not.
// ---------------------------------------------------------------------------

var TOOLS = [
  { key: 'gmsa',     label: 'gMSA',      hint: 'Service account for DSMT', render: renderGmsaTool },
  { key: 'adhealth', label: 'AD health', hint: 'Replication, FSMO, clocks', render: renderAdHealthTool }
];

var TOOL_KEY = 'dsmt.tools.current';

/* Jump straight to the AD health tool - what a notification about AD health
   should do when you click it. Selects the sub-tool first so loadTools()
   renders that one rather than whichever was last open. */
function openAdHealthTool() {
  writeSetting(TOOL_KEY, 'adhealth');
  setTab('tools');
}

function loadTools() {
  var current = readSetting(TOOL_KEY, TOOLS[0].key);
  var known = false;
  var i;
  for (i = 0; i < TOOLS.length; i++) { if (TOOLS[i].key === current) { known = true; } }
  if (!known) { current = TOOLS[0].key; }

  var navHtml = '';
  for (i = 0; i < TOOLS.length; i++) {
    navHtml += '<button class="set-nav-item' + (TOOLS[i].key === current ? ' is-active' : '') +
               '" type="button" data-tool="' + TOOLS[i].key + '">' +
               '<span>' + esc(TOOLS[i].label) + '</span>' +
               '<span class="set-nav-hint">' + esc(TOOLS[i].hint) + '</span></button>';
  }
  $('toolsNav').innerHTML = navHtml;

  var items = $('toolsNav').querySelectorAll('.set-nav-item');
  for (i = 0; i < items.length; i++) {
    items[i].onclick = function () {
      writeSetting(TOOL_KEY, this.getAttribute('data-tool'));
      loadTools();
    };
  }

  for (i = 0; i < TOOLS.length; i++) {
    if (TOOLS[i].key === current) { TOOLS[i].render(); }
  }
}

/* ---------------------------------------------------------------------------
   gMSA.

   Five steps, and the honest split between them is the point:

     1  KDS root key      - forest-wide, once ever. Ten-hour convergence.
     2  Permitted group   - DSMT creates it, as the operator.
     3  Computers in it   - DSMT manages them, as the operator.
     4  Install on host   - CANNOT run here: needs local administrator.
     5  Point DSMT at it  - Settings -> Service account.

   Steps 4 and 5 produce commands rather than pretending. The alternative -
   a button that fails with an access error - teaches nothing.
   --------------------------------------------------------------------------- */

function renderGmsaTool() {
  $('toolsBody').innerHTML = '<p class="muted-sm">Reading the directory...</p>';

  var group = readSetting('dsmt.tools.gmsa.group', '');
  var name  = readSetting('dsmt.tools.gmsa.name', '');

  var path = '/api/tools/gmsa/state?group=' + encodeURIComponent(group) +
             '&gmsa=' + encodeURIComponent(name);

  // The OU list is needed by step 2 and is cached after the first fetch;
  // without this the "Create it in" list would be empty until the operator
  // happened to open a dialog that loads it.
  withOus(function () {
    api(path).then(function (data) {
      state.gmsa = data;
      paintGmsa();
    }).catch(function (err) {
      $('toolsBody').innerHTML = '<div class="error-box"><strong>Could not read the directory.</strong>' +
                                 esc(explainApiError(err.message)) + '</div>';
    });
  });
}

function gmsaStep(n, title, status, bodyHtml) {
  return '<section class="set-card tool-step tool-' + esc(status) + '" id="gmsaStep' + n + '">' +
           '<div class="tool-step-head">' +
             '<span class="tool-step-n">' + n + '</span>' +
             '<h2 class="set-h">' + esc(title) + '</h2>' +
             '<span class="health-verdict">' + esc(gmsaWord(status)) + '</span>' +
           '</div>' +
           bodyHtml +
         '</section>';
}

function gmsaWord(status) {
  if (status === 'ok') { return 'Done'; }
  if (status === 'warn') { return 'Waiting'; }
  if (status === 'manual') { return 'Run by hand'; }
  return 'To do';
}

function paintGmsa() {
  var d = state.gmsa;
  var kds = d.kds || {};
  var group = d.groupName || '';
  var name = d.gmsaName || '';

  // ---- requirements, always visible -----------------------------------
  var intro =
    '<section class="set-card">' +
      '<h2 class="set-h">What a gMSA needs</h2>' +
      '<p class="dialog-note">A group managed service account has no password anyone knows: ' +
      'the domain generates it, rotates it every 30 days, and it never expires. It is the right ' +
      'way to run DSMT. Standing one up for the first time needs all of the following.</p>' +
      '<ul class="tool-reqs">' +
        '<li><strong>Domain functional level 2012 or higher.</strong> Not negotiable - gMSAs do not exist below it.</li>' +
        '<li><strong>A KDS root key in the forest</strong>, created once, ever. Step 1 below.</li>' +
        '<li><strong>Ten hours</strong> after that key is created before any gMSA can be used, ' +
        'while domain controllers converge on it. This is the step that surprises people.</li>' +
        '<li><strong>Rights:</strong> creating the KDS root key needs Enterprise or Domain Admin in ' +
        'the forest root. Creating the group and the account needs delegated create rights in the ' +
        'target OU. Installing on a host needs <strong>local administrator on that host</strong>.</li>' +
        '<li><strong>Windows Server 2012 or later</strong> on any machine that will use the account.</li>' +
      '</ul>' +
      '<p class="dialog-note">DSMT performs steps 1 to 3 as <strong>you</strong>, so the domain ' +
      'enforces your rights and records your name. Step 4 cannot run here at all - it needs local ' +
      'administrator on the DSMT host, which this process deliberately does not have.</p>' +
    '</section>';

  // ---- step 1: KDS root key -------------------------------------------
  var kdsStatus = 'todo';
  var kdsBody = '';

  if (kds.Error) {
    kdsBody = '<div class="error-box"><strong>Could not read the KDS root keys.</strong>' +
              esc(kds.Error) + '</div>';
  } else if (kds.Exists && kds.Usable) {
    kdsStatus = 'ok';
    kdsBody = '<p class="set-good">This forest has a usable KDS root key, effective ' +
              esc(formatStamp(kds.EffectiveUtc)) + '. Nothing to do here - a second key would not help.</p>';
  } else if (kds.Exists && !kds.Usable) {
    kdsStatus = 'warn';
    kdsBody = '<p class="set-warn">The key exists but is <strong>not usable yet</strong>: about ' +
              esc(String(kds.HoursRemaining)) + ' hour(s) remain of the ' + esc(String(d.waitHours)) +
              '-hour convergence window (usable from ' + esc(formatStamp(kds.UsableFromUtc)) + '). ' +
              'Creating a gMSA before then fails with an error that mentions none of this. ' +
              '<strong>Wait - this is not a fault.</strong></p>';
  } else {
    kdsBody =
      '<p class="set-warn">This forest has <strong>no KDS root key</strong>, so no gMSA can exist ' +
      'anywhere in it. This is the one-time step that makes gMSAs available to the organisation.</p>' +
      '<div class="tool-danger">' +
        '<p><strong>Read before doing this.</strong> It writes to the forest configuration ' +
        'partition. It affects every domain in the forest, it needs Enterprise or Domain Admin in ' +
        'the forest root, and it is normally done once in the lifetime of the forest.</p>' +
        '<p>After it succeeds, <strong>nothing works for ' + esc(String(d.waitHours)) + ' hours</strong> ' +
        'while domain controllers converge. That wait is expected and cannot be skipped safely.</p>' +
      '</div>' +
      // Two independent confirmations. Deliberately worded as two different
      // statements rather than "are you sure" twice, so ticking both is an
      // actual second thought and not a reflex.
      '<label class="tool-check"><input type="checkbox" id="kdsAck1"> ' +
        'I understand this changes the <strong>forest</strong>, not just this domain, and that ' +
        'gMSAs will not work for ' + esc(String(d.waitHours)) + ' hours afterwards.</label>' +
      '<label class="tool-check"><input type="checkbox" id="kdsAck2"> ' +
        'I am authorised to make a forest-level change, and I have checked that no KDS root key ' +
        'already exists.</label>' +
      '<div class="field"><label for="kdsReason">Reason for the audit log (required)</label>' +
      '<input class="input" id="kdsReason" placeholder="Ticket ID or justification" autocomplete="off"></div>' +
      '<label class="tool-check"><input type="checkbox" id="kdsBackdate"> ' +
        '<strong>Lab only:</strong> backdate the effective time so the key works immediately. ' +
        'Never do this on a production forest - it lets a controller be asked for a key it has ' +
        'not replicated yet.</label>' +
      '<div class="set-actions">' +
        '<button class="btn btn-primary" type="button" id="kdsCreate"' +
        (d.kdsLocal ? '' : ' disabled') + '>Create the KDS root key</button>' +
      '</div>' +
      (d.kdsLocal
        ? '<p class="dialog-note"><strong>Note on attribution:</strong> this one action runs as the ' +
          'account the DSMT server runs as, not as you. <code>Add-KdsRootKey</code> accepts no ' +
          'credential and no target server - that is a limitation of the cmdlet, not a choice here. ' +
          'The audit record names you as the initiator and says so explicitly.</p>'
        : '<p class="set-warn">The <code>Kds</code> module is not present on the DSMT host, so this ' +
          'cannot run from here. Run the command below on a domain controller.</p>') +
      '<label class="set-cmd-label">On a domain controller, in an elevated PowerShell:</label>' +
      '<div class="secret" id="kdsCmd">Add-KdsRootKey -EffectiveImmediately</div>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="copyKdsCmd">Copy command</button>' +
      '</div>' +
      '<div class="set-result" id="kdsResult"></div>';
  }

  // ---- step 2: the group ----------------------------------------------
  var groupStatus = d.groupExists ? 'ok' : 'todo';
  var groupBody =
    '<p class="dialog-note">The computers allowed to retrieve the gMSA password are named by a ' +
    '<strong>group</strong>, not listed on the account. A list has to be rewritten every time a ' +
    'host is added or replaced; a group does not. Put the DSMT host in it - and every host that ' +
    'will ever run DSMT.</p>' +
    '<div class="set-form">' +
      '<div class="field"><label for="gmsaGroup">Group name</label>' +
      '<input class="input" id="gmsaGroup" placeholder="DSMT-gMSA-Hosts" autocomplete="off" value="' +
      esc(group) + '"></div>' +
      '<div class="field"><label for="gmsaGroupOu">Create it in</label>' +
      '<select class="input" id="gmsaGroupOu"></select></div>' +
    '</div>' +
    (d.groupExists
      ? '<p class="set-good">Found: <strong>' + esc(group) + '</strong> at ' + esc(d.groupDn) + '</p>'
      : '<p class="muted-sm">No group by that name yet.</p>') +
    '<div class="field"><label for="gmsaGroupReason">Reason for the audit log (required to create)</label>' +
    '<input class="input" id="gmsaGroupReason" placeholder="Ticket ID or justification" autocomplete="off"></div>' +
    '<div class="set-actions">' +
      '<button class="btn btn-secondary" type="button" id="gmsaCheckGroup">Check</button>' +
      '<button class="btn btn-primary" type="button" id="gmsaCreateGroup"' +
      (d.groupExists ? ' disabled' : '') + '>Create the group</button>' +
    '</div>' +
    '<div class="set-result" id="gmsaGroupResult"></div>';

  // ---- step 3: the computers ------------------------------------------
  var members = asArray(d.members);
  var memberStatus = 'todo';
  if (d.groupExists && members.length > 0) { memberStatus = 'ok'; }
  else if (d.groupExists) { memberStatus = 'warn'; }

  var memberRows = members.length
    ? '<table class="table dsmt-table tool-table"><thead><tr>' +
        '<th>Computer</th><th>DNS name</th><th>Enabled</th><th></th></tr></thead><tbody>' +
        members.map(function (m) {
          return '<tr>' +
            '<td data-label="Computer" class="cell-name">' + esc(m.name) + '</td>' +
            '<td data-label="DNS name" class="cell-muted">' + esc(m.dns || '-') + '</td>' +
            '<td data-label="Enabled" class="' + (m.enabled ? 'res-success' : 'res-other') + '">' +
              (m.enabled ? 'Yes' : 'No') + '</td>' +
            '<td data-label=""><button class="btn btn-ghost btn-undo" type="button" data-drop="' +
              esc(m.sam) + '">Remove</button></td>' +
          '</tr>';
        }).join('') +
      '</tbody></table>'
    : '<p class="' + (d.groupExists ? 'set-warn' : 'muted-sm') + '">' +
      (d.groupExists
        ? 'The group is empty. A gMSA whose group has no computers installs on nothing - this is ' +
          'the most common reason a correct-looking account refuses to work.'
        : 'Create the group first.') + '</p>';

  var memberBody =
    '<p class="dialog-note">Add the machine account of every host that may use this gMSA. ' +
    'Type the computer name, the name with a trailing <code>$</code>, or the full DNS name - all ' +
    'three are accepted. <strong>Every name is resolved against AD before anything is changed</strong>, ' +
    'so a typo cannot silently add nothing.</p>' +
    memberRows +
    '<div class="field"><label for="gmsaComputers">Computers to add (one per line, or comma separated)</label>' +
    '<textarea class="input" id="gmsaComputers" rows="3" placeholder="DSMT01&#10;DSMT02.lab.local"></textarea></div>' +
    '<div class="field"><label for="gmsaMemberReason">Reason for the audit log (required)</label>' +
    '<input class="input" id="gmsaMemberReason" placeholder="Ticket ID or justification" autocomplete="off"></div>' +
    '<div class="set-actions">' +
      '<button class="btn btn-primary" type="button" id="gmsaAddComputers"' +
      (d.groupExists ? '' : ' disabled') + '>Add to the group</button>' +
    '</div>' +
    '<p class="dialog-note">A computer added to a group does not see that membership until it ' +
    '<strong>reboots</strong> - group membership is read into the machine\'s Kerberos ticket at ' +
    'startup. If step 4 fails on a host you just added, reboot it before investigating anything else.</p>' +
    '<div class="set-result" id="gmsaMemberResult"></div>';

  // ---- step 4: the account --------------------------------------------
  var acctStatus = d.gmsaExists ? 'ok' : 'todo';
  var accounts = asArray(d.accounts);

  var acctBody =
    '<p class="dialog-note">The account itself. The permitted-computers group is set <strong>when it ' +
    'is created</strong>, not afterwards: an account created without it looks perfectly healthy in ' +
    'AD and then fails to install on every host, with an error naming none of this.</p>' +
    '<div class="set-form">' +
      '<div class="field"><label for="gmsaName">Account name (no trailing $)</label>' +
      '<input class="input" id="gmsaName" placeholder="gmsa-dsmt" autocomplete="off" value="' + esc(name) + '"></div>' +
      '<div class="field"><label for="gmsaDns">DNS host name</label>' +
      '<input class="input" id="gmsaDns" placeholder="gmsa-dsmt.' + esc(d.domain || 'lab.local') +
      '" autocomplete="off"></div>' +
    '</div>' +
    (d.gmsaExists
      ? '<p class="set-good">Found: <strong>' + esc(name) + '$</strong>' +
        (d.gmsaPrincipals && d.gmsaPrincipals.length
          ? ' - retrievable by ' + esc(asArray(d.gmsaPrincipals).join(', '))
          : ' - <strong>but no principals may retrieve its password.</strong> It will not install anywhere.') +
        '</p>'
      : '') +
    (accounts.length
      ? '<p class="muted-sm">gMSAs already in this domain: ' +
        esc(accounts.map(function (a) { return a.name; }).join(', ')) + '</p>'
      : '<p class="muted-sm">There are no gMSAs in this domain yet.</p>') +
    '<div class="field"><label for="gmsaAcctReason">Reason for the audit log (required)</label>' +
    '<input class="input" id="gmsaAcctReason" placeholder="Ticket ID or justification" autocomplete="off"></div>' +
    '<div class="set-actions">' +
      '<button class="btn btn-primary" type="button" id="gmsaCreateAcct"' +
      ((d.groupExists && !d.gmsaExists) ? '' : ' disabled') + '>Create the gMSA</button>' +
    '</div>' +
    '<div class="set-result" id="gmsaAcctResult"></div>';

  // ---- step 5: install, by hand ----------------------------------------
  var acctForCmd = name || 'gmsa-dsmt';
  var installBody =
    '<p class="dialog-note">This one <strong>cannot</strong> run from the console. It writes to the ' +
    'local machine\'s secret store and needs local administrator on the DSMT host - which this ' +
    'process deliberately does not have. Run it there, in an elevated PowerShell.</p>' +
    '<label class="set-cmd-label">On the DSMT host:</label>' +
    '<div class="secret" id="gmsaInstallCmd">Install-ADServiceAccount -Identity ' + esc(acctForCmd) + '\n' +
    'Test-ADServiceAccount -Identity ' + esc(acctForCmd) + '</div>' +
    '<div class="set-actions">' +
      '<button class="btn btn-secondary" type="button" id="copyInstallCmd">Copy commands</button>' +
    '</div>' +
    '<p class="dialog-note"><code>Test-ADServiceAccount</code> returning <strong>True</strong> is the ' +
    'only proof that any of this worked. If it returns False, the usual cause is that the host has ' +
    'not rebooted since it was added to the group.</p>' +
    '<p class="dialog-note">Then point DSMT at it: <strong>Settings -> Service account</strong>, ' +
    'which builds the command that moves the service, the URL reservation, the data-folder ' +
    'permissions and the SQL login together.</p>';

  $('toolsBody').innerHTML =
    intro +
    gmsaStep(1, 'KDS root key (once per forest)', kdsStatus, kdsBody) +
    gmsaStep(2, 'Group of permitted computers', groupStatus, groupBody) +
    gmsaStep(3, 'Computers in that group', memberStatus, memberBody) +
    gmsaStep(4, 'The gMSA itself', acctStatus, acctBody) +
    gmsaStep(5, 'Install it on the host', 'manual', installBody);

  wireGmsa();
}

function wireGmsa() {
  var d = state.gmsa;

  function reload() { renderGmsaTool(); }

  // ---- step 1 ----
  if ($('kdsCreate')) {
    $('kdsCreate').addEventListener('click', function () {
      var ack1 = $('kdsAck1').checked;
      var ack2 = $('kdsAck2').checked;
      var reason = $('kdsReason').value.trim();

      if (!ack1 || !ack2) {
        setResult('kdsResult', 'Both confirmations are required. This is a forest-level change.', false);
        return;
      }
      if (!reason) { setResult('kdsResult', 'Give a reason for the audit log.', false); return; }

      setResult('kdsResult', 'Creating the KDS root key...', true);
      api('/api/tools/gmsa/kds', {
        method: 'POST',
        body: {
          reason: reason,
          backdate: $('kdsBackdate').checked,
          confirmUnderstood: ack1,
          confirmAuthorised: ack2
        }
      }).then(function (res) {
        toast('KDS root key created.', 'good');
        setResult('kdsResult', res.message + ' (executed as ' + res.ranAs + ')', true);
        window.setTimeout(reload, 1200);
      }).catch(function (err) {
        setResult('kdsResult', explainApiError(err.message), false);
      });
    });
  }

  if ($('copyKdsCmd')) {
    $('copyKdsCmd').addEventListener('click', function () {
      copyText($('kdsCmd').textContent, 'kdsResult');
    });
  }

  // ---- step 2 ----
  if ($('gmsaGroupOu')) {
    var ouSel = $('gmsaGroupOu');
    var ous = asArray(state.ous);
    if (!ous.length) {
      ouSel.innerHTML = '<option value="' + esc(d.defaultOu || '') + '">' +
                        esc(d.defaultOu || 'Default Computers container') + '</option>';
    } else {
      ouSel.innerHTML = ous.map(function (o) {
        return '<option value="' + esc(o.dn) + '">' + esc(o.path) + '</option>';
      }).join('');
    }
  }

  if ($('gmsaCheckGroup')) {
    $('gmsaCheckGroup').addEventListener('click', function () {
      writeSetting('dsmt.tools.gmsa.group', $('gmsaGroup').value.trim());
      reload();
    });
  }

  if ($('gmsaCreateGroup')) {
    $('gmsaCreateGroup').addEventListener('click', function () {
      var name = $('gmsaGroup').value.trim();
      var reason = $('gmsaGroupReason').value.trim();
      if (!name) { setResult('gmsaGroupResult', 'Name the group.', false); return; }
      if (!reason) { setResult('gmsaGroupResult', 'Give a reason for the audit log.', false); return; }

      setResult('gmsaGroupResult', 'Creating ' + name + '...', true);
      api('/api/tools/gmsa/group', {
        method: 'POST',
        body: { name: name, ou: $('gmsaGroupOu').value, reason: reason }
      }).then(function (res) {
        writeSetting('dsmt.tools.gmsa.group', name);
        if (res.ok) { toast('Group created.', 'good'); reload(); }
        else { setResult('gmsaGroupResult', gmsaFirstError(res), false); }
      }).catch(function (err) {
        setResult('gmsaGroupResult', explainApiError(err.message), false);
      });
    });
  }

  // ---- step 3 ----
  if ($('gmsaAddComputers')) {
    $('gmsaAddComputers').addEventListener('click', function () {
      var raw = $('gmsaComputers').value;
      var list = raw.split(/[\n,;]+/).map(function (s) { return s.trim(); })
                    .filter(function (s) { return s.length > 0; });
      var reason = $('gmsaMemberReason').value.trim();

      if (!list.length) { setResult('gmsaMemberResult', 'Name at least one computer.', false); return; }
      if (!reason) { setResult('gmsaMemberResult', 'Give a reason for the audit log.', false); return; }

      setResult('gmsaMemberResult', 'Resolving ' + list.length + ' computer(s)...', true);
      api('/api/tools/gmsa/members', {
        method: 'POST',
        body: { group: d.groupName, mode: 'add', computers: list, reason: reason }
      }).then(function (res) {
        if (res.ok) { toast('Added to the group.', 'good'); reload(); }
        else { setResult('gmsaMemberResult', gmsaFirstError(res), false); }
      }).catch(function (err) {
        setResult('gmsaMemberResult', explainApiError(err.message), false);
      });
    });
  }

  var drops = $('toolsBody').querySelectorAll('[data-drop]');
  for (var i = 0; i < drops.length; i++) {
    drops[i].onclick = function () {
      var who = this.getAttribute('data-drop');
      var reason = $('gmsaMemberReason').value.trim();
      if (!reason) {
        setResult('gmsaMemberResult', 'Give a reason first - removing a computer is an audited change.', false);
        return;
      }
      api('/api/tools/gmsa/members', {
        method: 'POST',
        body: { group: d.groupName, mode: 'remove', computers: [who], reason: reason }
      }).then(function () {
        toast('Removed from the group.', 'good');
        reload();
      }).catch(function (err) {
        setResult('gmsaMemberResult', explainApiError(err.message), false);
      });
    };
  }

  // ---- step 4 ----
  if ($('gmsaCreateAcct')) {
    $('gmsaCreateAcct').addEventListener('click', function () {
      var name = $('gmsaName').value.trim();
      var reason = $('gmsaAcctReason').value.trim();
      if (!name) { setResult('gmsaAcctResult', 'Name the account.', false); return; }
      if (!reason) { setResult('gmsaAcctResult', 'Give a reason for the audit log.', false); return; }

      setResult('gmsaAcctResult', 'Creating ' + name + '$...', true);
      api('/api/tools/gmsa/account', {
        method: 'POST',
        body: { name: name, dns: $('gmsaDns').value.trim(), group: d.groupName, reason: reason }
      }).then(function (res) {
        writeSetting('dsmt.tools.gmsa.name', name);
        if (res.ok) { toast('gMSA created.', 'good'); reload(); }
        else { setResult('gmsaAcctResult', gmsaFirstError(res), false); }
      }).catch(function (err) {
        setResult('gmsaAcctResult', explainApiError(err.message), false);
      });
    });
  }

  // ---- step 5 ----
  if ($('copyInstallCmd')) {
    $('copyInstallCmd').addEventListener('click', function () {
      copyText($('gmsaInstallCmd').textContent, '');
    });
  }
}

/* ---------------------------------------------------------------------------
   The profile window.

   The detail pane on the right stays exactly as it was - this is a second way
   in, not a replacement. The pane is for glancing while working down a list;
   this is for stopping and looking at one object properly, and it has the
   room for everything the pane has to abbreviate.

   It reads the SAME endpoint the pane reads, so there is one fetch and one
   shape of data. Adding a section here never means adding a second API.
   --------------------------------------------------------------------------- */

function openProfile(id) {
  var row = state.rows.filter(function (r) { return r.id === id; })[0];
  if (!row) { return; }

  var isGroup = (state.tab === 'groups');
  var path = (isGroup ? '/api/groups/' : '/api/users/') + encodeURIComponent(row.sam || row.dn);

  openDialog({
    title: row.name || row.sam,
    confirmLabel: '',
    hideConfirm: true,
    cancelLabel: 'Close',
    body: '<p class="muted-sm">Reading from the directory...</p>',
    onOpen: function () {
      // Widened only while a profile is open, so every other dialog keeps the
      // measure it was designed at.
      var box = el('.dialog');
      if (box) { box.className = 'dialog dialog-wide elev-lg'; }

      api(path).then(function (res) {
        // The endpoint wraps the object: { ok, item }. Reading `res` directly
        // gave a profile where every field was undefined, so every section
        // said "nothing recorded" and the Enable/Disable button could not
        // tell which state the account was in.
        var d = res.item;
        if (!d) {
          $('dialogBody').innerHTML = '<div class="error-box"><strong>The directory returned no object.</strong></div>';
          return;
        }
        $('dialogBody').innerHTML = profileHtml(d, isGroup);
        wireProfile(d, isGroup, id);
      }).catch(function (err) {
        $('dialogBody').innerHTML = '<div class="error-box"><strong>Could not read this object.</strong>' +
                                    esc(explainApiError(err.message)) + '</div>';
      });
    },
    onCancel: function () {
      var box = el('.dialog');
      if (box) { box.className = 'dialog elev-lg'; }
    }
  });
}

function profileRows(pairs) {
  var rows = pairs.filter(function (p) {
    return p[1] !== undefined && p[1] !== null && String(p[1]).length > 0;
  }).map(function (p) {
    return '<div class="detail-row"><dt>' + esc(p[0]) + '</dt><dd>' + esc(p[1]) + '</dd></div>';
  }).join('');

  // An empty section is worse than an absent one: it reads as "there is
  // nothing here" when the truth is "nothing was filled in".
  if (!rows) { return '<p class="muted-sm">Nothing recorded in the directory for these fields.</p>'; }
  return '<dl class="detail-fields">' + rows + '</dl>';
}

function profileHtml(d, isGroup) {
  var members = asArray(d.memberships);

  var tags =
    '<div class="profile-tags">' +
      (isGroup
        ? '<span class="tag tag-outline">' + esc(d.scope || '') + '</span>' +
          '<span class="tag tag-neutral">' + members.length + ' members</span>'
        : '<span class="tag tag-outline">' + esc(d.source || 'AD') + '</span>' +
          '<span class="tag tag-neutral">' + esc(d.status || '') + '</span>' +
          (d.privileged ? '<span class="tag-priv">Privileged</span>' : '')) +
    '</div>';

  var identity = isGroup
    ? [['Group name', d.name], ['samAccountName', d.sam], ['Type / scope', d.type],
       ['Description', d.description], ['Email', d.mail]]
    : [['Display name', d.name], ['samAccountName', d.sam], ['UPN', d.upn], ['Email', d.mail]];

  var org = isGroup
    ? [['Container', d.ou], ['Managed by', d.managedBy], ['Created', d.created], ['Notes', d.notes]]
    : [['Department', d.dept], ['Title', d.title], ['Manager', d.manager],
       ['Office', d.office], ['Phone', d.phone], ['Company', d.company]];

  var account = isGroup
    ? [['Distinguished name', d.dn]]
    : [['Status', d.status], ['OU / container', d.ou], ['Last logon', d.logon],
       ['Password expiry', d.pwd], ['Created', d.created], ['Employee ID', d.employeeId],
       ['Distinguished name', d.dn]];

  var memberTitle = isGroup ? 'Members' : 'Group memberships';
  var memberBody;
  if (!members.length) {
    memberBody = '<p class="muted-sm">' +
      (isGroup ? 'This group has no members.' : 'This account is in no groups.') + '</p>';
  } else {
    memberBody =
      '<ul class="member-list">' + members.map(function (m) {
        return '<li><span class="member-dot"></span>' +
               '<span class="member-name" title="' + esc(m.dn) + '">' + esc(m.name) + '</span>' +
               '<span class="member-meta">' + esc(m.meta) + '</span></li>';
      }).join('') + '</ul>';
  }

  // The window was one long scroll: identity, organisation, account, then
  // memberships below the fold. Tabs split it so more is visible with less
  // crowding.
  //
  // The tab strip is built ONCE, from a list, so the Attributes section
  // planned in PROGRESS item 28 slots in as another entry rather than as a
  // second navigation pattern bolted on beside this one.
  var panes = [
    { key: 'overview', label: 'Overview', body:
        '<div class="profile-grid">' +
          '<section class="profile-sec"><h4>Identity</h4>' + profileRows(identity) + '</section>' +
          '<section class="profile-sec"><h4>' + (isGroup ? 'Directory' : 'Organisation') + '</h4>' +
            profileRows(org) + '</section>' +
          '<section class="profile-sec profile-wide"><h4>Account</h4>' + profileRows(account) + '</section>' +
        '</div>' },
    { key: 'members', label: memberTitle + ' (' + members.length + ')', body:
        '<div class="profile-grid">' +
          '<section class="profile-sec profile-wide">' + memberBody + '</section>' +
        '</div>' }
  ];

  var strip = '<div class="profile-tabs" role="tablist">' +
    panes.map(function (p, i) {
      return '<button class="profile-tab' + (i === 0 ? ' is-on' : '') + '" type="button" ' +
             'role="tab" aria-selected="' + (i === 0 ? 'true' : 'false') + '" ' +
             'data-ptab="' + esc(p.key) + '">' + esc(p.label) + '</button>';
    }).join('') + '</div>';

  var bodies = panes.map(function (p, i) {
    return '<div class="profile-pane" data-ppane="' + esc(p.key) + '"' +
           (i === 0 ? '' : ' hidden') + '>' + p.body + '</div>';
  }).join('');

  return tags +
    // Actions above the content and OUTSIDE the tab strip. They apply to the
    // user, not to a tab - moving them inside one would hide half of them
    // depending on which tab happened to be open. With six group memberships
    // they were already past the fold, so the most-used controls moved
    // further away the more there was to read - exactly backwards.
    '<div class="set-actions profile-actions" id="profileActions"></div>' +
    strip + bodies;
}

function wireProfileTabs() {
  var strip = el('.profile-tabs');
  if (!strip) { return; }

  strip.addEventListener('click', function (e) {
    var btn = e.target.closest('.profile-tab');
    if (!btn) { return; }

    var key = btn.getAttribute('data-ptab');
    var tabs = strip.querySelectorAll('.profile-tab');
    var i;
    for (i = 0; i < tabs.length; i++) {
      var on = (tabs[i] === btn);
      tabs[i].className = 'profile-tab' + (on ? ' is-on' : '');
      tabs[i].setAttribute('aria-selected', on ? 'true' : 'false');
    }

    var panes = document.querySelectorAll('[data-ppane]');
    for (i = 0; i < panes.length; i++) {
      panes[i].hidden = (panes[i].getAttribute('data-ppane') !== key);
    }
  });
}

function wireProfile(d, isGroup, rowId) {
  wireProfileTabs();

  // The same actions the detail pane offers, so there is one set of verbs in
  // the console and they behave identically wherever they are pressed.
  var actions = isGroup
    ? [['add-members', 'Add members'], ['move-ou', 'Move OU']]
    : [['reset-password', 'Reset password'], ['unlock', 'Unlock'],
       [d.enabled ? 'disable' : 'enable', d.enabled ? 'Disable' : 'Enable'],
       ['move-ou', 'Move OU'], ['group-add', 'Add to group']];

  $('profileActions').innerHTML = actions.map(function (a) {
    return '<button class="btn btn-secondary" type="button" data-paction="' + a[0] + '">' +
           esc(a[1]) + '</button>';
  }).join('');

  var buttons = $('profileActions').querySelectorAll('[data-paction]');
  for (var i = 0; i < buttons.length; i++) {
    buttons[i].onclick = function () {
      var verb = this.getAttribute('data-paction');
      // Select the row first so the existing action handlers act on it, then
      // close - the actions open their own dialogs and two stacked dialogs
      // would fight over the backdrop.
      // The grid row's own id, not the one in the detail payload: the actions
      // operate on the list, and an id that does not match anything there
      // fails with "select at least one row first" - which is true and
      // useless.
      var row = state.rows.filter(function (r) { return r.id === rowId; });
      selectRow(rowId, true);
      closeDialog();
      var box = el('.dialog');
      if (box) { box.className = 'dialog elev-lg'; }
      dispatchAction(verb, row);
    };
  }
}

/* ---------------------------------------------------------------------------
   AD health.

   Never auto-runs. Every other screen in this console loads its data on open;
   this one does not, because it makes several remote calls per domain
   controller and a slow tab that nobody asked for is how a diagnostic tool
   becomes the thing people blame.
   --------------------------------------------------------------------------- */

function renderAdHealthTool() {
  $('toolsBody').innerHTML =
    '<section class="set-card">' +
      '<h2 class="set-h">Active Directory health</h2>' +
      '<p class="dialog-note">Different question from <strong>Settings -> Health</strong>, which asks ' +
      'whether DSMT can reach the directory. This asks whether the directory itself is well: ' +
      'replication, the FSMO roles, per-controller reachability and clock drift.</p>' +
      '<p class="dialog-note">It makes several remote calls to every domain controller, so it runs only ' +
      'when you ask. Nothing here changes anything - it is safe to repeat.</p>' +
      '<div class="set-actions">' +
        '<button class="btn btn-primary" type="button" id="runAdHealth">Run the checks</button>' +
        '<span class="audit-stamp" id="adhStamp"></span>' +
      '</div>' +
      '<div class="set-result" id="adhResult"></div>' +
    '</section>' +
    '<div id="adhBody"></div>';

  $('runAdHealth').addEventListener('click', loadAdHealth);

  // Repainted from the last run if there is one, so switching away and back
  // does not silently throw away a report that took thirty seconds.
  if (state.adHealth) { paintAdHealth(state.adHealth); }
}

function loadAdHealth() {
  var btn = $('runAdHealth');
  btn.disabled = true;
  btn.textContent = 'Checking...';
  setResult('adhResult', 'Querying every domain controller. This can take a while on a large domain.', true);
  $('adhBody').innerHTML = '';

  api('/api/tools/adhealth').then(function (data) {
    state.adHealth = data;
    setResult('adhResult', '', true);
    paintAdHealth(data);
  }).catch(function (err) {
    $('adhBody').innerHTML = '<div class="error-box"><strong>The checks could not run.</strong>' +
      esc(explainApiError(err.message)) + '</div>';
  }).then(function () {
    btn.disabled = false;
    btn.textContent = 'Run the checks again';
  });
}

/* Only real rows. A section that serialised oddly used to render one row of
   blanks, which reads as data. An empty section must look empty. */
function adhRows(value, key) {
  return asArray(value).filter(function (r) {
    return r && typeof r === 'object' && !(r instanceof Array) &&
           r[key] !== undefined && r[key] !== null && String(r[key]).length > 0;
  });
}

function adhWord(status) {
  if (status === 'ok') { return 'OK'; }
  if (status === 'warn') { return 'Attention'; }
  return 'Failing';
}

function adhCard(title, note, bodyHtml) {
  return '<section class="set-card">' +
           '<h2 class="set-h">' + esc(title) + '</h2>' +
           (note ? '<p class="dialog-note">' + note + '</p>' : '') +
           bodyHtml +
         '</section>';
}

function paintAdHealth(d) {
  var stamp = $('adhStamp');
  if (stamp) { stamp.textContent = 'Checked ' + formatStamp(d.checkedAt); }

  var head =
    '<section class="set-card">' +
      '<div class="set-state set-state-' + esc(d.overall) + '">' +
        '<div class="set-state-head"><span class="set-state-dot"></span>' +
        '<span>' + esc(adhWord(d.overall)) + '</span></div>' +
        '<p class="muted-sm">' +
          (d.overall === 'ok'
            ? 'Replication, roles, reachability and clocks all look healthy.'
            : 'Something needs attention. The worst individual result decides this verdict - it is never an average.') +
        '</p>' +
      '</div>' +
      (d.error ? '<div class="error-box"><strong>Part of the report could not be produced.</strong>' +
                 esc(d.error) + '</div>' : '') +
    '</section>';

  // ---- replication, laid out the way replsum is read: worst first ----
  var repl = adhRows(d.replication, 'name');
  var replRows = repl.length
    ? '<div class="scroll-x"><table class="table dsmt-table tool-table"><thead><tr>' +
      '<th>Controller</th><th>Partners</th><th>Failures</th><th>Last success</th><th>Delta</th><th>Note</th>' +
      '</tr></thead><tbody>' +
      repl.map(function (r) {
        var delta = (r.largestGapMin === null || r.largestGapMin === undefined)
          ? '-' : adhDelta(r.largestGapMin);
        return '<tr>' +
          '<td data-label="Controller" class="cell-name">' + esc(r.name) + '</td>' +
          '<td data-label="Partners" class="cell-muted">' + esc(String(r.partners)) + '</td>' +
          '<td data-label="Failures" class="' + (r.worstFailures > 0 ? 'res-other' : 'res-success') + '">' +
            esc(String(r.worstFailures)) + '</td>' +
          '<td data-label="Last success" class="cell-muted">' + esc(r.lastSuccess || '-') + '</td>' +
          '<td data-label="Delta" class="cell-muted">' + esc(delta) + '</td>' +
          '<td data-label="Note" class="cell-wrap cell-muted">' + esc(r.note || '') + '</td>' +
        '</tr>';
      }).join('') + '</tbody></table></div>'
    : '<p class="muted-sm">No replication data was returned.</p>';

  var replCard = adhCard('Replication', 
    'One row per controller, worst first - the same view as <code>repadmin /replsum</code>, ' +
    'built from objects rather than parsed console output. <strong>Delta</strong> is the time since ' +
    'the most recent successful inbound replication.', replRows);

  // ---- FSMO ----
  var fsmo = adhRows(d.fsmo, 'role');
  var fsmoRows = fsmo.length
    ? '<div class="health-list">' + fsmo.map(function (r) {
        return '<div class="health-item health-' + esc(r.status) + '">' +
                 '<div class="health-item-head"><span class="set-state-dot"></span>' +
                 '<span class="health-name">' + esc(r.role) + '</span>' +
                 '<span class="health-verdict">' + esc(r.scope) + '</span></div>' +
                 '<p class="health-detail">' + esc(r.holder || 'unknown') + '</p>' +
                 (r.note ? '<p class="health-fix">' + esc(r.note) + '</p>' : '') +
               '</div>';
      }).join('') + '</div>'
    : '<p class="muted-sm">The role holders could not be read.</p>';

  var fsmoCard = adhCard('FSMO roles',
    'Where each role sits, <strong>and whether that holder answers</strong>. A role pointing at a ' +
    'controller that was decommissioned without transferring it looks correct in every list, and is ' +
    'the actual fault.', fsmoRows);

  // ---- controllers ----
  var dcs = adhRows(d.controllers, 'name');
  var dcRows = dcs.length
    ? '<div class="scroll-x"><table class="table dsmt-table tool-table"><thead><tr>' +
      '<th>Controller</th><th>Site</th><th>LDAP</th><th>LDAPS</th><th>GC</th><th>Clock</th><th>Note</th>' +
      '</tr></thead><tbody>' +
      dcs.map(function (r) {
        var skew = (r.skew === null || r.skew === undefined) ? '-' : (r.skew + ' min');
        return '<tr>' +
          '<td data-label="Controller" class="cell-name">' + esc(r.name) + '</td>' +
          '<td data-label="Site" class="cell-muted">' + esc(r.site || '-') + '</td>' +
          '<td data-label="LDAP" class="' + (r.ldap ? 'res-success' : 'res-other') + '">' + (r.ldap ? 'open' : 'closed') + '</td>' +
          '<td data-label="LDAPS" class="cell-muted">' + (r.ldaps ? 'open' : 'closed') + '</td>' +
          '<td data-label="GC" class="' + (!r.isGc ? 'cell-muted' : (r.gc ? 'res-success' : 'res-other')) + '">' +
            (!r.isGc ? 'n/a' : (r.gc ? 'open' : 'closed')) + '</td>' +
          '<td data-label="Clock" class="cell-muted">' + esc(skew) + '</td>' +
          '<td data-label="Note" class="cell-wrap cell-muted">' + esc(r.note || '') + '</td>' +
        '</tr>';
      }).join('') + '</tbody></table></div>'
    : '<p class="muted-sm">No controllers were returned.</p>';

  var dcCard = adhCard('Domain controllers',
    'LDAP 389, LDAPS 636 and Global Catalog 3268, plus clock drift against this host. ' +
    '<strong>A closed 636 is information, not a fault</strong> - plenty of healthy domains do not ' +
    'publish LDAPS. Kerberos rejects a skew past ' + esc(String(d.skewBad)) + ' minutes, and the ' +
    'symptom never mentions time.', dcRows);

  // ---- explicit failures, only when there are any ----
  var fails = adhRows(d.failures, 'server');
  var failCard = '';
  if (fails.length) {
    failCard = adhCard('Replication failures',
      'Recorded by Active Directory itself. These are not inferred.',
      '<div class="scroll-x"><table class="table dsmt-table tool-table"><thead><tr>' +
      '<th>Controller</th><th>Partner</th><th>Count</th><th>Since</th><th>Reason</th>' +
      '</tr></thead><tbody>' +
      fails.map(function (f) {
        return '<tr>' +
          '<td data-label="Controller" class="cell-name">' + esc(f.server) + '</td>' +
          '<td data-label="Partner" class="cell-muted cell-wrap">' + esc(f.partner) + '</td>' +
          '<td data-label="Count" class="res-other">' + esc(String(f.count)) + '</td>' +
          '<td data-label="Since" class="cell-muted">' + esc(f.firstAt || '') + '</td>' +
          '<td data-label="Reason" class="cell-wrap cell-muted">' + esc(f.reason || '') + '</td>' +
        '</tr>';
      }).join('') + '</tbody></table></div>');
  }

  $('adhBody').innerHTML = head + replCard + fsmoCard + dcCard + failCard;
}

/* Minutes into something a person reads without converting. */
function adhDelta(mins) {
  if (mins < 60) { return mins + ' min'; }
  if (mins < 1440) { return Math.round(mins / 60) + ' h'; }
  return Math.round(mins / 1440) + ' d';
}

/* A bulk-action response reports per target; with one target the useful
   message is that target's error, not "it failed". */
function gmsaFirstError(res) {
  var rows = asArray(res.results);
  for (var i = 0; i < rows.length; i++) {
    if (!rows[i].ok && rows[i].error) { return rows[i].error; }
  }
  return 'The directory refused the change.';
}

function copyText(text, resultId) {
  var done = function () {
    if (resultId) { setResult(resultId, 'Copied to the clipboard.', true); }
    else { toast('Copied to the clipboard.', 'good'); }
  };

  // navigator.clipboard needs a secure context, which http://host:8080 is not.
  // The textarea fallback is not legacy cruft here - it is the path that
  // actually runs on most DSMT installations.
  if (window.navigator && window.navigator.clipboard && window.navigator.clipboard.writeText) {
    window.navigator.clipboard.writeText(text).then(done, function () { legacyCopy(text, done); });
    return;
  }
  legacyCopy(text, done);
}

function legacyCopy(text, done) {
  var ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.top = '-1000px';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); done(); } catch (e) { toast('Could not copy.', 'bad'); }
  document.body.removeChild(ta);
}

// ---------------------------------------------------------------------------
// Settings - a full view, not a dialog
//
// It renders inline and reports inline. Nothing here depends on an overlay
// being able to display, because the one thing an operator needs when the
// console is misbehaving is the settings screen.
// ---------------------------------------------------------------------------

function actionSettings() { setTab('settings'); }

function settingsRow(label, value) {
  if (!value) { return ''; }
  return '<div class="detail-row"><dt>' + esc(label) + '</dt><dd>' + esc(value) + '</dd></div>';
}

function loadSettings() {
  // The rail belongs to the rendered sections; drop it while there are none,
  // otherwise a failed reload leaves a rail pointing at cards that are gone.
  $('settingsNav').innerHTML = '';
  state.healthLoaded = false;
  $('settingsBody').innerHTML = '<p class="muted-sm">Loading...</p>';

  api('/api/settings').then(function (data) {
    state.settings = data.settings;
    // The editor edits what the server has, not a stale copy from whenever
    // the Groups tab last loaded.
    api('/api/groups?limit=1').then(function (g) {
      state.groupFilters = asArray(g.filters);
      state.gfDraft = null;
      renderSettings();
    }).catch(function () { renderSettings(); });
  }).catch(function (err) {
    $('settingsBody').innerHTML = '<div class="error-box"><strong>Could not read the settings.</strong>' +
                                  esc(err.message) + '</div>';
  });
}

function renderSettings() {
  var s = state.settings;
  if (!s) { return; }

  var b = s.sessionBounds || {};
  var bounds = { min: b.Min || b.min || 1, max: b.Max || b.max || 480, def: b.Default || b.def || 15 };

  // PowerShell hashtables serialise with their own capitalisation, so each of
  // these reads both spellings rather than betting on one. The fallbacks are
  // last resorts for an older server, not the values in use.
  var pb = s.pageSizeBounds || {};
  var pbounds = { min: pb.Min || pb.min || 25, max: pb.Max || pb.max || 5000, def: pb.Default || pb.def || 500 };

  var ab = s.alertBounds || {};
  var abounds = { min: ab.Min || ab.min || 5, max: ab.Max || ab.max || 1440, def: ab.Default || ab.def || 60 };

  var al = s.alerts || {};
  var alerts = {
    enabled: (al.Enabled === undefined ? (al.enabled === undefined ? true : al.enabled) : al.Enabled),
    intervalMinutes: al.IntervalMinutes || al.intervalMinutes || abounds.def
  };

  // Where the data actually goes, stated as fields rather than buried in a
  // sentence: on a screen with two name-shaped inputs, the one thing that must
  // be unambiguous is which server and database are LIVE right now, as opposed
  // to whatever is currently typed into the boxes below.
  var storage =
    '<div class="set-state' + (s.sqlEnabled ? ' set-state-on' : ' set-state-off') + '">' +
      '<div class="set-state-head">' +
        '<span class="set-state-dot"></span>' +
        '<span>' + (s.sqlEnabled ? 'Connected' : 'Not connected') + '</span>' +
      '</div>' +
      '<dl class="detail-fields">' +
        settingsRow('SQL Server instance', s.sqlEnabled ? s.sqlServer : 'None') +
        settingsRow('Database', s.sqlEnabled ? s.sqlDatabase : 'None') +
        settingsRow('Audit log', s.sqlEnabled ? 'SQL Server, and files under the data folder'
                                              : 'Files under the data folder only') +
        settingsRow('Operators, sessions, snapshot', s.sqlEnabled ? 'Stored in SQL Server'
                                                                  : 'Not stored') +
      '</dl>' +
    '</div>';

  if (!s.sqlEnabled) {
    storage += '<p class="set-warn">No database is configured, so operators, sessions and the ' +
               'directory snapshot are <strong>not stored at all</strong> and the audit log ' +
               'survives only as files on the server.</p>';
  }

  if (s.sqlError) {
    storage += '<div class="error-box"><strong>The last SQL attempt failed with:</strong>' +
               esc(s.sqlError) + '</div>';
  }

  // Sections are data, not one wall of markup: the rail and the cards both
  // read from this one list.
  var sections = [];

  // Health first: it is the section someone opens when something is wrong,
  // and the one that answers "is it me or is it the server".
  sections.push({ key: 'health', label: 'Health', hint: 'Is everything reachable', body:
      '<h2 class="set-h">Health</h2>' +
      '<p class="dialog-note">Every check below is run live, now. Nothing here changes anything, ' +
      'so it is safe to press repeatedly while diagnosing.</p>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="runHealth">Run checks</button>' +
        '<span class="audit-stamp" id="healthStamp"></span>' +
      '</div>' +
      '<div id="healthBody"></div>' });

  sections.push({ key: 'system', label: 'System', hint: 'Version, domain, paths', body:
      '<h2 class="set-h">System</h2>' +
      '<dl class="detail-fields">' +
        settingsRow('Version', s.version) +
        settingsRow('Published by', s.publisher) +
        settingsRow('Domain', s.domain) +
        settingsRow('Domain controller', s.server || 'Auto-discovered') +
        settingsRow('Listening on', s.listenAddress + ':' + s.port) +
        settingsRow('Search result cap', String(s.pageSize)) +
      '</dl>' +
      '<p class="set-sub">Where things are</p>' +
      '<dl class="detail-fields">' +
        settingsRow('Program files', s.installPath || '') +
        settingsRow('Settings', s.settingsKey || '') +
        settingsRow('Audit / log folder', s.dataPath) +
        settingsRow('Path pointers', s.registryKey || '') +
      '</dl>' +
      '<p class="dialog-note">Every setting on these screens is stored in the registry key above, ' +
      'machine-wide. It can be read or edited directly with <code>regedit</code>, which needs local ' +
      'administrator rights - the same rights as the host itself.</p>' +
      '<div class="set-actions">' +
        '<button class="btn btn-ghost" type="button" id="exportSettings">Show all settings as JSON</button>' +
      '</div>' +
      '<div class="set-result" id="exportResult"></div>' +
      (s.pathMode === 'portable'
        ? '<p class="dialog-note"><strong>Portable layout.</strong> Settings and data live inside the ' +
          'program folder, so replacing that folder to upgrade takes them with it - which is how an ' +
          'upgrade ends up with no database configured and no error to explain it. Run ' +
          '<code>Install-DSMT.ps1</code> on the host to move the code to Program Files and the state to ' +
          'ProgramData, where an upgrade cannot reach it. Existing settings are copied across, not moved.</p>'
        : '<p class="dialog-note">The code and the state are in separate folders, so replacing the ' +
          'program folder to upgrade cannot lose the settings. The registry key holds pointers to both ' +
          'and nothing else - every setting itself is in the settings file above.</p>') });

  sections.push({ key: 'search', label: 'Search', hint: 'Result cap', body:
      '<h2 class="set-h">Search result cap</h2>' +
      '<p class="dialog-note">The most objects a Users or Groups search will return. Every row is a ' +
      'live directory read and a row of markup, so this is a limit on the browser as much as on ' +
      'Active Directory - raising it makes large searches slower, not more complete. When a search ' +
      'hits the cap the console says so, rather than quietly showing a partial list.</p>' +
      '<div class="set-form">' +
        '<div class="field"><label for="setPageSize">Maximum results (' + pbounds.min + '-' + pbounds.max + ')</label>' +
        '<input class="input" id="setPageSize" type="number" min="' + pbounds.min + '" max="' + pbounds.max +
        '" step="1" value="' + esc(String(s.pageSize || pbounds.def)) + '"></div>' +
        '<div class="field"><label for="setPagePreset">Common values</label>' +
        '<select class="input" id="setPagePreset">' +
          '<option value="">Choose</option>' +
          '<option value="250">250</option>' +
          '<option value="500">500 (default)</option>' +
          '<option value="1000">1000</option>' +
          '<option value="2000">2000</option>' +
          '<option value="5000">5000 (maximum)</option>' +
        '</select></div>' +
      '</div>' +
      '<p class="dialog-note">Applies to the next search - no restart needed.</p>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="applyPageSize">Save result cap</button>' +
      '</div>' +
      '<div class="set-result" id="pageSizeResult"></div>' });

  sections.push({ key: 'alerts', label: 'AD health alerts', hint: 'Bell notifications', body:
      '<h2 class="set-h">AD health alerts</h2>' +
      '<p class="dialog-note">Runs the Tools &gt; AD health checks on a schedule and raises anything ' +
      'wrong on the bell at the top right - replication that is behind, a controller that stopped ' +
      'answering, a clock drifting towards the Kerberos limit, an FSMO role held by a machine that ' +
      'is gone.</p>' +
      '<p class="dialog-note"><strong>What this does and does not cover.</strong> The check runs when ' +
      'an open console asks for it and the last result is older than the interval below - so while ' +
      'somebody has DSMT open, the directory is checked on schedule. It does <strong>not</strong> run ' +
      'on an unattended server with nobody signed in, and it does not send mail. Real unattended ' +
      'monitoring needs a scheduled task with its own account, which DSMT deliberately does not set ' +
      'up for you.</p>' +
      '<div class="set-form">' +
        '<div class="field"><label for="setAlertsOn">Alerts</label>' +
        '<select class="input" id="setAlertsOn">' +
          '<option value="1"' + (alerts.enabled ? ' selected' : '') + '>On</option>' +
          '<option value="0"' + (alerts.enabled ? '' : ' selected') + '>Off</option>' +
        '</select></div>' +
        '<div class="field"><label for="setAlertMins">Check at most once every (minutes)</label>' +
        '<input class="input" id="setAlertMins" type="number" min="' + abounds.min + '" max="' + abounds.max +
        '" step="1" value="' + esc(String(alerts.intervalMinutes || abounds.def)) + '"></div>' +
      '</div>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="applyAlerts">Save alert settings</button>' +
        '<button class="btn btn-ghost" type="button" id="runAlertsNow">Check now</button>' +
      '</div>' +
      '<div class="set-result" id="alertsResult"></div>' });

  sections.push({ key: 'network', label: 'Network', hint: 'Listening port', body:
      '<h2 class="set-h">Network</h2>' +
      '<dl class="detail-fields">' +
        settingsRow('Listening on', s.listenAddress + ':' + s.port) +
      '</dl>' +
      '<div class="set-form">' +
        '<div class="field"><label for="setPort">Port (1-65535)</label>' +
        '<input class="input" id="setPort" type="number" min="1" max="65535" step="1" value="' +
        esc(String(s.port)) + '"></div>' +
      '</div>' +
      '<p class="dialog-note">A listener cannot move to another port while it is running, so the new ' +
      'port is saved and used on the next start. If DSMT listens on all interfaces you also need a URL ' +
      'reservation and a firewall rule for it - both commands are shown after you save.</p>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="applyPort">Save port</button>' +
      '</div>' +
      '<div class="set-result" id="portResult"></div>' +
      '<div id="portCommands"></div>' });

  // ---- Roles ----
  // Scope is DSMT's own settings and nothing else. The copy says so at the
  // top, because a role that looks like a directory permission and is not
  // would be relied on as one.
  var r = s.roles || {};
  var roleGroups = asArray(r.groups);

  var roleRows = '';
  for (var ri = 0; ri < roleGroups.length; ri++) {
    var rg = roleGroups[ri];
    roleRows +=
      '<div class="role-row" data-sid="' + esc(rg.sid) + '">' +
        '<div class="role-main">' +
          '<strong>' + esc(rg.name || rg.sid) + '</strong>' +
          (rg.present
            ? '<div class="role-note">' + esc(rg.ou || '') + '</div>'
            : '<div class="role-missing">Not found in the directory - this entry grants nobody anything.</div>') +
          '<div class="role-sid">' + esc(rg.sid) + '</div>' +
        '</div>' +
        '<button class="btn btn-ghost role-remove" type="button">Remove</button>' +
      '</div>';
  }
  if (!roleGroups.length) {
    roleRows = '<p class="role-note">No groups configured - every operator who can sign in can change ' +
               'every DSMT setting.</p>';
  }

  sections.push({ key: 'roles', label: 'Administrators',
    hint: (r.configured ? roleGroups.length + ' group(s)' : 'Everyone'), body:
      '<h2 class="set-h">DSMT administrators</h2>' +
      '<div class="set-state' + (s.isAdmin ? ' set-state-on' : ' set-state-off') + '">' +
        '<div class="set-state-head">' +
          '<span class="set-state-dot"></span>' +
          '<span>' + (s.isAdmin ? 'You can change DSMT settings' : 'You cannot change DSMT settings') + '</span>' +
        '</div>' +
        '<p class="muted">' + esc(s.roleReason || '') + '</p>' +
      '</div>' +
      '<p class="dialog-note"><strong>This controls DSMT\'s own settings only</strong> - the database it ' +
      'points at, the identity mode, the idle timeout, the listening port, HTTPS, and this list. ' +
      'Nothing in Active Directory governs those, which is why a role here has real teeth.</p>' +
      '<p class="dialog-note"><strong>It does not affect directory operations.</strong> Every user, ' +
      'group and password change still runs as the signed-in operator, so Active Directory decides what ' +
      'they may do - a DSMT role cannot grant a right AD withheld, and cannot take one away either. ' +
      'Someone not listed here can still open ADUC and do whatever AD permits.</p>' +
      '<p class="dialog-note">Membership is matched on <strong>SID</strong>, never on name: a group can ' +
      'be renamed and built-in groups are localised. Nested membership counts. The role is resolved at ' +
      '<strong>sign-in</strong>, so a change takes effect the next time someone signs in.</p>' +
      '<div id="roleList">' + roleRows + '</div>' +
      '<div class="set-form">' +
        '<div class="field"><label for="roleAdd">Add a group (name or DOMAIN\\Name)</label>' +
        '<input class="input" id="roleAdd" placeholder="DSMT Admins" autocomplete="off"></div>' +
      '</div>' +
      '<p class="dialog-note">DSMT refuses to save a list you are not a member of - that would lock you ' +
      'out immediately, and the only way back would be regedit on the DSMT host.</p>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="roleAddBtn">Add</button>' +
        '<button class="btn btn-primary" type="button" id="roleSave">Save administrators</button>' +
      '</div>' +
      '<div class="set-result" id="roleResult"></div>' });

  // ---- HTTPS ----
  // The live transport and the saved intent are shown as two separate facts.
  // They disagree between saving a certificate and restarting, and a screen
  // that merged them would say "HTTPS on" while passwords still cross the
  // network in clear text.
  var h = s.https || {};
  var liveHttps = (s.scheme === 'https');

  var httpsState =
    '<div class="set-state' + (liveHttps ? ' set-state-on' : ' set-state-off') + '">' +
      '<div class="set-state-head">' +
        '<span class="set-state-dot"></span>' +
        '<span>' + (liveHttps ? 'Serving HTTPS' : 'Serving plain HTTP') + '</span>' +
      '</div>' +
      '<dl class="detail-fields">' +
        settingsRow('Right now', (s.scheme || 'http') + ' on port ' + esc(String(h.livePort || s.port))) +
        settingsRow('Configured', h.enabled ? ('HTTPS on port ' + esc(String(h.port))) : 'HTTPS off') +
        settingsRow('Certificate bound', h.bound ? esc(String(h.boundTo || '')) : 'None') +
      '</dl>' +
    '</div>';

  if (!liveHttps) {
    // Two different situations, and conflating them would be the fake-data
    // failure again: "HTTPS was never set up" and "HTTPS is set up and BROKEN"
    // need different actions from the reader.
    if (h.enabled) {
      httpsState += '<div class="error-box"><strong>HTTPS is switched on but is not working, so ' +
                    'DSMT fell back to plain HTTP.</strong> The console is up so you can fix it here, ' +
                    'but this connection is not encrypted.</div>';
    } else {
      httpsState += '<p class="set-warn">Operators sign in with their <strong>domain password</strong>. ' +
                    'Until HTTPS is on, that password and every directory record cross the network in ' +
                    '<strong>clear text</strong>.</p>';
    }
  }

  if (h.warning) {
    httpsState += '<div class="error-box">' + esc(h.warning) + '</div>';
  }

  var certOptions = '<option value="">Select a certificate...</option>';
  var certs = asArray(h.certificateList);
  for (var ci = 0; ci < certs.length; ci++) {
    var c = certs[ci];
    var label = (c.subject || c.thumbprint) + ' - expires ' + c.notAfter;
    if (!c.usable) { label += ' [unusable: ' + c.why + ']'; }
    certOptions += '<option value="' + esc(c.thumbprint) + '"' +
                   (c.usable ? '' : ' disabled') +
                   (c.thumbprint === h.thumbprint ? ' selected' : '') +
                   '>' + esc(label) + '</option>';
  }

  sections.push({ key: 'https', label: 'HTTPS',
    hint: (liveHttps ? 'On, port ' + (h.port || '') : 'Off - passwords in clear text'), body:
      '<h2 class="set-h">HTTPS</h2>' +
      httpsState +
      '<p class="dialog-note">The console reads certificates from <code>' +
      esc(h.store || 'Cert:\\LocalMachine\\My') + '</code> on this host and binds one to a port. ' +
      '<strong>It never receives a private key.</strong> Uploading a .pfx and its password through ' +
      'this page would send that password over the very plain-HTTP connection HTTPS exists to ' +
      'replace, so the certificate has to be in the store first.</p>' +
      '<div class="set-form">' +
        '<div class="field"><label for="setHttpsCert">Certificate</label>' +
        '<select class="input" id="setHttpsCert">' + certOptions + '</select></div>' +
        '<div class="field"><label for="setHttpsPort">HTTPS port (1-65535)</label>' +
        '<input class="input" id="setHttpsPort" type="number" min="1" max="65535" step="1" value="' +
        esc(String(h.port || 8443)) + '"></div>' +
      '</div>' +
      (certs.length ? '' :
        '<p class="set-warn">No certificates found in the store. Put one there first, on the DSMT ' +
        'host, in an elevated prompt:</p><div class="secret">' + esc(h.importCommand || '') + '</div>') +
      (h.elevated ? '' :
        '<p class="set-warn">This process is <strong>not elevated</strong>, so it cannot bind a ' +
        'certificate itself. It will show you the command to run instead. DSMT running as the ' +
        'installed Windows service does not have this limitation.</p>') +
      '<p class="dialog-note">A listener cannot change scheme or port while it is running, so this is ' +
      'saved and applied on the next start. <strong>If the certificate is ever missing, expired or ' +
      'unbound, DSMT starts on plain HTTP rather than refusing to start</strong> - so a certificate ' +
      'that expires overnight does not take the console down with it. It is not quiet about it: the ' +
      'startup banner, the log and a bar across the top of every screen all say the connection is ' +
      'not encrypted until it is fixed.</p>' +
      '<div class="set-actions">' +
        '<button class="btn btn-primary" type="button" id="applyHttps">Enable HTTPS</button>' +
        (h.enabled ? '<button class="btn btn-ghost" type="button" id="disableHttps">Switch HTTPS off</button>' : '') +
      '</div>' +
      '<div class="set-result" id="httpsResult"></div>' +
      '<div id="httpsCommands"></div>' });

  sections.push({ key: 'groupfilters', label: 'Group filters', hint: 'Chips on the Groups tab', body:
      '<h2 class="set-h">Group filters</h2>' +
      '<p class="dialog-note">Every filter the Groups tab offers is listed below. The built-in ones are ' +
      '<strong>read-only</strong> - they are facts about Active Directory, not settings, and each says ' +
      'what it matches on.</p>' +
      '<p class="dialog-note">Add your own below. A group matches when any term appears in its name, ' +
      'sAMAccountName, description or OU. These are stored on the server, so everyone using this console ' +
      'sees the same filters.</p>' +
      '<div id="gfList"></div>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="gfAdd">Add a filter</button>' +
        '<button class="btn btn-primary" type="button" id="gfSave">Save filters</button>' +
      '</div>' +
      '<div class="set-result" id="gfResult"></div>' });

  sections.push({ key: 'sql', label: 'Database',
    hint: (s.sqlEnabled ? s.sqlServer + ' / ' + s.sqlDatabase : 'Not connected'), body:
      '<h2 class="set-h">Database</h2>' +
      storage +
      '<div class="set-form">' +
        '<div class="field"><label for="setSqlServer">SQL Server instance</label>' +
        '<input class="input" id="setSqlServer" placeholder="SQL01 or SQL01\\INSTANCE" autocomplete="off" value="' +
        esc(s.sqlServer || '') + '"></div>' +
        '<div class="field"><label for="setSqlDb">Database name</label>' +
        '<input class="input" id="setSqlDb" autocomplete="off" value="' + esc(s.sqlDatabase || 'DSMT') + '"></div>' +
        '<div class="field"><label for="setSqlUser">SQL user (blank = Windows auth)</label>' +
        '<input class="input" id="setSqlUser" autocomplete="off"></div>' +
        '<div class="field"><label for="setSqlPass">SQL password</label>' +
        '<input class="input" id="setSqlPass" type="password" autocomplete="new-password"></div>' +
      '</div>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="listDbs">List existing databases</button>' +
      '</div>' +
      '<div class="field" id="dbPickField" hidden>' +
        '<label for="setSqlPick">Existing databases on that instance</label>' +
        '<select class="input" id="setSqlPick"></select>' +
      '</div>' +
      '<p class="dialog-note">Upgrading an existing installation? List the databases and pick the one ' +
      'you already have - DSMT will use it and add only the tables that are missing. Creating a new ' +
      'database needs the <code>dbcreator</code> right; using one that exists needs only read and write.</p>' +
      '<div class="set-actions">' +
        '<button class="btn btn-primary" type="button" id="applySql">' +
        (s.sqlEnabled ? 'Reconnect' : 'Connect') + '</button>' +
      '</div>' +
      '<div class="set-confirm" id="sqlConfirm" hidden>' +
        '<p id="sqlConfirmText"></p>' +
        '<div class="set-actions">' +
          '<button class="btn btn-primary" type="button" id="confirmCreateDb">Create the database</button>' +
          '<button class="btn btn-ghost" type="button" id="cancelCreateDb">Cancel</button>' +
        '</div>' +
      '</div>' +
      '<div class="set-result" id="sqlResult"></div>' });

  sections.push({ key: 'identity', label: 'Identity', hint: 'Who reads the directory', body:
      '<h2 class="set-h">Identity</h2>' +
      '<dl class="detail-fields">' +
        settingsRow('DSMT runs as', s.serviceUser) +
        settingsRow('Registered account', s.serviceAccount) +
        settingsRow('Account type', accountKindLabel(s.accountKind)) +
      '</dl>' +
      '<p class="dialog-note">Which account performs directory operations. ' +
      '<strong>Writes always run as the signed-in operator</strong> in either mode, so the domain ' +
      'controller records who made each change.</p>' +
      '<div class="set-form">' +
        '<div class="field"><label for="setIdentity">Identity mode</label>' +
        '<select class="input" id="setIdentity">' +
          '<option value="operator"' + (s.identityMode === 'operator' ? ' selected' : '') + '>' +
            'Operator - reads and writes both run as the signed-in operator</option>' +
          '<option value="hybrid"' + (s.identityMode === 'hybrid' ? ' selected' : '') + '>' +
            'Hybrid - reads run as the service account</option>' +
        '</select></div>' +
      '</div>' +
      '<p class="dialog-note" id="identityWarning"></p>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="applyIdentity">Apply identity mode</button>' +
      '</div>' +
      '<div class="set-result" id="identityResult"></div>' });

  sections.push({ key: 'account', label: 'Service account', hint: 'Move to gMSA or a user', body:
      '<h2 class="set-h">Service account</h2>' +
      '<p class="dialog-note">Move DSMT onto a dedicated account, a group managed service account ' +
      '(gMSA) or the machine account. Pick the target below and DSMT builds the exact command.</p>' +
      '<div class="set-form">' +
        '<div class="field"><label for="setAcctKind">Account type</label>' +
        '<select class="input" id="setAcctKind">' +
          '<option value="gmsa">gMSA - no password, recommended</option>' +
          '<option value="user">Dedicated account - you are prompted for its password</option>' +
          '<option value="machine">LocalSystem - the machine account, no password</option>' +
        '</select></div>' +
        '<div class="field" id="acctNameField"><label for="setAcctName">Account name</label>' +
        '<input class="input" id="setAcctName" placeholder="LAB\\gmsa-dsmt$" autocomplete="off"></div>' +
      '</div>' +
      '<p class="dialog-note" id="acctHint"></p>' +
      '<label class="set-cmd-label" for="acctCmd">Run this on the DSMT host, in an elevated PowerShell:</label>' +
      '<div class="secret" id="acctCmd"></div>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="copyAcctCmd">Copy command</button>' +
      '</div>' +
      '<p class="dialog-note"><strong>Why this is not a button that just does it:</strong> changing ' +
      'the account rewrites the Windows service or scheduled task, the HTTP URL reservation, the ' +
      'data folder permissions and the SQL login. Those need administrator rights on the host, which ' +
      'this process deliberately does not have. The command does all five as one operation and ' +
      'verifies the account before touching anything.</p>' });

  sections.push({ key: 'sessions', label: 'Sessions', hint: 'Idle timeout', body:
      '<h2 class="set-h">Sessions</h2>' +
      '<p class="dialog-note">An operator who does not touch the console for this long is signed ' +
      'out; the browser warns a minute beforehand. Applies to sessions already open. Maximum ' +
      bounds.max + ' minutes (' + Math.round(bounds.max / 60) + ' hours).</p>' +
      '<div class="set-form">' +
        '<div class="field"><label for="setIdle">Minutes of inactivity (' + bounds.min + '-' + bounds.max + ')</label>' +
        '<input class="input" id="setIdle" type="number" min="' + bounds.min + '" max="' + bounds.max +
        '" step="1" value="' + esc(String(s.sessionMinutes || bounds.def)) + '"></div>' +
        '<div class="field"><label for="setIdlePreset">Common values</label>' +
        '<select class="input" id="setIdlePreset">' +
          '<option value="">Choose</option>' +
          '<option value="5">5 minutes</option>' +
          '<option value="15">15 minutes (default)</option>' +
          '<option value="30">30 minutes</option>' +
          '<option value="60">1 hour</option>' +
          '<option value="240">4 hours</option>' +
          '<option value="480">8 hours (maximum)</option>' +
        '</select></div>' +
      '</div>' +
      '<div class="set-actions">' +
        '<button class="btn btn-secondary" type="button" id="applyIdle">Apply idle timeout</button>' +
      '</div>' +
      '<div class="set-result" id="idleResult"></div>' });

  var bodyHtml = '';
  var navHtml = '';
  var i;
  for (i = 0; i < sections.length; i++) {
    bodyHtml += '<section class="set-card" id="setSec-' + sections[i].key + '">' +
                sections[i].body + '</section>';
    navHtml += '<button class="set-nav-item" type="button" data-section="' + sections[i].key + '">' +
               '<span>' + esc(sections[i].label) + '</span>' +
               '<span class="set-nav-hint">' + esc(sections[i].hint) + '</span></button>';
  }
  $('settingsBody').innerHTML = bodyHtml;
  $('settingsNav').innerHTML = navHtml;

  state.settingsSections = sections;
  wireSettingsNav();
  wireSettings(bounds);
}

/* ---------------------------------------------------------------------------
   The section rail. One section is shown at a time - calm on a monitor, and
   the only shape that works on a phone. Which one was open is remembered per
   browser, so Settings comes back where it was left.
   --------------------------------------------------------------------------- */

var SET_SECTION_KEY = 'dsmt.settings.section';

function readSetting(key, fallback) {
  try {
    var v = window.localStorage.getItem(key);
    return v ? v : fallback;
  } catch (e) { return fallback; }
}

function writeSetting(key, value) {
  try { window.localStorage.setItem(key, value); } catch (e) { /* private mode */ }
}

function wireSettingsNav() {
  var items = $('settingsNav').querySelectorAll('.set-nav-item');
  var i;
  for (i = 0; i < items.length; i++) {
    items[i].onclick = function () {
      writeSetting(SET_SECTION_KEY, this.getAttribute('data-section'));
      showSettingsSection();
    };
  }
  showSettingsSection();
}

function showSettingsSection() {
  var sections = state.settingsSections || [];
  if (!sections.length) { return; }

  var current = readSetting(SET_SECTION_KEY, sections[0].key);
  var known = false;
  var i;
  for (i = 0; i < sections.length; i++) { if (sections[i].key === current) { known = true; } }
  if (!known) { current = sections[0].key; }

  var items = $('settingsNav').querySelectorAll('.set-nav-item');
  for (i = 0; i < items.length; i++) {
    items[i].className = 'set-nav-item' +
      (items[i].getAttribute('data-section') === current ? ' is-active' : '');
  }

  // Run the checks when Health is opened, not when Settings loads: they cost a
  // live directory search and a SQL round trip, and nobody wants those on the
  // way to changing an idle timeout.
  if (current === 'health' && !state.healthLoaded) { loadHealth(); }

  // The other cards are hidden, never removed - the handlers wired by
  // wireSettings() stay attached to elements that still exist.
  for (i = 0; i < sections.length; i++) {
    var card = $('setSec-' + sections[i].key);
    if (card) { card.hidden = (sections[i].key !== current); }
  }
}

/* ---------------------------------------------------------------------------
   Health. One request, one verdict per check, and a fix for anything that is
   not green - a red light with no instruction has moved the problem rather
   than helped with it. Most of the "the server won't start" reports in this
   project's history were a known external step nobody had done yet.
   --------------------------------------------------------------------------- */

function loadHealth() {
  var btn = $('runHealth');
  if (btn) { btn.disabled = true; btn.textContent = 'Checking...'; }
  $('healthBody').innerHTML = '<p class="muted-sm">Running the checks...</p>';

  api('/api/health').then(function (data) {
    state.healthLoaded = true;
    renderHealth(data);
  }).catch(function (err) {
    state.healthLoaded = true;
    // A failure here is itself the answer: the server is not answering at all.
    $('healthBody').innerHTML = '<div class="error-box"><strong>The health check itself failed.</strong>' +
      esc(explainApiError(err.message)) + '</div>';
  }).then(function () {
    if (btn) { btn.disabled = false; btn.textContent = 'Run checks'; }
  });
}

function healthWordFor(status) {
  if (status === 'ok') { return 'OK'; }
  if (status === 'warn') { return 'Attention'; }
  return 'Failing';
}

function renderHealth(data) {
  var checks = asArray(data.checks);

  var head =
    '<div class="set-state set-state-' + esc(data.overall) + '">' +
      '<div class="set-state-head">' +
        '<span class="set-state-dot"></span>' +
        '<span>' + esc(healthWordFor(data.overall)) + '</span>' +
      '</div>' +
      '<p class="muted-sm">' +
        (data.overall === 'ok'
          ? 'Every check passed.'
          : 'One or more checks need attention. Each one below says what to do.') +
      '</p>' +
    '</div>';

  var rows = checks.map(function (c) {
    var fix = c.fix
      ? '<p class="health-fix"><strong>Fix:</strong> ' + esc(c.fix) + '</p>'
      : '';
    return '<div class="health-item health-' + esc(c.status) + '">' +
             '<div class="health-item-head">' +
               '<span class="set-state-dot"></span>' +
               '<span class="health-name">' + esc(c.name) + '</span>' +
               '<span class="health-verdict">' + esc(healthWordFor(c.status)) + '</span>' +
             '</div>' +
             '<p class="health-detail">' + esc(c.detail) + '</p>' +
             fix +
           '</div>';
  }).join('');

  $('healthBody').innerHTML = head + '<div class="health-list">' + rows + '</div>';

  var stamp = $('healthStamp');
  if (stamp) { stamp.textContent = 'Checked ' + formatStamp(data.checkedAt); }
}

/* The custom filters only. Built-ins are not editable, so they are not shown
   as rows that look editable. */
function gfFromServer() {
  var out = [];
  asArray(state.groupFilters).forEach(function (f) {
    if (f.kind !== 'custom') { return; }
    out.push({ label: f.label, terms: asArray(f.terms).join(', ') });
  });
  return out;
}

function builtinFilterRows() {
  // The built-ins are listed HERE, on the screen that lists filters, rather
  // than described in a paragraph above it. They stay read-only and say so:
  // Privileged is matched on SID precisely because a group called Domain
  // Admins can be renamed and is localised, so exposing it as an editable
  // term list would invite someone to break it where it matters most.
  var rows = asArray(state.groupFilters).filter(function (f) {
    return f.kind === 'builtin' && f.key !== 'all';
  });
  if (!rows.length) { return ''; }

  return rows.map(function (f) {
    return '<div class="role-row">' +
             '<div class="role-main">' +
               '<strong>' + esc(f.label) + '</strong> ' +
               '<span class="tag">Built in - read only</span>' +
               '<div class="role-note">' + esc(f.how || '') + '</div>' +
             '</div>' +
           '</div>';
  }).join('');
}

function renderGroupFilterEditor() {
  var box = $('gfList');
  if (!box) { return; }

  var builtins = builtinFilterRows();

  if (!state.gfDraft.length) {
    box.innerHTML = builtins +
      '<p class="muted-sm">No custom filters yet.</p>';
    return;
  }

  box.innerHTML = builtins + state.gfDraft.map(function (row, i) {
    return '<div class="set-form gf-row">' +
             '<div class="field"><label for="gfName' + i + '">Name</label>' +
             '<input class="input" id="gfName' + i + '" data-gf="' + i + '" data-gffield="label" ' +
             'placeholder="Service accounts" autocomplete="off" value="' + esc(row.label) + '"></div>' +
             '<div class="field"><label for="gfTerms' + i + '">Match terms (comma separated)</label>' +
             '<input class="input" id="gfTerms' + i + '" data-gf="' + i + '" data-gffield="terms" ' +
             'placeholder="svc-, service, gmsa" autocomplete="off" value="' + esc(row.terms) + '"></div>' +
             '<div class="set-actions"><button class="btn btn-ghost btn-undo" type="button" ' +
             'data-gfdrop="' + i + '">Remove</button></div>' +
           '</div>';
  }).join('');

  var inputs = box.querySelectorAll('[data-gf]');
  var i;
  for (i = 0; i < inputs.length; i++) {
    inputs[i].oninput = function () {
      state.gfDraft[parseInt(this.getAttribute('data-gf'), 10)][this.getAttribute('data-gffield')] = this.value;
    };
  }

  var drops = box.querySelectorAll('[data-gfdrop]');
  for (i = 0; i < drops.length; i++) {
    drops[i].onclick = function () {
      state.gfDraft.splice(parseInt(this.getAttribute('data-gfdrop'), 10), 1);
      renderGroupFilterEditor();
    };
  }
}

function accountKindLabel(kind) {
  if (kind === 'gmsa') { return 'Group managed service account (no password)'; }
  if (kind === 'machine') { return 'Machine account (LocalSystem)'; }
  if (kind === 'user') { return 'Ordinary account'; }
  return '';
}

/* "No API route for POST /api/..." has exactly one cause worth naming: the
   web files were copied but the server was not restarted, so a new front end
   is talking to an old back end. Say that instead of the raw 404, because the
   raw 404 reads like a bug in the feature. */
function explainApiError(message) {
  if (message && message.indexOf('No API route') === 0) {
    return message + ' - the server is running an older build than these web ' +
           'files. Copy server\\lib\\*.ps1 to the DSMT host and restart ' +
           'Start-DSMT.ps1, then reload this page.';
  }
  return message;
}

/* Inline result, shown next to the control that produced it - so a failure is
   readable even if no overlay renders. */
function setResult(id, message, ok) {
  var box = $(id);
  if (!box) { return; }
  box.className = 'set-result ' + (ok ? 'set-result-ok' : 'set-result-bad');
  box.textContent = message;
}

function wireSettings(bounds) {

  // ---- health ----
  $('runHealth').addEventListener('click', function () { loadHealth(); });

  // ---- group filters ----
  // Edited as a local list and saved in one call, so a half-finished row
  // never reaches the server and a mistake can be abandoned by leaving.
  if (!state.gfDraft) { state.gfDraft = gfFromServer(); }
  renderGroupFilterEditor();

  $('gfAdd').addEventListener('click', function () {
    state.gfDraft.push({ label: '', terms: '' });
    renderGroupFilterEditor();
  });

  $('gfSave').addEventListener('click', function () {
    var payload = [];
    var i;
    for (i = 0; i < state.gfDraft.length; i++) {
      var label = (state.gfDraft[i].label || '').trim();
      var terms = (state.gfDraft[i].terms || '').split(',').map(function (t) { return t.trim(); })
                    .filter(function (t) { return t.length > 0; });
      if (!label && !terms.length) { continue; }
      if (!label) { setResult('gfResult', 'Every filter needs a name.', false); return; }
      if (!terms.length) { setResult('gfResult', 'Filter "' + label + '" has no terms to match.', false); return; }
      payload.push({ label: label, terms: terms });
    }

    setResult('gfResult', 'Saving...', true);
    api('/api/settings/groupfilters', { method: 'POST', body: { filters: payload } })
      .then(function (res) {
        state.groupFilters = asArray(res.filters);
        state.gfDraft = gfFromServer();
        renderGroupFilterEditor();
        setResult('gfResult', payload.length + ' custom filter(s) saved. They appear on the Groups tab.', true);
        toast('Group filters saved.', 'good');
      })
      .catch(function (err) { setResult('gfResult', explainApiError(err.message), false); });
  });

  // ---- SQL ----
  function sqlCredentials() {
    return {
      server: $('setSqlServer').value.trim(),
      database: $('setSqlDb').value.trim() || 'DSMT',
      username: $('setSqlUser').value.trim(),
      password: $('setSqlPass').value
    };
  }

  function hideCreateConfirm() { $('sqlConfirm').hidden = true; }

  $('listDbs').addEventListener('click', function () {
    var creds = sqlCredentials();
    if (!creds.server) { setResult('sqlResult', 'Enter the SQL Server instance first.', false); return; }

    hideCreateConfirm();
    setResult('sqlResult', 'Listing databases on ' + creds.server + '...', true);

    api('/api/settings/sql/databases', {
      method: 'POST',
      body: { server: creds.server, username: creds.username, password: creds.password }
    }).then(function (res) {
      var names = asArray(res.databases);
      var pick = $('setSqlPick');

      if (!names.length) {
        $('dbPickField').hidden = true;
        setResult('sqlResult', 'Connected, but the instance has no user databases yet. ' +
                  'Type a name above and press Connect to create one.', true);
        return;
      }

      pick.innerHTML = '<option value="">Choose a database</option>' +
        names.map(function (n) {
          var sel = (n === creds.database) ? ' selected' : '';
          return '<option value="' + esc(n) + '"' + sel + '>' + esc(n) + '</option>';
        }).join('');
      $('dbPickField').hidden = false;

      setResult('sqlResult', names.length + ' database' + (names.length === 1 ? '' : 's') +
                ' found. Pick one to use it, or type a new name to create one.', true);
    }).catch(function (err) {
      $('dbPickField').hidden = true;
      setResult('sqlResult', explainApiError(err.message), false);
    });
  });

  // Picking from the list fills the name field, so there is one place the
  // name actually comes from.
  $('setSqlPick').addEventListener('change', function (e) {
    if (e.target.value) {
      $('setSqlDb').value = e.target.value;
      hideCreateConfirm();
      setResult('sqlResult', 'Will use the existing database ' + e.target.value +
                '. Press Connect.', true);
    }
  });

  function connectSql(createIfMissing) {
    var creds = sqlCredentials();
    if (!creds.server) { setResult('sqlResult', 'Enter the SQL Server instance.', false); return; }

    hideCreateConfirm();
    setResult('sqlResult', 'Connecting to ' + creds.server + '...', true);

    creds.createIfMissing = createIfMissing;

    api('/api/settings/sql', { method: 'POST', body: creds })
      .then(function (res) {
        // The database is simply not there yet - ask before creating one,
        // because a typo in the instance name should not silently produce a
        // stray database on a production server.
        if (res && res.needsCreate) {
          $('sqlConfirmText').textContent =
            'The database "' + res.database + '" does not exist on ' + res.server +
            '. Create it now? This needs the dbcreator right on the instance.';
          $('sqlConfirm').hidden = false;
          setResult('sqlResult', '', true);
          return;
        }

        state.storage = res.storage;
        renderNotifications();

        var what;
        if (res.databaseCreated) {
          what = 'Created database ' + res.storage.sqlDatabase + ' on ' + res.storage.sqlServer +
                 ' with ' + res.tablesCreated + ' tables.';
        } else if (res.tablesCreated > 0) {
          what = 'Using the existing database ' + res.storage.sqlDatabase + '. Added ' +
                 res.tablesCreated + ' missing table' + (res.tablesCreated === 1 ? '' : 's') + '.';
        } else {
          what = 'Using the existing database ' + res.storage.sqlDatabase +
                 '. All ' + res.tablesFound + ' tables were already present.';
        }
        if (!res.persisted) {
          what += ' NOTE: the setting could not be saved (' + res.persistError +
                  '), so it will be lost on restart.';
        }
        setResult('sqlResult', what, true);
        loadSettings();
      })
      .catch(function (err) {
        // The server returns the real SQL error - show it verbatim, it is the
        // whole point of this control.
        setResult('sqlResult', err.message, false);
      });
  }

  $('applySql').addEventListener('click', function () { connectSql(false); });
  $('confirmCreateDb').addEventListener('click', function () { connectSql(true); });
  $('cancelCreateDb').addEventListener('click', function () {
    hideCreateConfirm();
    setResult('sqlResult', 'Nothing was created.', true);
  });

  // ---- identity mode ----
  var identity = $('setIdentity');
  var warning = $('identityWarning');
  function describeIdentity() {
    if (identity.value === 'hybrid') {
      warning.innerHTML = '<strong>Every operator will be able to see everything ' +
        esc(state.settings.serviceUser || 'the service account') + ' can see</strong>, whether or ' +
        'not they have read rights of their own in the directory.';
    } else {
      warning.textContent = 'Each operator sees only what the directory lets them see.';
    }
  }
  identity.addEventListener('change', describeIdentity);
  describeIdentity();

  $('applyIdentity').addEventListener('click', function () {
    api('/api/settings/identity', { method: 'POST', body: { mode: identity.value } })
      .then(function (res) {
        if (state.identity) { state.identity.mode = res.identityMode; }
        renderNotifications();
        setResult('identityResult', 'Identity mode set to ' + res.identityMode + '.' +
                  (res.persisted ? '' : ' Not saved: ' + res.persistError), res.persisted);
        if (state.tab !== 'settings') { loadRows(); }
      })
      .catch(function (err) { setResult('identityResult', err.message, false); });
  });

  // ---- service account command builder ----
  var kind = $('setAcctKind');
  var name = $('setAcctName');
  var hint = $('acctHint');

  function buildCommand() {
    var target = name.value.trim();
    var show = (kind.value !== 'machine');
    $('acctNameField').hidden = !show;

    if (kind.value === 'gmsa') {
      hint.textContent = 'End the name with a dollar sign. The gMSA must already exist and be ' +
                         'installed on this host (Install-ADServiceAccount). No password is asked for.';
      if (target && target.charAt(target.length - 1) !== '$') { target = target + '$'; }
    } else if (kind.value === 'user') {
      hint.textContent = 'You are prompted for the password once - Windows has to store it to log ' +
                         'on at boot. Set the password not to expire, or use a gMSA.';
    } else {
      hint.textContent = 'Reaches AD and SQL as the computer account. Grant that account rights on ' +
                         'the SQL instance.';
      target = 'LocalSystem';
    }

    var arg = target || (kind.value === 'gmsa' ? 'DOMAIN\\gmsa-dsmt$' : 'DOMAIN\\svc-dsmt');
    $('acctCmd').textContent = '.\\server\\Install-DSMT.ps1 -ChangeServiceAccount "' + arg + '"';
  }

  kind.addEventListener('change', buildCommand);
  name.addEventListener('input', buildCommand);
  buildCommand();

  // One copy path for the whole console - see copyText(). It was duplicated
  // here with its own fallback until the Tools screen needed the same thing.
  $('copyAcctCmd').addEventListener('click', function () {
    copyText($('acctCmd').textContent, '');
  });

  // ---- port ----
  $('applyPort').addEventListener('click', function () {
    var port = parseInt($('setPort').value, 10);
    if (isNaN(port) || port < 1 || port > 65535) {
      setResult('portResult', 'The port must be between 1 and 65535.', false);
      return;
    }

    api('/api/settings/network', { method: 'POST', body: { port: port } })
      .then(function (res) {
        var message = 'Port saved as ' + res.port + '. It takes effect the next time DSMT starts - ' +
                      'until then the console is still on ' + res.previousPort + '.';
        if (!res.persisted) { message += ' NOT saved: ' + res.persistError; }
        setResult('portResult', message, res.persisted);

        var cmds = '';
        if (res.reservation) {
          cmds += '<label class="set-cmd-label">Reserve the new URL, elevated, on the DSMT host:</label>' +
                  '<div class="secret">' + esc(res.reservation) + '</div>';
        }
        if (res.firewall) {
          cmds += '<label class="set-cmd-label">Open the new port in the firewall:</label>' +
                  '<div class="secret">' + esc(res.firewall) + '</div>';
        }
        $('portCommands').innerHTML = cmds;
      })
      .catch(function (err) { setResult('portResult', err.message, false); });
  });

  // ---- Roles ----
  // The pending list lives in the DOM rather than in a variable, so what is
  // saved is exactly what is on screen.
  if ($('roleAddBtn')) {
    $('roleAddBtn').addEventListener('click', function () {
      var name = $('roleAdd').value.trim();
      if (!name) { return; }

      var list = $('roleList');
      if (list.querySelector('p.role-note')) { list.innerHTML = ''; }

      var row = document.createElement('div');
      row.className = 'role-row';
      row.setAttribute('data-pending', name);
      row.innerHTML = '<div class="role-main"><strong>' + esc(name) + '</strong>' +
                      '<div class="role-note">Not saved yet - the SID is resolved when you save.</div></div>' +
                      '<button class="btn btn-ghost role-remove" type="button">Remove</button>';
      list.appendChild(row);
      $('roleAdd').value = '';
    });
  }

  if ($('roleList')) {
    $('roleList').addEventListener('click', function (e) {
      var btn = e.target.closest('.role-remove');
      if (!btn) { return; }
      var row = btn.closest('.role-row');
      if (row && row.parentNode) { row.parentNode.removeChild(row); }
    });
  }

  if ($('roleSave')) {
    $('roleSave').addEventListener('click', function () {
      var rows = $('roleList').querySelectorAll('.role-row');
      var names = [];
      for (var i = 0; i < rows.length; i++) {
        // A saved row is sent back by SID, a pending one by the typed name -
        // both are re-resolved server-side, so a group renamed since it was
        // added keeps working and gets its display name refreshed.
        var sid = rows[i].getAttribute('data-sid');
        var pending = rows[i].getAttribute('data-pending');
        names.push(sid || pending);
      }

      api('/api/settings/roles', { method: 'POST', body: { groups: names } })
        .then(function (res) {
          var message;
          if (!res.count) {
            message = 'Cleared. Every operator who can sign in can now change every DSMT setting.';
          } else {
            message = res.count + ' group(s) saved. This takes effect at each operator\'s next sign-in, ' +
                      'because the role is resolved once when they sign in.';
          }
          if (!res.persisted) { message += ' NOT saved: ' + res.persistError; }
          setResult('roleResult', message, res.persisted);
          loadSettings();
        })
        .catch(function (err) { setResult('roleResult', err.message, false); });
    });
  }

  // ---- HTTPS ----
  if ($('applyHttps')) {
    $('applyHttps').addEventListener('click', function () {
      var thumb = $('setHttpsCert').value;
      var hport = parseInt($('setHttpsPort').value, 10);

      if (!thumb) {
        setResult('httpsResult', 'Choose a certificate first.', false);
        return;
      }
      if (isNaN(hport) || hport < 1 || hport > 65535) {
        setResult('httpsResult', 'The HTTPS port must be between 1 and 65535.', false);
        return;
      }

      api('/api/settings/https', { method: 'POST', body: { enabled: true, port: hport, thumbprint: thumb } })
        .then(function (res) {
          var message = 'Certificate bound to port ' + res.port + '.';
          if (res.replaced) { message += ' It replaced the previous DSMT binding on that port.'; }
          message += ' HTTPS starts serving the next time DSMT restarts - until then this console is ' +
                     'still on plain HTTP. After the restart, open ' + res.url;
          if (!res.persisted) { message += ' NOT saved: ' + res.persistError; }
          setResult('httpsResult', message, res.persisted);

          var cmds = '';
          if (res.reservation) {
            cmds += '<label class="set-cmd-label">Reserve the HTTPS URL, elevated, on the DSMT host:</label>' +
                    '<div class="secret">' + esc(res.reservation) + '</div>';
          }
          if (res.firewall) {
            cmds += '<label class="set-cmd-label">Open the HTTPS port in the firewall:</label>' +
                    '<div class="secret">' + esc(res.firewall) + '</div>';
          }
          $('httpsCommands').innerHTML = cmds;
        })
        .catch(function (err) { setResult('httpsResult', err.message, false); });
    });
  }

  if ($('disableHttps')) {
    $('disableHttps').addEventListener('click', function () {
      openDialog({
        title: 'Switch HTTPS off?',
        body: '<p>DSMT will go back to serving plain HTTP on the next restart, and operator ' +
              'domain passwords will cross the network in clear text again.</p>',
        confirmLabel: 'Switch HTTPS off',
        onConfirm: function () {
          api('/api/settings/https', { method: 'POST', body: { enabled: false } })
            .then(function (res) {
              closeDialog();
              var message = res.message;
              if (!res.bindingRemoved && res.bindingError) {
                message += ' The certificate binding was left in place: ' + res.bindingError;
              }
              if (!res.persisted) { message += ' NOT saved: ' + res.persistError; }
              setResult('httpsResult', message, res.persisted);
              $('httpsCommands').innerHTML = '';
            })
            .catch(function (err) { dialogError(err.message); });
        }
      });
    });
  }

  // ---- idle timeout ----
  $('setIdlePreset').addEventListener('change', function (e) {
    if (e.target.value) { $('setIdle').value = e.target.value; }
  });

  $('applyIdle').addEventListener('click', function () {
    var minutes = parseInt($('setIdle').value, 10);
    if (isNaN(minutes) || minutes < bounds.min || minutes > bounds.max) {
      setResult('idleResult', 'The idle timeout must be between ' + bounds.min + ' and ' +
                bounds.max + ' minutes.', false);
      return;
    }
    api('/api/settings/session', { method: 'POST', body: { sessionMinutes: minutes } })
      .then(function (res) {
        state.sessionMinutes = res.sessionMinutes;
        startIdleWatch(res.sessionMinutes);
        setResult('idleResult', 'Idle timeout set to ' + res.sessionMinutes + ' minutes.' +
                  (res.persisted ? '' : ' Not saved: ' + res.persistError), res.persisted);
      })
      .catch(function (err) { setResult('idleResult', err.message, false); });
  });

  // ---- settings export ----
  $('exportSettings').addEventListener('click', function () {
    api('/api/settings/export').then(function (res) {
      openDialog({
        title: 'All settings',
        hideConfirm: true,
        cancelLabel: 'Close',
        body: '<p class="dialog-note">Read live from ' + esc(res.settingsKey) + '. This is a view, not ' +
              'a second copy - editing it here is not possible, and nothing is written back. Copy it ' +
              'into a ticket, or compare it against another host.</p>' +
              '<div class="secret secret-block">' + esc(res.json) + '</div>'
      });
    }).catch(function (err) {
      setResult('exportResult', explainApiError(err.message), false);
    });
  });

  // ---- search result cap ----
  $('setPagePreset').addEventListener('change', function (e) {
    if (e.target.value) { $('setPageSize').value = e.target.value; }
  });

  $('applyPageSize').addEventListener('click', function () {
    var size = parseInt($('setPageSize').value, 10);
    if (isNaN(size)) {
      setResult('pageSizeResult', 'Enter a whole number.', false);
      return;
    }
    api('/api/settings/pagesize', { method: 'POST', body: { pageSize: size } })
      .then(function (res) {
        // state.limit is what the "result limit reached" notice quotes, so it
        // has to follow the server or the console reports the old number
        // against the new behaviour.
        state.limit = res.pageSize;
        if (state.settings) { state.settings.pageSize = res.pageSize; }
        setResult('pageSizeResult', 'Searches now return at most ' + res.pageSize + ' objects.' +
                  (res.persisted ? '' : ' Not saved: ' + res.persistError), res.persisted);
        renderSettings();
      })
      .catch(function (err) { setResult('pageSizeResult', explainApiError(err.message), false); });
  });

  // ---- AD health alerts ----
  $('applyAlerts').addEventListener('click', function () {
    var on = ($('setAlertsOn').value === '1');
    var mins = parseInt($('setAlertMins').value, 10);
    if (isNaN(mins)) {
      setResult('alertsResult', 'Enter a whole number of minutes.', false);
      return;
    }
    api('/api/settings/alerts', { method: 'POST', body: { enabled: on, intervalMinutes: mins } })
      .then(function (res) {
        if (state.settings) {
          state.settings.alerts = { enabled: res.enabled, intervalMinutes: res.intervalMinutes };
        }
        setResult('alertsResult', res.enabled
          ? ('AD health is checked at most once every ' + res.intervalMinutes + ' minutes.')
          : 'AD health alerts are off. The Tools > AD health screen still runs on demand.',
          res.persisted);
        if (res.enabled) { startAdAlertWatch(); } else { stopAdAlertWatch(); state.adAlert = null; renderNotifications(); }
      })
      .catch(function (err) { setResult('alertsResult', explainApiError(err.message), false); });
  });

  $('runAlertsNow').addEventListener('click', function () {
    setResult('alertsResult', 'Running the checks against every domain controller. This can take a while.', true);
    api('/api/alerts?force=1')
      .then(function (res) {
        state.adAlert = res.alert || null;
        renderNotifications();
        var n = res.alert ? res.alert.count : 0;
        setResult('alertsResult', n
          ? (n + ' problem' + (n === 1 ? '' : 's') + ' found - open the bell at the top right.')
          : 'Checked: nothing wrong.', true);
      })
      .catch(function (err) { setResult('alertsResult', explainApiError(err.message), false); });
  });
}

function actionAbout() {
  var d = state.domainInfo;
  var controllers = d ? asArray(d.controllers) : [];

  var rows = [
    ['Version', state.version],
    ['Published by', state.publisher],
    ['Signed in as', state.user ? state.user.account : ''],
    ['Identity mode', state.identity ? state.identity.mode : ''],
    ['Service account', state.identity ? state.identity.serviceUser : ''],
    ['Idle timeout', state.sessionMinutes ? (state.sessionMinutes + ' minutes') : ''],
    ['Domain', d ? d.domain : state.domain],
    ['NetBIOS name', d ? d.netbios : ''],
    ['Forest', d ? d.forest : ''],
    ['Domain controllers', d ? String(d.controllerCount) : ''],
    ['Connected to', d ? d.connectedTo : ''],
    ['Record store', storageLine()]
  ].filter(function (r) { return r[1]; });

  openDialog({
    title: 'About DSMT',
    hideConfirm: true,
    cancelLabel: 'Close',
    body: '<p class="dialog-note">Directory Service Management Tool - a console for Active Directory ' +
          'operations. Every value below is read live from the directory this console is connected to.</p>' +
          '<dl class="detail-fields">' + rows.map(function (r) {
            return '<div class="detail-row"><dt>' + esc(r[0]) + '</dt><dd>' + esc(r[1]) + '</dd></div>';
          }).join('') + '</dl>' +
          (controllers.length
            ? '<div class="detail-fields"><span class="detail-section-label">Controllers</span>' +
              '<ul class="member-list">' + controllers.map(function (c) {
                return '<li><span class="member-dot"></span><span class="member-name">' + esc(c.name) + '</span>' +
                       '<span class="member-meta">' + esc(c.site) + (c.isGc ? ' - GC' : '') + '</span></li>';
              }).join('') + '</ul></div>'
            : '') +
          '<p class="dialog-note">Version numbering is MAJOR.FEATURE.FIX and comes from one constant on ' +
          'the server, surfaced through /api/meta.</p>' +
          (state.publisher
            ? '<p class="dialog-note">' + esc(state.publisher) + '</p>'
            : '')
  });
}

function dispatchAction(kind, rows) {
  if (!rows.length) { toast('Select at least one row first.', 'bad'); return; }

  switch (kind) {
    case 'reset-password':  actionResetPassword(rows); break;
    case 'unlock':          actionSimple('unlock', rows); break;
    case 'enable':          actionSimple('enable', rows); break;
    case 'disable':         actionSimple('disable', rows); break;
    case 'move-ou':         actionMoveOu(rows); break;
    case 'group-add':       actionAddToGroup(rows); break;
    case 'add-members':     actionAddMembers(state.detail); break;
    case 'delete':          actionDelete(rows); break;
    case 'export-members':  exportMembers(); break;
    default: break;
  }
}

function exportMembers() {
  var d = state.detail;
  var members = d ? asArray(d.memberships) : [];
  if (!members.length) { toast('This group has no members to export.', 'bad'); return; }
  downloadCsv('dsmt-members-' + (d.sam || 'group') + '-' + stampName() + '.csv',
    ['Name', 'Container', 'DistinguishedName'],
    members.map(function (m) { return [m.name, m.meta, m.dn]; }));
  toast('Exported ' + members.length + ' members.');
}

/* Type-ahead picker shared by the group and user selectors. */
function wirePicker(searchId, selectId, path) {
  var search = $(searchId);
  var select = $(selectId);
  var timer = null;

  search.addEventListener('input', function () {
    var q = search.value.trim();
    if (timer) { window.clearTimeout(timer); }
    if (q.length < 2) {
      select.innerHTML = '<option value="">Type at least two characters</option>';
      return;
    }
    timer = window.setTimeout(function () {
      api(path + '?q=' + encodeURIComponent(q) + '&limit=50').then(function (data) {
        var items = asArray(data.items);
        if (!items.length) {
          select.innerHTML = '<option value="">No match in the directory</option>';
          return;
        }
        select.innerHTML = items.map(function (i) {
          return '<option value="' + esc(i.sam || i.dn) + '">' + esc(i.name) + ' (' + esc(i.sam) + ')</option>';
        }).join('');
      }).catch(function (err) {
        select.innerHTML = '<option value="">' + esc(err.message) + '</option>';
      });
    }, 250);
  });
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

function wireEvents() {

  // ---- login ----
  $('loginForm').addEventListener('submit', function (e) {
    e.preventDefault();
    var err = $('loginError');
    err.hidden = true;

    var button = $('loginSubmit');
    button.disabled = true;

    api('/api/session', {
      method: 'POST',
      allow401: true,
      body: { username: $('loginUser').value.trim(), password: $('loginPass').value }
    }).then(function (data) {
      button.disabled = false;
      saveToken(data.token);
      applyVersion(data.version, data.publisher);
      applyInsecureBar(data);
      state.user = data.user;
      $('loginPass').value = '';
      enterApp();
    }).catch(function (ex) {
      button.disabled = false;
      err.textContent = ex.message;
      err.hidden = false;
      $('loginPass').select();
    });
  });

  // ---- menu ----
  function setMenu(open) {
    $('menu').hidden = !open;
    $('menuBackdrop').hidden = !open;
    $('menuBtn').setAttribute('aria-expanded', String(open));
  }
  $('menuBtn').addEventListener('click', function () { setMenu($('menu').hidden); });
  $('menuBackdrop').addEventListener('click', function () { setMenu(false); });
  els('.menu-item[data-tab]').forEach(function (b) {
    b.addEventListener('click', function () { setMenu(false); setTab(b.getAttribute('data-tab')); });
  });
  $('menuAbout').addEventListener('click', function () { setMenu(false); actionAbout(); });
  $('menuRefresh').addEventListener('click', function () {
    setMenu(false);
    if (state.tab === 'audit') { loadAudit(); } else { loadRows(); }
    loadDomainInfo();
  });
  $('menuLogoff').addEventListener('click', function () {
    setMenu(false);
    api('/api/session', { method: 'DELETE', allow401: true })
      .catch(function () { /* signing out locally regardless */ })
      .then(function () { signOutLocal(); });
  });

  $('aboutBtn').addEventListener('click', actionAbout);

  // ---- notifications ----
  $('bellBtn').addEventListener('click', function (e) {
    e.stopPropagation();
    if ($('bellPanel').hidden) { openBell(); } else { closeBell(); }
  });

  $('bellList').addEventListener('click', function (e) {
    var button = e.target.closest('[data-note]');
    if (!button) { return; }
    var note = state.notifications[parseInt(button.getAttribute('data-note'), 10)];
    if (note && note.action) { note.action(); }
  });

  document.addEventListener('click', function (e) {
    if ($('bellPanel').hidden) { return; }
    if (e.target.closest('.bell-wrap')) { return; }
    closeBell();
  });

  // ---- tabs ----
  els('.tab').forEach(function (b) {
    b.addEventListener('click', function () { setTab(b.getAttribute('data-tab')); });
  });

  // ---- search (debounced; the query goes to the directory, not a local filter) ----
  var searchTimer = null;
  $('search').addEventListener('input', function () {
    if (searchTimer) { window.clearTimeout(searchTimer); }
    searchTimer = window.setTimeout(function () {
      state.query = $('search').value.trim();
      state.checked = {};
      loadRows();
    }, 350);
  });

  var auditTimer = null;
  $('auditSearch').addEventListener('input', function () {
    if (auditTimer) { window.clearTimeout(auditTimer); }
    auditTimer = window.setTimeout(function () {
      state.auditQuery = $('auditSearch').value.trim();
      loadAudit();
    }, 350);
  });

  $('auditFilters').addEventListener('click', function (e) {
    var chip = e.target.closest('[data-filter]');
    if (!chip) { return; }
    state.auditFilter = chip.getAttribute('data-filter');
    renderAuditFilters();
    loadAudit();
  });

  $('auditRanges').addEventListener('click', function (e) {
    var chip = e.target.closest('[data-range]');
    if (!chip) { return; }

    state.auditRange = chip.getAttribute('data-range');
    renderAuditFilters();

    if (state.auditRange === 'custom') {
      // Seed the pickers with the last 24 hours so the operator adjusts a
      // sensible window instead of starting from two empty fields.
      if (!$('auditFrom').value) { $('auditFrom').value = toLocalInput(new Date(Date.now() - 86400000)); }
      if (!$('auditTo').value)   { $('auditTo').value   = toLocalInput(new Date()); }
      $('auditRangeError').hidden = true;
      $('auditFrom').focus();
      return;   // nothing is applied until Apply range is pressed
    }

    state.auditFrom = null;
    state.auditTo = null;
    loadAudit();
  });

  $('auditApplyRange').addEventListener('click', function () {
    var err = $('auditRangeError');
    var fromValue = $('auditFrom').value;
    var toValue = $('auditTo').value;

    if (!fromValue && !toValue) {
      err.textContent = 'Set a start, an end, or both.';
      err.hidden = false;
      return;
    }
    if (fromValue && toValue && new Date(fromValue) > new Date(toValue)) {
      err.textContent = 'The start of the range is after its end.';
      err.hidden = false;
      return;
    }

    err.hidden = true;
    state.auditFrom = fromValue ? new Date(fromValue).toISOString() : null;
    state.auditTo   = toValue   ? new Date(toValue).toISOString()   : null;
    loadAudit();
  });

  $('auditRefresh').addEventListener('click', function () { loadAudit(); });
  $('auditExport').addEventListener('click', exportAudit);

  // ---- toolbar ----
  $('colsBtn').addEventListener('click', function () {
    $('colPicker').hidden = !$('colPicker').hidden;
    renderColPicker();
  });
  $('colPicker').addEventListener('click', function (e) {
    var chip = e.target.closest('[data-col]');
    if (chip) { toggleCol(chip.getAttribute('data-col')); }
  });
  $('exportBtn').addEventListener('click', exportCurrent);
  $('importBtn').addEventListener('click', actionImportCsv);
  $('createBtn').addEventListener('click', function () {
    if (state.tab === 'groups') { actionCreateGroup(); } else { actionCreateUser(); }
  });

  // ---- table ----
  $('table').addEventListener('click', function (e) {
    var check = e.target.closest('.row-check');
    if (check) {
      e.stopPropagation();
      state.checked[check.getAttribute('data-id')] = check.checked;
      updateBulkBar();
      return;
    }
    if (e.target.id === 'checkAll') {
      var on = e.target.checked;
      state.rows.forEach(function (r) { state.checked[r.id] = on; });
      els('.row-check').forEach(function (c) { c.checked = on; });
      updateBulkBar();
      return;
    }
    // The name button opens the profile. Handled before the row handler so
    // clicking a name does not also re-select and scroll the row.
    var nameBtn = e.target.closest('[data-profile]');
    if (nameBtn) {
      e.stopPropagation();
      openProfile(nameBtn.getAttribute('data-profile'));
      return;
    }

    var tr = e.target.closest('tr[data-id]');
    if (tr) { selectRow(tr.getAttribute('data-id')); }
  });

  // ---- bulk bar ----
  $('bulkBar').addEventListener('click', function (e) {
    var button = e.target.closest('[data-bulk]');
    if (!button) { return; }
    dispatchAction(button.getAttribute('data-bulk'), checkedRows());
  });

  // ---- detail pane ----
  $('detailBody').addEventListener('click', function (e) {
    var member = e.target.closest('[data-member]');
    if (member) {
      if (state.tab === 'groups') {
        actionRemoveMember(member.getAttribute('data-member'));
      } else {
        // On a user, the list is the groups they belong to - remove the user
        // from that group rather than the group from the user.
        removeUserFromGroup(member.getAttribute('data-member'));
      }
      return;
    }
    var button = e.target.closest('[data-action]');
    if (!button) { return; }
    var current = state.rows.filter(function (r) { return r.id === state.selectedId; });
    dispatchAction(button.getAttribute('data-action'), current);
  });

  $('detailClose').addEventListener('click', function () {
    $('detailPane').hidden = true;
    $('detailBackdrop').hidden = true;
  });
  $('detailBackdrop').addEventListener('click', function () {
    $('detailPane').hidden = true;
    $('detailBackdrop').hidden = true;
  });

  // ---- dialog ----
  $('dialogCancel').addEventListener('click', function () {
    var onCancel = dialogState.onCancel;
    closeDialog();
    if (onCancel) { onCancel(); }
  });
  $('dialogConfirm').addEventListener('click', function () {
    if (dialogState.onConfirm) { dialogState.onConfirm(); }
  });
  $('dialogBackdrop').addEventListener('click', function (e) {
    if (e.target === $('dialogBackdrop')) { closeDialog(); }
  });
  $('dialogBody').addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && e.target.tagName === 'INPUT' && e.target.type !== 'file') {
      e.preventDefault();
      if (dialogState.onConfirm) { dialogState.onConfirm(); }
    }
  });

  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') { return; }
    if (!$('dialogBackdrop').hidden) { closeDialog(); return; }
    if (!$('bellPanel').hidden) { closeBell(); return; }
    if (!$('menu').hidden) { setMenu(false); return; }
    if (!$('detailBackdrop').hidden) {
      $('detailPane').hidden = true;
      $('detailBackdrop').hidden = true;
    }
  });

  // Keep the detail pane's docked/slide-over behaviour correct across a resize.
  window.addEventListener('resize', function () {
    if (window.matchMedia('(max-width: 1180px)').matches) { return; }
    $('detailBackdrop').hidden = true;
    if (state.tab !== 'audit') { $('detailPane').hidden = false; }
  });
}

function removeUserFromGroup(groupDn) {
  var user = state.detail;
  openDialog({
    title: 'Remove from group',
    confirmLabel: 'Remove',
    body: '<p class="dialog-note">Removing <strong>' + esc(user.name) + '</strong> from ' +
          esc(groupDn) + '.</p>' + reasonField(),
    onConfirm: function () {
      var reason = readReason();
      if (!reason) { dialogError('A reason is required.'); return; }
      runAction('/api/actions/group-remove', {
        targets: [user.sam || user.dn], group: groupDn, reason: reason
      }, 'Remove from group', refreshAfterWrite);
    }
  });
}

// ---------------------------------------------------------------------------

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot);
} else {
  boot();
}

})();
