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
  busy: 0
};

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

var AUDIT_FILTERS = ['All', 'Users', 'Groups', 'Passwords', 'Deletions'];

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

  busy(true);
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
    busy(false);
    return data;
  }, function (err) {
    busy(false);
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

    var count = data.domain.controllerCount;
    $('menuDomain').textContent = data.domain.domain + ' - ' + count +
                                  ' controller' + (count === 1 ? '' : 's');
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

function buildNotifications() {
  var list = [];
  var storage = state.storage;

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

  $('directoryView').hidden = (isAudit || isSettings);
  $('auditView').hidden     = !isAudit;
  $('settingsView').hidden  = !isSettings;

  // The detail pane belongs to the directory views only.
  $('detailPane').hidden = (isAudit || isSettings);
  closeDetail();

  if (isSettings) {
    loadSettings();
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

  renderColPicker();
  loadRows();
}

// ---------------------------------------------------------------------------
// Directory list
// ---------------------------------------------------------------------------

function loadRows() {
  var tab = state.tab;
  var path = (tab === 'groups' ? '/api/groups' : '/api/users');
  if (state.query) { path += '?q=' + encodeURIComponent(state.query); }

  state.loadError = '';
  api(path).then(function (data) {
    if (state.tab !== tab) { return; }
    state.rows = asArray(data.items);
    state.limit = data.limit;
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
      return '<td class="' + cls + '" data-label="' + esc(c.label) + '">' + esc(text) + '</td>';
    }).join('');

    return '<tr data-id="' + esc(row.id) + '" aria-selected="' + selected + '">' +
           '<td class="col-check" data-label="Select">' +
           '<input type="checkbox" class="check row-check" data-id="' + esc(row.id) + '"' + checked + '></td>' +
           cells + '</tr>';
  }).join('');

  var noun = (state.tab === 'groups' ? 'groups' : 'users');
  var line = state.rows.length + ' ' + noun + ' from ' + (state.domainInfo ? state.domainInfo.domain : 'the directory');

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

  api(path).then(function (data) {
    state.auditRows = asArray(data.items);
    state.auditTotal = data.total || 0;
    state.auditSource = data.source || '';
    renderAudit();
  }).catch(function (err) {
    state.auditRows = [];
    state.auditTotal = 0;
    $('auditBody').innerHTML = '';
    $('auditLine').textContent = '';
    renderAudit();
    toast('Could not read the audit log: ' + err.message, 'bad');
  });
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

    $('auditBody').innerHTML = '<tr><td colspan="7" data-label="">' +
      '<span class="muted-sm">' + esc(scope) + '. Entries are written here as changes are made.</span>' +
      '</td></tr>';
    $('auditLine').textContent = '';
    return;
  }

  $('auditBody').innerHTML = state.auditRows.map(function (r) {
    var cls = (r.result === 'Success') ? 'res-success' : 'res-other';
    return '<tr>' +
      '<td data-label="Time" class="cell-muted">' + esc(formatStamp(r.time)) + '</td>' +
      '<td data-label="Action" class="cell-name">' + esc(r.action) + '</td>' +
      '<td data-label="Target">' + esc(r.target) + '</td>' +
      '<td data-label="Operator" class="cell-muted">' + esc(r.operator) + '</td>' +
      '<td data-label="Controller" class="cell-disabled">' + esc(r.dc) + '</td>' +
      '<td data-label="Reason" class="cell-muted cell-wrap">' + esc(r.reason) + '</td>' +
      '<td data-label="Result" class="' + cls + '">' + esc(r.result) + '</td>' +
      '</tr>';
  }).join('');

  var line = state.auditRows.length + ' of ' + state.auditTotal + ' entries in ' + windowLabel() +
             ' - written by this console, newest first';
  if (state.auditSource === 'sql') { line += ' - stored in SQL Server'; }
  else if (state.auditSource === 'file') { line += ' - stored in files on the server (no SQL configured)'; }
  $('auditLine').textContent = line;
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
          'It is shown once and is not written to the audit log - copy it now and hand it over securely.</p>' +
          '<div class="secret">' + esc(password) + '</div>'
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
    title: 'Reset password - ' + rows.map(function (r) { return r.name; }).join(', '),
    confirmLabel: 'Reset',
    body: '<p class="dialog-note">The new password is written to the directory and the change is ' +
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

function actionSimple(kind, rows) {
  var config = {
    'unlock':  { path: '/api/actions/unlock', title: 'Unlock account', label: 'Unlock', extra: {} },
    'enable':  { path: '/api/actions/set-enabled', title: 'Enable account', label: 'Enable', extra: { enabled: true } },
    'disable': { path: '/api/actions/set-enabled', title: 'Disable account', label: 'Disable', extra: { enabled: false } }
  }[kind];

  openDialog({
    title: config.title + ' - ' + rows.length + ' object' + (rows.length === 1 ? '' : 's'),
    confirmLabel: config.label,
    body: '<p class="dialog-note">This change is written to the directory and recorded in the audit log ' +
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
      title: 'Move OU - ' + rows.length + ' object' + (rows.length === 1 ? '' : 's'),
      confirmLabel: 'Move',
      body: '<p class="dialog-note">Moving replicates to every domain controller.</p>' +
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
    title: 'Add to group - ' + rows.length + ' user' + (rows.length === 1 ? '' : 's'),
    confirmLabel: 'Add',
    body: '<div class="field"><label for="dlgGroupSearch">Find the group</label>' +
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

function actionImportCsv() {
  withOus(function () {
    openDialog({
      title: 'Bulk CSV import',
      confirmLabel: 'Import',
      body: '<p class="dialog-note">Header row required. Recognised columns: ' +
            '<strong>SamAccountName</strong> (required), DisplayName, GivenName, Surname, ' +
            'Department, Title, Password, OU. A row without a Password gets a generated one; ' +
            'a row without an OU uses the OU chosen here.</p>' +
            '<div class="field"><label for="dlgFile">CSV file</label>' +
            '<input class="input" id="dlgFile" type="file" accept=".csv,text/csv"></div>' +
            '<div class="field"><label for="dlgCsv">or paste the CSV</label>' +
            '<textarea class="input" id="dlgCsv" placeholder="SamAccountName,DisplayName,Department"></textarea></div>' +
            ouSelect(null) + reasonField(),
      onOpen: function () {
        $('dlgFile').addEventListener('change', function (e) {
          var file = e.target.files && e.target.files[0];
          if (!file) { return; }
          var reader = new FileReader();
          reader.onload = function () { $('dlgCsv').value = String(reader.result); };
          reader.readAsText(file);
        });
      },
      onConfirm: function () {
        var reason = readReason();
        var csv = $('dlgCsv').value.trim();
        if (!csv) { dialogError('Choose a file or paste the CSV.'); return; }
        if (!reason) { dialogError('A reason is required.'); return; }
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
  $('settingsBody').innerHTML = '<p class="muted-sm">Loading...</p>';

  api('/api/settings').then(function (data) {
    state.settings = data.settings;
    renderSettings();
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

  var storage = s.sqlEnabled
    ? '<p class="set-good">Connected to <strong>' + esc(s.sqlServer) + '</strong>, database ' +
      '<strong>' + esc(s.sqlDatabase) + '</strong>. Operators, sessions, the directory snapshot and ' +
      'the audit log are stored there.</p>'
    : '<p class="set-warn"><strong>No database is configured.</strong> The audit log is written to ' +
      'files under the data folder, and operators, sessions and the directory snapshot are ' +
      '<strong>not stored at all</strong>.</p>';

  if (s.sqlError) {
    storage += '<div class="error-box"><strong>The last SQL attempt failed with:</strong>' +
               esc(s.sqlError) + '</div>';
  }

  $('settingsBody').innerHTML =
    // ---- system ----
    '<section class="set-card">' +
      '<h2 class="set-h">System</h2>' +
      '<dl class="detail-fields">' +
        settingsRow('Version', s.version) +
        settingsRow('Published by', s.publisher) +
        settingsRow('Domain', s.domain) +
        settingsRow('Domain controller', s.server || 'Auto-discovered') +
        settingsRow('Listening on', s.listenAddress + ':' + s.port) +
        settingsRow('Search result cap', String(s.pageSize)) +
        settingsRow('Data folder', s.dataPath) +
      '</dl>' +
    '</section>' +

    // ---- SQL ----
    '<section class="set-card">' +
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
      '<p class="dialog-note">The database and its tables are created if they do not exist, and the ' +
      'setting is saved so it survives a restart. Creating a database needs the <code>dbcreator</code> ' +
      'right on the instance; using one that already exists needs only read and write.</p>' +
      '<div class="set-actions">' +
        '<button class="btn btn-primary" type="button" id="applySql">' +
        (s.sqlEnabled ? 'Reconnect' : 'Connect and create database') + '</button>' +
      '</div>' +
      '<div class="set-result" id="sqlResult"></div>' +
    '</section>' +

    // ---- identity ----
    '<section class="set-card">' +
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
      '<div class="set-result" id="identityResult"></div>' +
    '</section>' +

    // ---- service account ----
    '<section class="set-card">' +
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
      'verifies the account before touching anything.</p>' +
    '</section>' +

    // ---- sessions ----
    '<section class="set-card">' +
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
      '<div class="set-result" id="idleResult"></div>' +
    '</section>';

  wireSettings(bounds);
}

function accountKindLabel(kind) {
  if (kind === 'gmsa') { return 'Group managed service account (no password)'; }
  if (kind === 'machine') { return 'Machine account (LocalSystem)'; }
  if (kind === 'user') { return 'Ordinary account'; }
  return '';
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

  // ---- SQL ----
  $('applySql').addEventListener('click', function () {
    var server = $('setSqlServer').value.trim();
    if (!server) { setResult('sqlResult', 'Enter the SQL Server instance.', false); return; }

    setResult('sqlResult', 'Connecting to ' + server + '...', true);

    api('/api/settings/sql', {
      method: 'POST',
      body: {
        server: server,
        database: $('setSqlDb').value.trim() || 'DSMT',
        username: $('setSqlUser').value.trim(),
        password: $('setSqlPass').value
      }
    }).then(function (res) {
      state.storage = res.storage;
      renderNotifications();
      var message = 'Connected. Database ' + res.storage.sqlDatabase + ' on ' +
                    res.storage.sqlServer + ' is ready.';
      if (!res.persisted) {
        message += ' NOTE: the setting could not be saved (' + res.persistError +
                   '), so it will be lost on restart.';
      }
      setResult('sqlResult', message, true);
      loadSettings();
    }).catch(function (err) {
      // The server returns the real SQL error - show it verbatim, it is the
      // whole point of this control.
      setResult('sqlResult', err.message, false);
    });
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

  $('copyAcctCmd').addEventListener('click', function () {
    var text = $('acctCmd').textContent;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () {
        toast('Command copied.');
      }).catch(function () { selectCommand(); });
    } else {
      selectCommand();
    }
  });

  function selectCommand() {
    // Clipboard API needs a secure context; over plain HTTP it is absent, so
    // fall back to selecting the text for the operator to copy.
    var node = $('acctCmd');
    if (window.getSelection && document.createRange) {
      var range = document.createRange();
      range.selectNodeContents(node);
      var sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    }
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
