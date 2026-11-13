/* SPDX-License-Identifier: GPL-2.0-only
 * GPU Unlock for Unraid: behaviour of the settings page.
 *
 * The server renders the page (include/render.php). This script posts the
 * buttons to include/exec.php, then swaps the content of #gu for a fresh
 * render from include/view.php: after every action, every three seconds
 * while a firmware generation runs, and when the tab comes back into view.
 * A card selection that is not saved yet survives the swap.
 *
 * Everything lives in the gu namespace; the page shares the document with
 * the rest of the WebGUI.
 */
var gu = {
  base: '/plugins/gpu-unlock',
  issues: 'https://github.com/tabilzad/gpu-unlock-unraid/issues/new',
  pollMs: 3000,
  busy: false,       // an action is in flight
  result: null,      // the banner under the header: {tone, title, output, open, link}
  timer: null,
  jobWas: false,     // a firmware generation was running at the last render
  loadedAt: 0,

  // What the banner says when an action succeeded, and when it did not.
  labels: {
    'check': ['Check finished: nothing is missing', 'Check finished: something is missing'],
    'fetch': ['Module fetched', 'Module not fetched'],
    'fetch-pending': ['Module fetched', 'Module not fetched'],
    'firmware': ['Firmware generation started', 'Firmware generation did not start'],
    'enable': ['Unlock enabled for the next boots', 'Not enabled'],
    'disable': ['Unlock switched off for the next boots', 'Not switched off'],
    'hook-install': ['Boot rule installed', 'Boot rule not installed'],
    'targets': ['Selection saved. It applies at the next boot.', 'Selection not saved'],
    'targets-clear': ['Selection cleared', 'Selection not cleared'],
    'diagnostics': ['Report copied to the clipboard', 'Report not available']
  },

  // Safe in text and in attribute context.
  esc: function(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
      return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c];
    });
  },

  view: function() { return $('#gu .gu-view'); },

  /* ------------------------------------------------------- card selection */

  saved: function() { return String(gu.view().attr('data-targets') || ''); },
  locked: function() { return gu.view().attr('data-locked') === '1'; },

  // The selection as the module takes it: "all", or addresses joined by commas.
  picked: function() {
    if ($('#gu-all').is(':checked')) return 'all';
    var list = [];
    $('#gu .gu-pick:checked').each(function() { list.push(this.value); });
    return list.join(',');
  },

  norm: function(t) {
    return t === 'all' ? 'all' : t.split(',').filter(Boolean).sort().join(',');
  },

  dirty: function() {
    return !gu.locked() && $('#gu-save').length > 0 && gu.norm(gu.picked()) !== gu.norm(gu.saved());
  },

  // Put a selection back after the content was swapped.
  apply: function(t) {
    var all = t === 'all', list = all ? [] : t.split(',');
    $('#gu-all').prop('checked', all);
    $('#gu .gu-pick').each(function() {
      this.checked = all || list.indexOf(this.value) >= 0;
    });
  },

  // Boxes, rows, the hint and the Save button follow the selection.
  sync: function() {
    var all = $('#gu-all').is(':checked'), locked = gu.locked();
    $('#gu .gu-pick').each(function() {
      if (all) this.checked = true;
      this.disabled = locked || all;
      $(this).closest('tr').toggleClass('gu-row-on', this.checked);
    });
    var dirty = gu.dirty(), hint = $('#gu-pick-hint');
    $('#gu-save').prop('disabled', !dirty || gu.busy);
    if (locked) {
      hint.text('Set on the kernel command line').attr('data-dirty', '0');
    } else if (dirty) {
      hint.text('Not saved yet').attr('data-dirty', '1');
    } else {
      hint.text(gu.saved() === '' ? 'Nothing chosen yet' : 'Saved. Applies at the next boot.').attr('data-dirty', '0');
    }
  },

  /* ------------------------------------------------------------ rendering */

  renderResult: function() {
    var box = $('#gu-result'), r = gu.result;
    if (!box.length) return;
    if (!r) { box.addClass('gu-hidden').empty(); return; }
    box.attr('data-tone', r.tone).html(
      '<div class="gu-result-body">' +
        '<div class="gu-result-title">' + gu.esc(r.title) + '</div>' +
        (r.output ? '<details class="gu-details"' + (r.open ? ' open' : '') + '><summary>Output</summary><pre class="gu-log">' + gu.esc(r.output) + '</pre></details>' : '') +
        (r.link ? '<a class="gu-link" href="' + gu.esc(r.link) + '" target="_blank" rel="noopener">Open a new issue on GitHub</a>' : '') +
      '</div>' +
      '<a class="gu-link gu-dismiss" href="#" role="button">Dismiss</a>'
    ).removeClass('gu-hidden');
    // The swap rebuilds the banner; keep the Output block as the user left it.
    box.find('details').on('toggle', function() { if (gu.result) gu.result.open = this.open; });
  },

  // Runs after every render: the first one from the server and each swap.
  after: function() {
    gu.sync();
    gu.renderResult();
    var log = document.getElementById('gu-fwlog');
    if (log) log.scrollTop = log.scrollHeight;

    var v = gu.view(), job = v.attr('data-job') === '1';
    if (gu.jobWas && !job) {
      gu.result = v.attr('data-job-rc') === '0'
        ? {tone: 'ok', title: 'Firmware generated', output: '', open: false}
        : {tone: 'bad', title: 'Firmware generation failed', output: 'The log under step 2 says why.', open: true};
      gu.renderResult();
    }
    gu.jobWas = job;
    gu.loadedAt = Date.now();
    clearTimeout(gu.timer);
    if (job) gu.timer = setTimeout(gu.refresh, gu.pollMs);
  },

  // Swap the content for a fresh render. An unsaved selection and the open
  // state of the log blocks carry over.
  refresh: function(done) {
    clearTimeout(gu.timer);
    var failed = function() {
      // Keep what is shown; try again while a generation is being followed.
      if (gu.jobWas) gu.timer = setTimeout(gu.refresh, gu.pollMs);
      if (typeof done === 'function') done(false);
    };
    $.get(gu.base + '/include/view.php', null, null, 'html').done(function(html) {
      // Only the page's own fragment is swapped in: after the WebGUI session
      // expired the answer is the login page.
      if (String(html).indexOf('class="gu-view"') < 0) { failed(); return; }
      var keep = gu.dirty() ? gu.picked() : null, open = {};
      $('#gu details[data-key]').each(function() { open[$(this).attr('data-key')] = this.open; });
      $('#gu').html(html);
      $('#gu details[data-key]').each(function() {
        var k = $(this).attr('data-key');
        if (open.hasOwnProperty(k)) this.open = open[k];
      });
      if (keep !== null) gu.apply(keep);
      if (gu.busy) $('#gu').addClass('gu-busy');
      gu.after();
      if (typeof done === 'function') done(true);
    }).fail(failed);
  },

  /* -------------------------------------------------------------- actions */

  act: function(action, data, button) {
    if (gu.busy) return;
    gu.busy = true;
    $('#gu').addClass('gu-busy');
    if (button) $(button).addClass('gu-btn-working').attr('aria-busy', 'true');
    $('#gu-save').prop('disabled', true);
    var post = $.extend({action: action, csrf_token: (typeof csrf_token === 'undefined' ? '' : csrf_token)}, data || {});
    $.post(gu.base + '/include/exec.php', post, null, 'json').done(function(r) {
      gu.finish(action, r || {});
    }).fail(function(xhr) {
      var r = xhr.responseJSON;
      if (!r) {
        try { r = JSON.parse(xhr.responseText); } catch (e) { r = null; }
      }
      gu.finish(action, r || {ok: false, error: 'The request failed' + (xhr.status ? ' (HTTP ' + xhr.status + ')' : '') + '. Reload the page and try again.'});
    });
  },

  finish: function(action, r) {
    var names = gu.labels[action] || [action, action], ok = !!r.ok;
    var out = String(r.output || r.error || '');
    var settle = function() {
      gu.busy = false;
      $('#gu').removeClass('gu-busy');
      $('#gu .gu-btn-working').removeClass('gu-btn-working').removeAttr('aria-busy');
      gu.sync();
    };
    // "check" exits 1 when it found something to do; that is a finding, not an error.
    gu.result = {tone: ok ? 'ok' : (action === 'check' ? 'warn' : 'bad'), title: ok ? names[0] : names[1], output: out, open: !ok};
    if (action === 'diagnostics' && ok) {
      gu.copy('```text\n' + out + '\n```\n', function(copied) {
        gu.result = {
          tone: copied ? 'ok' : 'info',
          title: copied ? names[0] : 'Report: select the text below and copy it',
          output: out, open: !copied, link: gu.issues
        };
        settle();
        gu.renderResult();
      });
      return;
    }
    // A generation can be over before the first look at it (no Docker
    // service, say): count it as seen running, so its outcome is reported.
    if (action === 'firmware' && ok) gu.jobWas = true;
    gu.refresh(function(swapped) {
      settle();
      // Without a fresh render the banner still has to say what happened.
      if (!swapped) gu.renderResult();
    });
  },

  // navigator.clipboard needs https; the WebGUI is often plain http on the LAN.
  copy: function(text, cb) {
    var fallback = function() {
      var ta = document.createElement('textarea'), ok = false;
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.top = '-1000px';
      document.body.appendChild(ta);
      ta.select();
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(ta);
      cb(ok);
    };
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function() { cb(true); }, fallback);
    } else {
      fallback();
    }
  }
};

$(function() {
  var root = $('#gu');
  if (!root.length) return;

  root.on('click', '[data-action]', function(e) {
    e.preventDefault();
    var action = $(this).attr('data-action');
    if (action === 'save-targets') {
      var t = gu.picked();
      if (t === '') gu.act('targets-clear', null, this); else gu.act('targets', {targets: t}, this);
      return;
    }
    gu.act(action, null, this);
  });
  root.on('click', '[data-refresh]', function() { gu.refresh(); });
  root.on('change', '.gu-pick, #gu-all', gu.sync);
  // A click anywhere on a supported card's row ticks it.
  root.on('click', 'tr.gu-row', function(e) {
    if ($(e.target).closest('input, a, button, label').length) return;
    var box = $(this).find('.gu-pick')[0];
    if (!box || box.disabled) return;
    box.checked = !box.checked;
    gu.sync();
  });
  root.on('click', '.gu-dismiss', function(e) {
    e.preventDefault();
    gu.result = null;
    gu.renderResult();
  });
  // Coming back to the tab after a while: show the current state.
  document.addEventListener('visibilitychange', function() {
    if (!document.hidden && !gu.busy && !gu.jobWas && Date.now() - gu.loadedAt > 30000) gu.refresh();
  });

  gu.after();
});
