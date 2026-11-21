interface MonitorApplication {
  uuid?: unknown;
  'remote-session'?: unknown;
  'remote-monitor-profile'?: unknown;
}

export function isRemoteMonitorApplication(app: MonitorApplication | null | undefined): boolean {
  return (
    app?.['remote-monitor-profile'] === true ||
    app?.['remote-session'] === 'monitor' ||
    app?.uuid === '9a1c5a25-58fe-40e0-b9aa-7d3f00000005'
  );
}

const applicationDisplayRoutingKeys = [
  'virtual-screen',
  'virtual-display-mode',
  'virtual-display-layout',
  'dd-configuration-option',
  'display-output',
] as const;

export function preserveRemoteMonitorRouting(
  source: MonitorApplication | null | undefined,
  payload: Record<string, unknown>,
): void {
  if (!source || !isRemoteMonitorApplication(source)) return;
  if (Object.prototype.hasOwnProperty.call(source, 'remote-monitor-profile')) {
    payload['remote-monitor-profile'] = source['remote-monitor-profile'];
  }
  for (const key of applicationDisplayRoutingKeys) {
    if (Object.prototype.hasOwnProperty.call(source, key)) {
      payload[key] = Reflect.get(source, key);
    } else {
      delete payload[key];
    }
  }
}
