<script setup>
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue';
import Icon from './Icon.vue';

const base = location.pathname.endsWith('/') ? location.pathname : `${location.pathname}/`;
const page = ref('overview');
const mobileMenuOpen = ref(false);
const loading = ref(true);
const refreshing = ref(false);
const saving = ref(false);
const creating = ref(false);
const removing = ref(false);
const state = reactive({ hosts: 0, phones: 0, publicWss: '', keys: [], legacyKey: false });
const wssDraft = ref('');
const wssEdited = ref(false);
const keyName = ref('');
const customKey = ref('');
const showCustomKey = ref(false);
const createdToken = ref('');
const createdName = ref('');
const keyToRemove = ref(null);
const error = ref('');
const toast = ref('');
let refreshTimer;
let toastTimer;

const nav = [
  { id: 'overview', label: '概览', icon: 'grid' },
  { id: 'connection', label: '连接配置', icon: 'link' },
  { id: 'keys', label: '连接密钥', icon: 'key' },
  { id: 'guide', label: '使用说明', icon: 'guide' },
];
const navTitle = computed(() => nav.find((item) => item.id === page.value)?.label || '概览');
const totalKeys = computed(() => state.keys.length + (state.legacyKey ? 1 : 0));
const wssUnchanged = computed(() => wssDraft.value.trim() === state.publicWss);

function showToast(text) {
  toast.value = text;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toast.value = ''; }, 3500);
}

async function api(route, options = {}) {
  const response = await fetch(`${base}api/${route}`, {
    method: options.method || 'GET',
    cache: 'no-store',
    credentials: 'same-origin',
    headers: {
      ...(options.method ? { 'X-AstroGate-Admin': '1' } : {}),
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  let result;
  try { result = await response.json(); }
  catch { throw new Error(`服务返回了异常内容（${response.status}）`); }
  if (!response.ok) throw new Error(result.error || `请求失败（${response.status}）`);
  return result;
}

async function refresh(silent = false) {
  if (!silent) refreshing.value = true;
  try {
    const next = await api('state');
    state.hosts = next.hosts;
    state.phones = next.phones;
    state.publicWss = next.publicWss;
    state.keys = next.keys;
    state.legacyKey = next.legacyKey;
    if (!wssEdited.value) wssDraft.value = next.publicWss;
    error.value = '';
  } catch (cause) {
    error.value = cause.message || '无法连接中转服务';
  } finally {
    loading.value = false;
    refreshing.value = false;
  }
}

function navigate(id) {
  page.value = id;
  mobileMenuOpen.value = false;
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

async function copy(text, label) {
  try {
    await navigator.clipboard.writeText(text);
    showToast(`${label}已复制`);
  } catch {
    error.value = '浏览器未允许复制，请选中文本后手动复制';
  }
}

async function saveWss() {
  if (saving.value) return;
  saving.value = true;
  try {
    const result = await api('public-wss', { method: 'POST', body: { publicWss: wssDraft.value.trim() } });
    state.publicWss = result.publicWss;
    wssDraft.value = result.publicWss;
    wssEdited.value = false;
    error.value = '';
    showToast('连接地址已保存');
  } catch (cause) { error.value = cause.message; }
  finally { saving.value = false; }
}

async function createKey() {
  if (creating.value) return;
  if (!keyName.value.trim()) { error.value = '请先填写密钥名称'; return; }
  creating.value = true;
  try {
    const result = await api('keys', { method: 'POST', body: {
      name: keyName.value.trim(),
      ...(customKey.value ? { token: customKey.value } : {}),
    } });
    createdToken.value = result.token;
    createdName.value = result.name;
    keyName.value = '';
    customKey.value = '';
    showCustomKey.value = false;
    error.value = '';
    await refresh(true);
  } catch (cause) { error.value = cause.message; }
  finally { creating.value = false; }
}

function closeCreatedToken() {
  createdToken.value = '';
  createdName.value = '';
}

async function revokeKey() {
  if (!keyToRemove.value || removing.value) return;
  removing.value = true;
  try {
    await api(`keys/${keyToRemove.value.id}`, { method: 'DELETE' });
    keyToRemove.value = null;
    error.value = '';
    showToast('连接密钥已停用');
    await refresh(true);
  } catch (cause) { error.value = cause.message; }
  finally { removing.value = false; }
}

function formatDate(iso) {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString('zh-CN', { dateStyle: 'medium', timeStyle: 'short' });
}

onMounted(() => {
  refresh();
  refreshTimer = setInterval(() => { if (!document.hidden) refresh(true); }, 15000);
});
onUnmounted(() => { clearInterval(refreshTimer); clearTimeout(toastTimer); });
</script>

<template>
  <div class="app-shell">
    <aside class="sidebar" :class="{ 'sidebar-open': mobileMenuOpen }">
      <div class="brand"><div class="brand-mark"><span>✦</span></div><div><strong>AstroGate</strong><small>RELAY CONSOLE</small></div></div>
      <div class="side-caption">工作空间</div>
      <nav class="side-nav" aria-label="控制台导航">
        <button v-for="item in nav" :key="item.id" type="button" class="nav-item" :class="{ active: page === item.id }" @click="navigate(item.id)">
          <Icon :name="item.icon" :size="19" /><span>{{ item.label }}</span><Icon v-if="page === item.id" name="chevron" :size="16" class="nav-chevron" />
        </button>
      </nav>
      <div class="sidebar-foot"><div class="foot-icon"><Icon name="shield" :size="17" /></div><div><strong>安全连接</strong><small>管理操作需验证身份</small></div></div>
    </aside>

    <div v-if="mobileMenuOpen" class="mobile-scrim" @click="mobileMenuOpen = false"></div>
    <main class="main-panel">
      <header class="topbar">
        <div class="topbar-left"><button class="mobile-menu icon-button" type="button" aria-label="打开导航" @click="mobileMenuOpen = true"><span class="menu-lines">☰</span></button><span class="breadcrumb">工作台</span><Icon name="chevron" :size="14" class="breadcrumb-arrow" /><strong>{{ navTitle }}</strong></div>
        <div class="topbar-right"><span class="server-status" :class="{ offline: !!error }"><i></i>{{ error ? '连接异常' : '中转运行中' }}</span><button class="icon-button" type="button" :disabled="refreshing" aria-label="刷新数据" title="刷新数据" @click="refresh()"><Icon name="refresh" :size="18" :class="{ spin: refreshing }" /></button></div>
      </header>

      <div class="content">
        <div v-if="error" class="error-banner" role="alert"><Icon name="alert" :size="19"/><span>{{ error }}</span><button type="button" aria-label="关闭提示" @click="error = ''"><Icon name="close" :size="17"/></button></div>

        <template v-if="page === 'overview'">
          <div class="page-head"><div><div class="eyebrow">DASHBOARD / OVERVIEW</div><h1>中转概览</h1><p>查看当前连接状态，并管理设备接入方式。</p></div><button class="button button-quiet" type="button" @click="refresh()"><Icon name="refresh" :size="17"/>刷新数据</button></div>
          <div class="metrics-grid">
            <div class="metric-card"><div class="metric-top"><span>在线电脑</span><span class="metric-icon blue"><Icon name="monitor" :size="22"/></span></div><strong class="metric-number">{{ loading ? '—' : state.hosts }}</strong><div class="metric-foot"><span class="status-dot"></span>当前连接到中转的电脑</div></div>
            <div class="metric-card"><div class="metric-top"><span>在线手机</span><span class="metric-icon purple"><Icon name="phone" :size="22"/></span></div><strong class="metric-number">{{ loading ? '—' : state.phones }}</strong><div class="metric-foot"><span class="status-dot"></span>当前连接到中转的手机</div></div>
            <div class="metric-card"><div class="metric-top"><span>连接密钥</span><span class="metric-icon teal"><Icon name="key" :size="22"/></span></div><strong class="metric-number">{{ loading ? '—' : totalKeys }}</strong><div class="metric-foot">含原有兼容密钥</div></div>
          </div>
          <div class="overview-grid">
            <section class="panel endpoint-panel"><div class="section-head"><div><div class="section-kicker">连接入口</div><h2>WSS 中转地址</h2></div><span class="outline-pill">TLS 加密</span></div><p>当前提供给客户端的服务器地址</p><div class="code-line"><code>{{ state.publicWss || '读取中…' }}</code><button type="button" class="copy-button" aria-label="复制 WSS 地址" @click="copy(state.publicWss, '连接地址')"><Icon name="copy" :size="17"/></button></div><button class="text-link" type="button" @click="navigate('connection')">管理连接地址<Icon name="arrow" :size="16"/></button></section>
            <section class="panel quick-panel"><div class="section-head"><div><div class="section-kicker">快速开始</div><h2>设备配对</h2></div><div class="round-accent"><Icon name="link" :size="20"/></div></div><p>Windows 私有安装包已预置本站连接配置。安装后打开程序即可生成配对码，由手机扫描完成绑定。</p><button class="text-link" type="button" @click="navigate('guide')">查看操作说明<Icon name="arrow" :size="16"/></button></section>
          </div>
          <section class="panel recent-panel"><div class="section-head"><div><div class="section-kicker">ACCESS KEYS</div><h2>连接密钥</h2></div><button class="button button-subtle" type="button" @click="navigate('keys')">管理密钥<Icon name="arrow" :size="16"/></button></div><p>为不同电脑分别创建密钥，以便独立管理。</p><div class="recent-list"><div class="recent-item"><div class="recent-icon"><Icon name="shield" :size="18"/></div><span>原有兼容密钥</span><span class="active-tag">有效</span></div><div v-for="key in state.keys.slice(0, 3)" :key="key.id" class="recent-item"><div class="recent-icon"><Icon name="key" :size="18"/></div><span>{{ key.name }}</span><time>{{ formatDate(key.createdAt) }}</time></div></div></section>
        </template>

        <template v-else-if="page === 'connection'">
          <div class="page-head"><div><div class="eyebrow">SETTINGS / CONNECTION</div><h1>连接配置</h1><p>管理客户端使用的公开 WSS 地址。</p></div></div>
          <section class="panel form-panel"><div class="section-head"><div class="section-kicker">PUBLIC ENDPOINT</div><span class="outline-pill">已启用</span></div><h2>中转地址</h2><p>此地址用于客户端连接。更改这里会更新后台提供的地址；域名、证书与反向代理需在服务器同步配置。</p><label for="wss-address">公开 WSS 地址</label><div class="field-row"><div class="field-icon"><Icon name="link" :size="18"/></div><input id="wss-address" v-model="wssDraft" type="url" autocomplete="off" spellcheck="false" placeholder="wss://example.com/ifile-connect" @input="wssEdited = true"/><button type="button" class="field-copy" title="复制当前地址" aria-label="复制当前地址" @click="copy(state.publicWss, '连接地址')"><Icon name="copy" :size="18"/></button></div><div class="form-actions"><button class="button button-primary" type="button" :disabled="saving || wssUnchanged" @click="saveWss">{{ saving ? '保存中…' : '保存更改' }}</button><span>当前：{{ state.publicWss || '读取中…' }}</span></div></section>
          <div class="info-callout"><Icon name="info" :size="20"/><p>Windows 私有安装包可预置本站地址和独立连接密钥。公开分享安装包前，请确认其中没有私有配置。</p></div>
        </template>

        <template v-else-if="page === 'keys'">
          <div class="page-head"><div><div class="eyebrow">SECURITY / ACCESS KEYS</div><h1>连接密钥</h1><p>给每台电脑分配独立密钥，并随时停用。</p></div><span class="count-pill">{{ totalKeys }} 个有效密钥</span></div>
          <div class="keys-layout"><section class="panel key-list-panel"><div class="section-head"><div><div class="section-kicker">ACTIVE KEYS</div><h2>当前有效</h2></div></div><div class="key-list"><div class="key-row"><div class="key-avatar legacy"><Icon name="shield" :size="19"/></div><div class="key-main"><strong>原有兼容密钥</strong><small>用于已经配置的电脑</small></div><span class="active-tag">有效</span></div><div v-for="key in state.keys" :key="key.id" class="key-row"><div class="key-avatar"><Icon name="key" :size="19"/></div><div class="key-main"><strong>{{ key.name }}</strong><small>创建于 {{ formatDate(key.createdAt) }}</small></div><button class="icon-button danger-button" type="button" :aria-label="`停用 ${key.name}`" :title="`停用 ${key.name}`" @click="keyToRemove = key"><Icon name="trash" :size="18"/></button></div></div><div v-if="state.keys.length === 0" class="empty-note">尚未创建独立密钥。原有密钥仍可使用。</div></section>
          <section class="panel create-panel"><div class="section-kicker">CREATE KEY</div><h2>创建新密钥</h2><p>为一台电脑创建专用密钥。自动生成的密钥只会显示一次，请立即妥善保存。</p><label for="key-name">密钥名称</label><input id="key-name" v-model="keyName" maxlength="50" autocomplete="off" placeholder="例如：办公室电脑" @keyup.enter="createKey"/><button class="advanced-toggle" type="button" @click="showCustomKey = !showCustomKey"><Icon :name="showCustomKey ? 'eyeoff' : 'eye'" :size="17"/>{{ showCustomKey ? '隐藏自定义密钥' : '使用自定义密钥（可选）' }}</button><div v-if="showCustomKey" class="advanced-field"><label for="custom-key">自定义连接密钥</label><input id="custom-key" v-model="customKey" type="password" autocomplete="new-password" placeholder="至少 32 个字符；留空则自动生成"/><small>建议使用自动生成的高强度密钥。</small></div><button class="button button-primary create-submit" type="button" :disabled="creating" @click="createKey"><Icon name="plus" :size="18"/>{{ creating ? '生成中…' : '生成连接密钥' }}</button></section></div>
          <div class="info-callout"><Icon name="info" :size="20"/><p>停用密钥后，使用它的电脑在下次重连时会被拒绝。原有兼容密钥继续有效，已配置电脑无需重新配对。</p></div>
        </template>

        <template v-else>
          <div class="page-head"><div><div class="eyebrow">SUPPORT / GET STARTED</div><h1>使用说明</h1><p>按下面的步骤让手机连接到电脑。</p></div></div>
          <section class="panel guide-panel"><div class="guide-step"><span>01</span><div><h2>安装 Windows 连接程序</h2><p>解压私有安装包，双击“安装 AstroGate Connect.cmd”。包内已配置本站中转地址和连接密钥，无需手动填写。</p></div></div><div class="guide-step"><span>02</span><div><h2>打开并生成配对码</h2><p>连接程序启动后显示配对二维码。手机在“连接”页面扫描二维码，确认绑定电脑。</p></div></div><div class="guide-step"><span>03</span><div><h2>查看连接状态</h2><p>绑定后可在概览中查看在线电脑与手机数量。登录 Windows 后，连接程序会自动启动。</p></div></div></section>
          <div class="info-callout"><Icon name="shield" :size="20"/><p>连接密钥是私有凭据。不要将带有私有配置的安装包上传到公开仓库，也不要通过公开渠道发送配对码。</p></div>
        </template>

        <footer class="footer"><span>© AstroGate Connect</span><span>安全中转 · 本机记录</span></footer>
      </div>
    </main>

    <div v-if="toast" class="toast" role="status"><Icon name="check" :size="18"/>{{ toast }}</div>
    <div v-if="createdToken" class="modal-layer" role="presentation"><div class="modal-backdrop" @click="closeCreatedToken"></div><section class="modal" role="dialog" aria-modal="true" aria-labelledby="token-title"><div class="modal-icon success"><Icon name="key" :size="24"/></div><h2 id="token-title">连接密钥已生成</h2><p>“{{ createdName }}”的密钥仅在此显示一次。关闭后无法再次查看。</p><div class="secret-box"><code>{{ createdToken }}</code></div><div class="modal-actions"><button type="button" class="button button-quiet" @click="closeCreatedToken">完成</button><button type="button" class="button button-primary" @click="copy(createdToken, '连接密钥')"><Icon name="copy" :size="17"/>复制密钥</button></div></section></div>
    <div v-if="keyToRemove" class="modal-layer" role="presentation"><div class="modal-backdrop" @click="keyToRemove = null"></div><section class="modal" role="dialog" aria-modal="true" aria-labelledby="remove-title"><div class="modal-icon warning"><Icon name="alert" :size="24"/></div><h2 id="remove-title">停用连接密钥？</h2><p>“{{ keyToRemove.name }}”将无法再用于电脑重连。此操作不会修改原有兼容密钥。</p><div class="modal-actions"><button type="button" class="button button-quiet" @click="keyToRemove = null">取消</button><button type="button" class="button button-danger" :disabled="removing" @click="revokeKey">{{ removing ? '处理中…' : '确认停用' }}</button></div></section></div>
  </div>
</template>
