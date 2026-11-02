/**
 * HttpClient —— 极简 JSON 文本拉取器（只负责「拿到字符串」，不解析）
 *
 * 对应原项目 utils/data.js 的 request() / fetchDataset() 里的网络部分。
 * 三点与小程序不同的地方：
 *   1. 鸿蒙 http 每次都要 createHttp() 新建，用完必须 destroy()，否则句柄泄漏；
 *   2. 必须显式 expectDataType = STRING，否则 result 可能是 ArrayBuffer；
 *   3. 加并发限流（4）与同 URL 去重，避免首页多个区块同时开页面时打满连接。
 *
 * 约定：本文件不出现 console.*，诊断信息一律走 hilog。
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'HttpClient';

// 与 utils/data.js 的 REQUEST_TIMEOUT = 8000 对齐；连接超时另给 5000
const CONNECT_TIMEOUT: number = 5000;
const READ_TIMEOUT: number = 8000;
const MAX_CONCURRENCY: number = 4;

/**
 * 网络错误。把 BusinessError 的 code 带出来，方便上层区分
 *   2300006 DNS 解析失败 / 2300007 连接失败 / 2300028 请求超时
 */
export class HttpError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.name = 'HttpError';
    this.code = code;
  }
}

/**
 * 极简信号量：队列 + 计数，不引三方库。
 *
 * release() 时如果队列非空，直接把许可「转交」给队首（permits 不变），
 * 否则才把 permits 加回去。这样并发上限恒等于 MAX_CONCURRENCY。
 */
class Semaphore {
  private permits: number;
  private waiters: Array<() => void> = [];

  constructor(size: number) {
    this.permits = size > 0 ? size : 1;
  }

  acquire(): Promise<void> {
    if (this.permits > 0) {
      this.permits = this.permits - 1;
      return Promise.resolve();
    }
    return new Promise<void>((resolve) => {
      this.waiters.push(resolve);
    });
  }

  release(): void {
    const next = this.waiters.shift();
    if (next !== undefined) {
      // 直接转交许可，permits 保持已扣减状态
      next();
      return;
    }
    this.permits = this.permits + 1;
  }
}

const semaphore: Semaphore = new Semaphore(MAX_CONCURRENCY);

// 同 URL 去重：并发请求共用同一个 Promise，完成后删除
const inflight: Map<string, Promise<string>> = new Map<string, Promise<string>>();

/**
 * 拉一个 URL 的响应正文（字符串），不解析 JSON。
 *
 * - 并发限流 4
 * - 同一 URL 在途时复用同一个 Promise；无论成败，结束后都会从表里移除，
 *   因此失败之后的下一次调用会重新发请求（与原项目 inflight 的清理语义一致）
 *
 * @param url 完整 URL
 * @param readTimeout 读超时，默认 8000ms
 */
export async function getText(url: string, readTimeout?: number): Promise<string> {
  const running = inflight.get(url);
  if (running !== undefined) {
    return running;
  }

  const timeout: number =
    readTimeout !== undefined && readTimeout > 0 ? readTimeout : READ_TIMEOUT;
  const p: Promise<string> = doGetText(url, timeout);
  inflight.set(url, p);

  const clear = () => {
    if (inflight.get(url) === p) {
      inflight.delete(url);
    }
  };
  // 两个分支都清理，避免失败后该 URL 永远占着表项
  p.then(clear, clear);

  return p;
}

/** 真正发请求的那一层。acquire 在 try 之外，保证 release 与 acquire 成对。 */
async function doGetText(url: string, readTimeout: number): Promise<string> {
  await semaphore.acquire();

  let req: http.HttpRequest | null = null;
  try {
    req = http.createHttp();

    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      // 不显式指定可能拿到 ArrayBuffer
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: CONNECT_TIMEOUT,
      readTimeout: readTimeout,
      // COS 对象带 Cache-Control: max-age=3600，走系统缓存是期望行为
      usingCache: true
    };

    const resp: http.HttpResponse = await req.request(url, options);

    // responseCode 的声明类型是 number | http.ResponseCode，统一转 number 再判
    const respCode: number = Number(resp.responseCode);
    if (respCode !== 200) {
      throw new HttpError(respCode, 'HTTP ' + respCode + ' ' + url);
    }

    const body: string | Object | ArrayBuffer = resp.result;
    if (typeof body !== 'string') {
      throw new HttpError(-1, '响应正文不是字符串: ' + url);
    }
    return body;
  } catch (e) {
    if (e instanceof HttpError) {
      throw e;
    }
    // 业务错误：DNS / 连接 / 超时都在 BusinessError.code 里
    const err: HttpError = normalizeError(e as Object, url);
    hilog.warn(DOMAIN, TAG, 'getText failed code=%{public}d url=%{public}s', err.code, url);
    throw err;
  } finally {
    // 每个 createHttp() 都必须配对 destroy()；destroy 本身异常不能掩盖原错误
    if (req !== null) {
      try {
        req.destroy();
      } catch (destroyErr) {
        // 忽略：销毁失败不影响本次结果
      }
      req = null;
    }
    semaphore.release();
  }
}

/**
 * 把任意抛出的对象规整成 HttpError，并给三个常见网络错误码补上人话描述。
 * 独立成函数是为了让 catch 块只做「转换 + 记录 + 重抛」，避免参数类型推断踩坑。
 */
function normalizeError(e: Object, url: string): HttpError {
  let code: number = -1;
  let msg: string = '网络请求失败';

  const be: BusinessError = e as BusinessError;
  if (be !== null && be !== undefined) {
    const rawCode: number = be.code;
    if (typeof rawCode === 'number') {
      code = rawCode;
    }
    const rawMsg: string = be.message;
    if (typeof rawMsg === 'string' && rawMsg.length > 0) {
      msg = rawMsg;
    }
  }

  if (code === 2300006) {
    msg = 'DNS 解析失败(' + code + '): ' + msg + ' ' + url;
  } else if (code === 2300007) {
    msg = '连接失败(' + code + '): ' + msg + ' ' + url;
  } else if (code === 2300028) {
    msg = '请求超时(' + code + '): ' + msg + ' ' + url;
  } else {
    msg = msg + ' ' + url;
  }

  return new HttpError(code, msg);
}
