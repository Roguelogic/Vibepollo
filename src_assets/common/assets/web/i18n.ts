import { createI18n, type LocaleMessageValue } from 'vue-i18n';

type LocaleMessages = Record<string, LocaleMessageValue>;

interface LocaleResponse {
  locale?: string;
}

async function loadJson(path: string): Promise<LocaleMessages> {
  const response = await fetch(path, {
    credentials: 'same-origin',
    headers: { Accept: 'application/json' },
  });
  if (!response.ok) throw new Error('locale-catalog-unavailable');
  return (await response.json()) as LocaleMessages;
}

function mergeMessages(base: LocaleMessages, overlay: LocaleMessages): LocaleMessages {
  const result: LocaleMessages = { ...base };
  for (const [key, value] of Object.entries(overlay)) {
    const existing = result[key];
    result[key] =
      value &&
      typeof value === 'object' &&
      !Array.isArray(value) &&
      existing &&
      typeof existing === 'object' &&
      !Array.isArray(existing)
        ? mergeMessages(existing as LocaleMessages, value as LocaleMessages)
        : value;
  }
  return result;
}

async function loadMessages(locale: string): Promise<LocaleMessages> {
  const basePath = `${import.meta.env.BASE_URL}assets/locale`;
  const englishBase = await loadJson(`${basePath}/en.json`);
  const englishInterface = await loadJson(`${basePath}/ui/en.json`);
  let messages = mergeMessages(englishBase, englishInterface);
  if (locale === 'en') return messages;

  const encoded = encodeURIComponent(locale);
  const base = await loadJson(`${basePath}/${encoded}.json`);
  messages = mergeMessages(messages, base);
  try {
    const interfaceMessages = await loadJson(`${basePath}/ui/${encoded}.json`);
    return mergeMessages(messages, interfaceMessages);
  } catch {
    return messages;
  }
}

async function configuredLocale(): Promise<string> {
  try {
    const response = await fetch('/api/configLocale', {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    });
    if (!response.ok) return 'en';
    const payload = (await response.json()) as LocaleResponse;
    const locale = payload.locale?.trim() ?? '';
    return /^[a-z]{2}(?:_[A-Z]{2})?$/.test(locale) ? locale : 'en';
  } catch {
    return 'en';
  }
}

function browserLocaleTag(locale: string): string {
  return locale.replace(/_/g, '-');
}

function normalizeLocaleCode(locale: string): string {
  const trimmed = locale.trim();
  return /^[a-z]{2}(?:_[A-Z]{2})?$/.test(trimmed) ? trimmed : 'en';
}

type VibepolloI18n = Awaited<ReturnType<typeof createVibepolloI18n>>;

let activeI18nInstance: VibepolloI18n | null = null;

export async function setVibepolloLocale(nextLocale: string): Promise<void> {
  if (!activeI18nInstance) return;
  const normalized = normalizeLocaleCode(nextLocale);
  const targetTag = normalized === 'en' ? 'en' : browserLocaleTag(normalized);
  try {
    const loaded = await loadMessages(normalized);
    activeI18nInstance.global.setLocaleMessage(targetTag, loaded);
    activeI18nInstance.global.locale.value = targetTag;
    document.documentElement.lang = targetTag;
  } catch {
    activeI18nInstance.global.locale.value = 'en';
    document.documentElement.lang = 'en';
  }
}

export async function createVibepolloI18n() {
  const configured = await configuredLocale();
  let activeLocale = 'en';
  const english = await loadMessages('en');
  const messages: Record<string, LocaleMessages> = { en: english };

  if (configured !== 'en') {
    try {
      const configuredMessages = await loadMessages(configured);
      activeLocale = browserLocaleTag(configured);
      messages[activeLocale] = configuredMessages;
    } catch {
      activeLocale = 'en';
    }
  }

  document.documentElement.lang = activeLocale;
  const instance = createI18n({
    legacy: false,
    locale: activeLocale,
    fallbackLocale: 'en',
    fallbackWarn: false,
    missingWarn: false,
    messages,
  });
  activeI18nInstance = instance;
  return instance;
}
