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
  storage: null,
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
  clearToken();
  state.user = null;
  showLogin();
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

function applyVersion(version) {
  if (!version) { return; }
  state.version = version;
  var badge = $('loginVersion');
  if (badge) { badge.textContent = 'v' + version; }
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

function boot() {
  wireEvents();

  api('/api/meta', { allow401: true }).then(function (meta) {
    if (meta) {
      applyVersion(meta.version);
      state.storage = meta.storage || null;
      state.domain = meta.domain || '';
      var dom = $('loginDomain');
      if (dom && state.domain) { dom.textContent = state.domain; }
    }
  }).catch(function () { /* the login form still works */ });

  var token = loadToken();
  if (!token) { showLogin(); return; }

  state.token = token;
  api('/api/session', { allow401: true }).then(function (data) {
    if (!data || !data.ok) { signOutLocal(); return; }
    applyVersion(data.version);
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
}

function paintIdentity() {
  if (!state.user) { return; }
  var initials = (state.user.display || state.user.sam || '')
    .split(/\s+/).filter(Boolean).slice(0, 2)
    .map(function (p) { return p.charAt(0).toUpperCase(); }).join('');
  var avatar = $('avatar');
  avatar.textContent = initials || 'AD';
  avatar.title = state.user.account || '';
  $('menuSignedIn').textContent = 'Signed in as ' + (state.user.account || state.user.sam);
}

function loadDomainInfo() {
  api('/api/domain').then(function (data) {
    state.domainInfo = data.domain;
    var count = data.domain.controllerCount;
    var line = data.domain.domain + ' - ' + count + ' controller' + (count === 1 ? '' : 's');
    $('domainLine').textContent = line;
    $('menuDomain').textContent = line;
  }).catch(function (err) {
    $('domainLine').textContent = 'Domain unavailable';
    toast('Could not read the domain: ' + err.message, 'bad');
  });
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

  var isAudit = (tab === 'audit');
  $('directoryView').hidden = isAudit;
  $('auditView').hidden = !isAudit;
  closeDetail();

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
  if (state.limit && state.rows.length >= state.limit) {
    line += ' - result limit of ' + state.limit + ' reached, narrow the search to see the rest';
  }
  $('resultLine').textContent = line;

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
}

function loadAudit() {
  var path = '/api/audit?filter=' + encodeURIComponent(state.auditFilter);
  if (state.auditQuery) { path += '&q=' + encodeURIComponent(state.auditQuery); }

  api(path).then(function (data) {
    state.auditRows = asArray(data.items);
    state.auditTotal = data.total || 0;
    renderAudit();
  }).catch(function (err) {
    state.auditRows = [];
    $('auditBody').innerHTML = '';
    $('auditLine').textContent = '';
    toast('Could not read the audit log: ' + err.message, 'bad');
  });
}

function renderAudit() {
  if (!state.auditRows.length) {
    $('auditBody').innerHTML = '<tr><td colspan="7" data-label="">' +
      '<span class="muted-sm">No audit entries match. Entries are written here as changes are made.</span>' +
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

  $('auditLine').textContent = state.auditRows.length + ' of ' + state.auditTotal +
    ' entries - written by this console, newest first';
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

var dialogState = { onConfirm: null };

function openDialog(config) {
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

function actionAbout() {
  var d = state.domainInfo;
  var controllers = d ? asArray(d.controllers) : [];

  var rows = [
    ['Version', state.version],
    ['Signed in as', state.user ? state.user.account : ''],
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
          'the server, surfaced through /api/meta.</p>'
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
      applyVersion(data.version);
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
  $('dialogCancel').addEventListener('click', closeDialog);
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
