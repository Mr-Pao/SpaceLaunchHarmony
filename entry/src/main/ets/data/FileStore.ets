/**
 * FileStore —— L2 缓存的文件系统实现（同步 API）
 *
 * 为什么不用 preferences：
 *   鸿蒙的 preferences 单个 value 上限 8192 字节，而我们的数据集动辄几百 KB
 *   （launchers 435KB / upcomingMore 626KB / gallery 140KB），根本存不下。
 *   所以 L2 落到文件系统，并全部使用 *Sync 接口，保持与原项目
 *   uni.getStorageSync / uni.setStorageSync 一样的同步语义。
 *
 * 为什么落 filesDir 而不是 cacheDir：
 *   cacheDir 会被系统在空间不足时自动清理，冷启动首屏就白等网络了。
 *   filesDir 属于应用私有数据，只有用户主动清数据 / 卸载才会消失。
 *
 * 原则：读失败一律返回 null / 空，绝不向上抛。
 *       缓存层是加速手段，任何异常都不该把已渲染的页面搞崩。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

const CACHE_DIR_NAME: string = 'dataCache';

export class FileStore {
  // 形如 <filesDir>/dataCache/v14/
  private dir: string = '';
  private ready: boolean = false;

  /**
   * 初始化。必须在 Ability onCreate 里调一次。
   * 目录是 v{DATA_VERSION} 的，版本升级时自然是另一个目录，
   * 旧目录由 clearAllSync() 或系统清理流程收走。
   */
  init(ctx: common.UIAbilityContext, dataVersion?: number): void {
    const v: number = dataVersion !== undefined && dataVersion > 0 ? dataVersion : 0;
    const versionDir: string = v > 0 ? 'v' + v : 'v0';
    this.dir = ctx.filesDir + '/' + CACHE_DIR_NAME + '/' + versionDir;
    try {
      if (!this.exists(this.dir)) {
        fs.mkdirSync(this.dir, true); // true = 递归创建多级目录
      }
      this.ready = true;
    } catch (e) {
      // 建目录失败就退化为「不落盘」，上层仍然有 L1 内存缓存可用
      this.ready = false;
    }
  }

  /** 当前缓存目录，仅供诊断/日志使用 */
  getDir(): string {
    return this.dir;
  }

  isReady(): boolean {
    return this.ready;
  }

  /**
   * 读一个 key 的文本内容。不存在、解析失败、未初始化，一律 null。
   * 注意这里不解析 JSON —— 解析交给 Repository，FileStore 只认字符串。
   */
  readSync(key: string): string | null {
    if (!this.ready) {
      return null;
    }
    const path: string = this.pathOf(key);
    try {
      if (!this.exists(path)) {
        return null;
      }
      return fs.readTextSync(path);
    } catch (e) {
      // 文件被外部删掉、权限异常、内容损坏——统统当作没有缓存
      return null;
    }
  }

  /**
   * 原子写：先写 xxx.json.tmp，closeSync 之后再 renameSync 到正式名。
   * 这样即使写到一半掉电 / 进程被杀，正式文件要么是旧的完整内容，
   * 要么完全不存在，不会出现「半截 JSON 让下次启动解析炸掉」。
   *
   * @returns 是否写成功（磁盘满、目录不存在都返回 false，不抛）
   */
  writeSync(key: string, text: string): boolean {
    if (!this.ready) {
      return false;
    }
    const path: string = this.pathOf(key);
    const tmpPath: string = path + '.tmp';

    // 先清掉可能残留的 tmp（上次写到一半崩了）
    this.safeUnlink(tmpPath);

    if (!this.writeFileSync(tmpPath, text)) {
      this.safeUnlink(tmpPath);
      return false;
    }

    try {
      // 部分 SDK 版本的 renameSync 不覆盖已存在的目标，先删再改名
      if (this.exists(path)) {
        fs.unlinkSync(path);
      }
      fs.renameSync(tmpPath, path);
      return true;
    } catch (e) {
      this.safeUnlink(tmpPath);
      return false;
    }
  }

  /** 删除一个 key。失败静默。 */
  removeSync(key: string): void {
    this.safeUnlink(this.pathOf(key));
  }

  /** 缓存目录总字节数（只统计 *.json，不含 .tmp 残留） */
  totalSizeSync(): number {
    if (!this.ready) {
      return 0;
    }
    let total: number = 0;
    try {
      const names: string[] = fs.listFileSync(this.dir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (!name.endsWith('.json')) {
          continue;
        }
        try {
          const st: fs.Stat = fs.statSync(this.dir + '/' + name);
          total += st.size;
        } catch (e) {
          // 单个文件统计失败不影响总数
        }
      }
    } catch (e) {
      return total;
    }
    return total;
  }

  /** 当前目录下的所有 key（去掉 .json 后缀） */
  listKeysSync(): string[] {
    const keys: string[] = [];
    if (!this.ready) {
      return keys;
    }
    try {
      const names: string[] = fs.listFileSync(this.dir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (name.endsWith('.json')) {
          keys.push(name.substring(0, name.length - 5));
        }
      }
    } catch (e) {
      // 目录读不到就当空
    }
    return keys;
  }

  /** 清空整个版本目录下的文件（保留目录本身） */
  clearAllSync(): void {
    if (!this.ready) {
      return;
    }
    try {
      const names: string[] = fs.listFileSync(this.dir);
      for (let i = 0; i < names.length; i++) {
        this.safeUnlink(this.dir + '/' + names[i]);
      }
    } catch (e) {
      // 忽略
    }
  }

  // ============ 内部 ============

  /**
   * 写文件本体：openSync → writeSync → closeSync，close 放 finally 保证配对。
   * 返回值表示是否成功，**不抛异常**。
   */
  private writeFileSync(tmpPath: string, text: string): boolean {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(
        tmpPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
      );
      fs.writeSync(file.fd, text);
      return true;
    } catch (e) {
      return false;
    } finally {
      // 每个 openSync 都必须配对 closeSync；close 自己失败也不能掩盖结果
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e2) {
          // 忽略：close 失败不影响写入结果判定
        }
      }
    }
  }

  /**
   * 判断路径是否存在 —— 兼容 accessSync 的两种行为。
   *
   * API 12 的 fs.accessSync(path) 声明返回 boolean，但不同 SDK 小版本
   * 存在返回 void 的实现（存在则正常返回，不存在则抛 BusinessError 13900002）。
   * 这里**不接收返回值**、只用 try/catch 判断，两种签名都能过编译：
   *   - 没抛异常 → 路径可访问 → 存在（不管返回 true 还是 undefined）
   *   - 抛异常   → 不存在或不可访问 → false
   *
   * 已知局限：若某版本改成「不存在时返回 false 而不抛」，这里会误判为存在。
   * 该情况下 readSync 仍被 readTextSync 的异常兜住（返回 null），
   * writeSync 只是多做一次无用 unlink，功能依然正确。
   * 若日后确认签名恒为 boolean，改成 `return fs.accessSync(p)` 即可收紧。
   */
  private exists(p: string): boolean {
    try {
      fs.accessSync(p);
      return true;
    } catch (e) {
      return false;
    }
  }

  private pathOf(key: string): string {
    return this.dir + '/' + this.sanitize(key) + '.json';
  }

  /**
   * key 直接拼进文件名前先净化：只留字母数字、下划线、点、横线。
   * 我们的 key 形如 sl_data_upcoming_v14，本来就只有这些字符，
   * 这里只是防御性处理，避免将来带 '/' 的 key 写到目录外。
   */
  private sanitize(key: string): string {
    let out: string = '';
    for (let i = 0; i < key.length; i++) {
      const c: string = key.charAt(i);
      const isDigit: boolean = c >= '0' && c <= '9';
      const isLower: boolean = c >= 'a' && c <= 'z';
      const isUpper: boolean = c >= 'A' && c <= 'Z';
      if (isDigit || isLower || isUpper || c === '_' || c === '-' || c === '.') {
        out += c;
      } else {
        out += '_';
      }
    }
    return out.length > 0 ? out : '_';
  }

  private safeUnlink(p: string): void {
    try {
      if (this.exists(p)) {
        fs.unlinkSync(p);
      }
    } catch (e) {
      // 删不掉也无妨，下次写入会覆盖 / 再次尝试
    }
  }
}

/** 全局单例 */
export const fileStore: FileStore = new FileStore();
