/*
 * 隐私政策同意状态。
 *
 * 上架审核要求首次启动时必须让用户明确同意隐私政策，且该状态要跨启动保
 * 存——否则每次打开都会弹，用户会烦。用 preferences 而不是 AppStorage，
 * 因为 AppStorage 只活在进程里，杀进程就没了。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE = 'spektra-settings';
const KEY = 'privacyAccepted';

export class PrivacyStore {
  /** 从 AppStorage 取 Ability 上下文；拿不到就返回 null，调用方自己兜底。 */
  private static ctx(): common.UIAbilityContext | null {
    const raw = AppStorage.get<common.UIAbilityContext>('abilityContext');
    return raw === undefined ? null : raw;
  }

  /** 读是否已同意。任何异常都当作「没同意」——宁可多问一次，也不要漏问。 */
  static async isAccepted(): Promise<boolean> {
    const ctx = PrivacyStore.ctx();
    if (ctx === null) {
      return false;
    }
    try {
      const store = await preferences.getPreferences(ctx, STORE);
      const value = await store.get(KEY, false);
      return value === true;
    } catch (e) {
      return false;
    }
  }

  /** 记下同意。写失败不阻断使用，本次会话内仍然放行。 */
  static async accept(): Promise<void> {
    const ctx = PrivacyStore.ctx();
    if (ctx === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(ctx, STORE);
      await store.put(KEY, true);
      await store.flush();
    } catch (e) {
      // 忽略：最坏情况是下次启动再问一遍。
    }
  }

  /** 不同意时退出应用，而不是留在一个功能被锁死的界面上。 */
  static exit(): void {
    const ctx = PrivacyStore.ctx();
    if (ctx !== null) {
      ctx.terminateSelf();
    }
  }
}
