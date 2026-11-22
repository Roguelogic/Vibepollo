import { createPinia } from 'pinia';
import { createApp, watch } from 'vue';
import type { RouteLocationNormalizedLoaded } from 'vue-router';

import App from '@/App.vue';
import { createVibepolloI18n } from '@/i18n';
import router from '@/router';
import '@/styles/tokens.css';
import '@/styles/base.css';
import '@/styles/components.css';
import '@/styles/shell.css';
import '@/styles/views.css';

const i18n = await createVibepolloI18n();

function syncDocumentTitle(route: RouteLocationNormalizedLoaded = router.currentRoute.value): void {
  const key = typeof route.meta.titleKey === 'string' ? route.meta.titleKey : 'ui.nav.overview';
  const title = i18n.global.t(key);
  document.title = route.path === '/' ? 'Vibepollo' : `${title} · Vibepollo`;
}

router.afterEach((route) => {
  syncDocumentTitle(route);
});

watch(
  () => i18n.global.locale.value,
  () => syncDocumentTitle(),
);

createApp(App).use(createPinia()).use(router).use(i18n).mount('#app');
