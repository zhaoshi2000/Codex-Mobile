<script setup>
defineProps({ name: { type: String, required: true }, size: { type: Number, default: 20 } });
</script>

<template>
  <svg :width="size" :height="size" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <template v-if="name === 'grid'"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></template>
    <template v-else-if="name === 'link'"><path d="M10 13a5 5 0 0 0 7.1 0l2.2-2.2a5 5 0 1 0-7.1-7.1L10.9 5"/><path d="M14 11a5 5 0 0 0-7.1 0l-2.2 2.2a5 5 0 1 0 7.1 7.1l1.3-1.3"/></template>
    <template v-else-if="name === 'key'"><circle cx="8" cy="15" r="4"/><path d="m11 12 8-8 2 2-2 2 1.5 1.5-2 2L17 10l-3 3"/></template>
    <template v-else-if="name === 'guide'"><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v17H6.5A2.5 2.5 0 0 1 4 17.5z"/><path d="M4 17.5A2.5 2.5 0 0 1 6.5 15H20"/><path d="M8 8h8M8 11h6"/></template>
    <template v-else-if="name === 'refresh'"><path d="M20 11a8 8 0 0 0-14.7-4.3L3 9"/><path d="M3 4v5h5"/><path d="M4 13a8 8 0 0 0 14.7 4.3L21 15"/><path d="M21 20v-5h-5"/></template>
    <template v-else-if="name === 'copy'"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></template>
    <template v-else-if="name === 'arrow'"><path d="M5 12h14m-6-6 6 6-6 6"/></template>
    <template v-else-if="name === 'check'"><path d="m5 12 4 4L19 6"/></template>
    <template v-else-if="name === 'monitor'"><rect x="3" y="4" width="18" height="14" rx="2"/><path d="M8 22h8M12 18v4"/></template>
    <template v-else-if="name === 'phone'"><rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/></template>
    <template v-else-if="name === 'shield'"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Z"/><path d="m9 12 2 2 4-4"/></template>
    <template v-else-if="name === 'plus'"><path d="M12 5v14M5 12h14"/></template>
    <template v-else-if="name === 'trash'"><path d="M4 7h16M10 11v7m4-7v7M6 7l1 14h10l1-14M9 7V4h6v3"/></template>
    <template v-else-if="name === 'eye'"><path d="M2 12s4-6 10-6 10 6 10 6-4 6-10 6-10-6-10-6Z"/><circle cx="12" cy="12" r="2.5"/></template>
    <template v-else-if="name === 'eyeoff'"><path d="m3 3 18 18M9.9 5.9A12 12 0 0 1 12 5.7c6 0 10 6.3 10 6.3a17 17 0 0 1-3.1 3.5M6.2 6.8C3.5 8.6 2 12 2 12s4 6.3 10 6.3a10 10 0 0 0 3.2-.5"/></template>
    <template v-else-if="name === 'close'"><path d="M5 5l14 14M19 5 5 19"/></template>
    <template v-else-if="name === 'info'"><circle cx="12" cy="12" r="10"/><path d="M12 11v6M12 7h.01"/></template>
    <template v-else-if="name === 'download'"><path d="M12 3v12m-4-4 4 4 4-4M4 17v3h16v-3"/></template>
    <template v-else-if="name === 'chevron'"><path d="m9 6 6 6-6 6"/></template>
    <template v-else-if="name === 'alert'"><path d="m12 3 10 18H2L12 3Z"/><path d="M12 9v5M12 18h.01"/></template>
    <template v-else-if="name === 'clock'"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></template>
  </svg>
</template>
