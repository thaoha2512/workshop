// Shared helpers: the Supabase connection, login checks, the top bar, and sharing.
(function () {
  const cfg = window.POLAROID_CONFIG || {};
  const configured = Boolean(cfg.url && cfg.anonKey && !cfg.anonKey.startsWith('PASTE_'));
  const sb = configured ? window.supabase.createClient(cfg.url, cfg.anonKey) : null;

  function showBanner(text) {
    const p = document.createElement('p');
    p.className = 'banner';
    p.setAttribute('role', 'alert');
    p.textContent = text;
    document.body.prepend(p);
  }

  if (!configured) {
    document.addEventListener('DOMContentLoaded', () =>
      showBanner('Supabase isn\'t connected yet. Add your public key to polaroid/config.js.'));
  }

  // Only allow going back to one of our own pages after logging in.
  function safeNext(value) {
    return /^(index|editor)\.html(\?[\w=&-]*)?$/.test(value || '') ? value : 'index.html';
  }

  // Send visitors who aren't logged in to the login screen, then bring them back here.
  async function requireUser() {
    if (!sb) return new Promise(() => {});
    const { data: { session } } = await sb.auth.getSession();
    if (!session) {
      const here = location.pathname.split('/').pop() || 'index.html';
      location.replace('login.html?next=' + encodeURIComponent(here + location.search));
      return new Promise(() => {});  // stop the page while it leaves
    }
    initHeader(session.user);
    return session.user;
  }

  function initHeader(user) {
    const who = document.getElementById('who');
    if (who) who.textContent = user.email;
    const out = document.getElementById('logout');
    if (out) out.addEventListener('click', async () => {
      await sb.auth.signOut();
      location.replace('login.html');
    });
  }

  function shareUrl(token) {
    return new URL('view.html?s=' + token, location.href).href;
  }

  // Turn sharing on: give the polaroid a secret token and publish a copy of the finished image.
  async function shareOn(row) {
    const token = crypto.randomUUID();
    const { data: file, error: dlErr } = await sb.storage.from('photos').download(row.render_path);
    if (dlErr) throw dlErr;
    let { error } = await sb.from('polaroids').update({ share_token: token }).eq('id', row.id);
    if (error) throw error;
    ({ error } = await sb.storage.from('shared')
      .upload(token + '.png', file, { contentType: 'image/png', upsert: true, cacheControl: '60' }));
    if (error) {
      await sb.from('polaroids').update({ share_token: null }).eq('id', row.id);
      throw error;
    }
    row.share_token = token;
    return token;
  }

  // Turn sharing off: remove the public copy, then forget the token so the old link stops working.
  async function shareOff(row) {
    if (!row.share_token) return;
    await sb.storage.from('shared').remove([row.share_token + '.png']);
    const { error } = await sb.from('polaroids').update({ share_token: null }).eq('id', row.id);
    if (error) throw error;
    row.share_token = null;
  }

  // Replace the public copy after an edit, so viewers see the latest version.
  async function refreshSharedCopy(row, pngBlob) {
    if (!row.share_token) return;
    const { error } = await sb.storage.from('shared')
      .upload(row.share_token + '.png', pngBlob, { contentType: 'image/png', upsert: true, cacheControl: '60' });
    if (error) throw error;
  }

  async function copyText(text, button) {
    const label = button.textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = 'Copied';
    } catch (e) {
      window.prompt('Copy this link:', text);
    }
    setTimeout(() => { button.textContent = label; }, 1500);
  }

  function friendlyError(err) {
    const m = (err && (err.message || err.error_description)) || String(err);
    if (/fetch/i.test(m)) return 'Couldn\'t reach Supabase. Check your internet connection and try again.';
    return m;
  }

  window.App = {
    sb, configured, requireUser, safeNext, shareUrl, shareOn, shareOff,
    refreshSharedCopy, copyText, friendlyError, showBanner,
  };
})();
