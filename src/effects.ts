import {NativeModules, Platform} from 'react-native';
import {NosmaiCameraSdk} from '@nosmai/react-native-effects-sdk';
import type {NosmaiFilter} from '@nosmai/react-native-effects-sdk';

/**
 * One effects API for the Host on both platforms.
 *
 * - Android: the Host camera is the Nosmai RN SDK camera, so calls go to
 *   NosmaiCameraSdk unchanged.
 * - iOS: the Host camera is owned by this bridge (NosmaiCore). The RN SDK's
 *   visual APIs reject there, so calls go to the bridge's native effects methods,
 *   which use the same NosmaiCore APIs.
 *
 * Use only after the Host camera is ready (NosmaiTencentHost status 'ready').
 */
export type NosmaiPackageType = 'filter' | 'effect' | 'background' | 'beauty_effect' | 'game';

export type NosmaiPackage = {
  /** Cloud: filter id. Local: the package path. */
  id: string;
  name: string;
  displayName: string;
  type: NosmaiPackageType;
  location: 'local' | 'cloud';
  /** Local .nosmai file path; present once a cloud package is downloaded. */
  path?: string;
  previewUrl?: string;
  /** Local preview image path (local packages only). */
  previewPath?: string;
  category?: string;
  isDownloaded: boolean;
  isFree: boolean;
};

export type NosmaiBeautyControl = 'skinSmoothing' | 'skinWhitening' | 'teethWhitening';
export type NosmaiReshape =
  | 'faceSlim' | 'eye' | 'nose' | 'chin' | 'lip' | 'jaw'
  | 'brow' | 'browThickness' | 'mouthWidth' | 'forehead';
export type NosmaiBackground =
  | {mode: 'blur'; blurStrength: number}
  | {mode: 'color'; color: {red: number; green: number; blue: number; alpha?: number}}
  | {mode: 'image'; uri: string}
  | {mode: 'video'; uri: string};
export type NosmaiClearTarget = 'filter' | 'effect' | 'background' | 'beauty' | 'reshape' | 'all';
export type NosmaiCapabilities = {beauty: boolean; cloud: boolean; advanced: boolean};

type IosEffects = {
  effectsCapabilities(): Promise<NosmaiCapabilities>;
  effectsGetLocal(type: string | null): Promise<NosmaiPackage[]>;
  effectsGetCloud(type: string | null): Promise<NosmaiPackage[]>;
  effectsDownloadCloud(id: string): Promise<{filterId: string; path: string; alreadyDownloaded: boolean}>;
  effectsApply(path: string): Promise<boolean>;
  effectsClear(kind: NosmaiClearTarget): Promise<void>;
  effectsSetBeauty(control: NosmaiBeautyControl, value: number): Promise<void>;
  effectsSetReshape(type: NosmaiReshape, value: number): Promise<void>;
  effectsSetBackground(options: NosmaiBackground): Promise<void>;
};

function ios(): IosEffects {
  const native = NativeModules.NosmaiTencentBridge as Partial<IosEffects> | undefined;
  if (!native?.effectsApply) {
    throw new Error('iOS bridge effects are unavailable; rebuild the native app with this bridge version');
  }
  return native as IosEffects;
}

const isIos = Platform.OS === 'ios';

function fromSdk(filter: NosmaiFilter): NosmaiPackage {
  return {
    id: filter.location === 'cloud' ? (filter.filterId ?? filter.id) : (filter.path || filter.id),
    name: filter.name,
    displayName: filter.displayName || filter.name,
    type: filter.packageType,
    location: filter.location,
    path: filter.path || undefined,
    previewUrl: filter.previewUrl,
    category: filter.category,
    isDownloaded: filter.isDownloaded,
    isFree: filter.isFree,
  };
}

export const NosmaiTencentEffects = {
  /** Which feature groups this Nosmai license enables. */
  async getCapabilities(): Promise<NosmaiCapabilities> {
    if (isIos) return ios().effectsCapabilities();
    const [beauty, cloud, advanced] = await Promise.all([
      NosmaiCameraSdk.isBeautyEffectEnabled(),
      NosmaiCameraSdk.isCloudFilterEnabled(),
      NosmaiCameraSdk.isAdvancedFiltersEnabled(),
    ]);
    return {beauty, cloud, advanced};
  },

  /** Packages bundled with the app / SDK. */
  async getLocalPackages(type?: NosmaiPackageType): Promise<NosmaiPackage[]> {
    if (isIos) return ios().effectsGetLocal(type ?? null);
    return (await NosmaiCameraSdk.getLocalFilters(type)).map(fromSdk);
  },

  /** Cloud catalog for this license (all pages). */
  async getCloudPackages(type?: NosmaiPackageType): Promise<NosmaiPackage[]> {
    if (isIos) return ios().effectsGetCloud(type ?? null);
    const page = await NosmaiCameraSdk.getCloudFilters(type ? {packageType: type} : undefined);
    return page.filters.map(fromSdk);
  },

  /** Downloads (or reuses) a cloud package and returns its local path. */
  async downloadCloudPackage(item: NosmaiPackage | string): Promise<string> {
    const id = typeof item === 'string' ? item : item.id;
    if (isIos) return (await ios().effectsDownloadCloud(id)).path;
    return (await NosmaiCameraSdk.downloadCloudFilter(id)).path;
  },

  /** Applies a local .nosmai package; the SDK picks the right slot from its type. */
  async applyPackage(path: string): Promise<void> {
    if (isIos) { await ios().effectsApply(path); return; }
    await NosmaiCameraSdk.applyFilter(path);
  },

  /** Downloads a cloud package if needed, then applies it. */
  async applyCloudPackage(item: NosmaiPackage): Promise<string> {
    const path = item.path && item.isDownloaded ? item.path : await this.downloadCloudPackage(item);
    await this.applyPackage(path);
    return path;
  },

  async clear(target: NosmaiClearTarget): Promise<void> {
    if (isIos) return ios().effectsClear(target);
    switch (target) {
      case 'filter': return NosmaiCameraSdk.clearFilter();
      case 'effect': return NosmaiCameraSdk.clearAREffect();
      case 'background': return NosmaiCameraSdk.clearBackground();
      case 'beauty': return NosmaiCameraSdk.clearBeauty();
      case 'reshape': return NosmaiCameraSdk.clearReshaping();
      case 'all': return NosmaiCameraSdk.clearAll();
    }
  },

  /** 0..1 */
  async setBeauty(control: NosmaiBeautyControl, value: number): Promise<void> {
    if (isIos) return ios().effectsSetBeauty(control, value);
    if (control === 'skinSmoothing') return NosmaiCameraSdk.setSkinSmoothing(value);
    if (control === 'skinWhitening') return NosmaiCameraSdk.setSkinWhitening(value);
    return NosmaiCameraSdk.setTeethWhitening(value);
  },

  /** -1..1 (0 = neutral). */
  async setReshape(type: NosmaiReshape, value: number): Promise<void> {
    if (isIos) return ios().effectsSetReshape(type, value);
    return NosmaiCameraSdk.setReshape(type, value);
  },

  /** Background replacement (needs a license with advanced filters). Colors are 0..1. */
  async setBackground(background: NosmaiBackground): Promise<void> {
    if (isIos) return ios().effectsSetBackground(background);
    return NosmaiCameraSdk.setBackground(background);
  },
};
