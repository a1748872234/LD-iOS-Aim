// ============================================================
//  凤凰 iOS 功能核心层（对齐安卓 Menu.cpp）
//  - 本地保留通道分发：PHXOPTS / PHXSELECT / PHXGIVE / PHXSPAWN /
//    PHXTELEPORT / PHXBAN / PHXCROSS / PHXDRAW / PHXGIFT / PHXGP_*
//  - 服务端回包解析：JDARK_CLIENT_CHALLENGE / JDARK_ADMIN_STATE /
//    JDARK_ADMIN_PLAYERS / JDARK_SHOP|BALANCE / BUY_OK / VIP_DAILY_*
//  - 状态快照（网页 serverStatus 依赖的全部字段）
//  - 生成面板名单（spawn_data.json，1202 物品 + 110 生物）
//  编译时拼在 entry.mm 之后，共用其 static 函数
// ============================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ---------- 与安卓逐字节一致的 AUTH 算法 ----------
static const uint64_t kAuthSecretA = 0x4a4441524b434c31ULL;   // "JDARKCL1"
static const uint64_t kAuthSecretB = 0xd6e8feb86659fd93ULL;
static const uint64_t kAuthVersion  = 1ULL;

static uint64_t phxMix(uint64_t hash, uint64_t value) {
    for (int i = 0; i < 8; ++i) {
        hash ^= (value & 0xffULL);
        hash *= 1099511628211ULL;
        value >>= 8;
    }
    return hash;
}

static uint64_t phxAuthResponse(uint64_t pid, uint64_t nonce) {
    uint64_t h = 1469598103934665603ULL;
    h = phxMix(h, kAuthSecretA);
    h = phxMix(h, pid);
    h = phxMix(h, nonce);
    h = phxMix(h, kAuthSecretB);
    h = phxMix(h, kAuthVersion);
    return h ^ (h >> 32);
}

// ---------- 运行态 ----------
static BOOL g_adminOK = NO;
static BOOL g_conn = NO;
static BOOL g_cross = NO, g_drawDinos = NO, g_drawPlayers = NO, g_drawRes = NO;
static NSString *g_srvAddr = @"";
static long long g_localPid = 0;

static NSString *g_gpJson = @"";        // /api/gameplay_info 原始响应
static NSString *g_gpMsg = @"";
static long long g_gpSeq = 0;
static NSString *g_gpDrawIds = @"";

static NSString *g_shopMsg = @"";
static long long g_shopSeq = 0;
static BOOL g_shopNeedIdentity = NO;
static long long g_balanceCache = 0;
static BOOL g_vipActive = NO;
static long long g_vipExpire = 0;
static long long g_vipLevel = 0;
static long long g_vipGrowth = 0;

// 开关状态与日志环形缓冲（网页桥与功能层共用）
static NSMutableDictionary *g_q = nil;
static NSMutableArray<NSString *> *g_logs = nil;

static void ldqInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_q = [NSMutableDictionary dictionaryWithDictionary:@{@"god":@NO, @"fly":@NO, @"ghost":@NO,
            @"ammo":@NO, @"weight":@NO, @"invisible":@NO, @"speedbuild":@NO}];
        g_logs = [NSMutableArray array];
    });
}

static void ldqLog(NSString *fmt, ...) {
    if (!fmt) return;
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!line) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ldqInit();
        [g_logs addObject:line];
        if (g_logs.count > 200) [g_logs removeObjectAtIndex:0];
    });
}

static BOOL ldqToggle(NSString *key, BOOL *out) {
    ldqInit();
    BOOL v = ![g_q[key] boolValue];
    g_q[key] = @(v);
    if (out) *out = v;
    return v;
}

static NSString *g_itemOptsJson = nil;           // 生成面板物品名单
static NSString *g_dinoOptsJson = nil;           // 生成面板生物名单
static long long g_selGivePid = 0;               // PHXSELECT 选中的发放目标
static NSString *g_playersJson = @"[]";

// ---------- 工具 ----------
static NSString *phxJ(id obj) {
    if (!obj) return @"null";
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!d) return @"null";
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s ?: @"null";
}

static NSArray<NSString *> *phxSplit(NSString *s, NSString *sep) {
    if (!s) return @[];
    return [s componentsSeparatedByString:sep];
}

// ---------- 生成面板名单（从资源加载） ----------
static void phxLoadSpawnData(void) {
    if (g_itemOptsJson && g_dinoOptsJson) return;
    NSString *p = nil;
    for (NSString *cand in @[@"spawn_data", @"phoenix/spawn_data"]) {
        p = [[NSBundle mainBundle] pathForResource:[cand lastPathComponent] ofType:@"json" inDirectory:[cand hasPrefix:@"phoenix"] ? @"phoenix" : nil];
        if (p) break;
    }
    if (!p) {
        NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *cand = [doc stringByAppendingPathComponent:@"phoenix/spawn_data.json"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:cand]) p = cand;
    }
    if (!p) { g_itemOptsJson = @"[]"; g_dinoOptsJson = @"[]"; return; }

    NSData *d = [NSData dataWithContentsOfFile:p];
    NSDictionary *root = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![root isKindOfClass:[NSDictionary class]]) { g_itemOptsJson = @"[]"; g_dinoOptsJson = @"[]"; return; }

    NSMutableArray *it = [NSMutableArray array];
    for (NSDictionary *o in root[@"items"]) {
        if (![o isKindOfClass:[NSDictionary class]]) continue;
        [it addObject:@{@"n": (o[@"n"] ?: @""), @"c": (o[@"c"] ?: @"")}];
    }
    NSMutableArray *dn = [NSMutableArray array];
    for (NSDictionary *o in root[@"dinos"]) {
        if (![o isKindOfClass:[NSDictionary class]]) continue;
        [dn addObject:@{@"n": (o[@"n"] ?: @""), @"k": (o[@"k"] ?: @"")}];
    }
    g_itemOptsJson = phxJ(it);
    g_dinoOptsJson = phxJ(dn);
    logLine(@"[凤凰] 生成名单已载入：物品 %lu，生物 %lu", (unsigned long)it.count, (unsigned long)dn.count);
}

// ---------- 服务端回包解析 ----------
// 返回 YES 表示已被本层消费，不再往下传
static BOOL phxHandleServerCommand(NSString *cmd) {
    if (!cmd.length) return NO;

    // 客户端识别挑战：JDARK_CLIENT_CHALLENGE|<非零字段里取 nonce/pid>
    if ([cmd hasPrefix:@"JDARK_CLIENT_CHALLENGE|"]) {
        NSArray *f = phxSplit(cmd, @"|");
        uint64_t nonce = 0, pid = 0;
        for (NSUInteger i = 1; i < f.count; i++) {
            long long v = [f[i] longLongValue];
            if (v <= 0) continue;
            if (!nonce) nonce = (uint64_t)v;
            else if (!pid) pid = (uint64_t)v;
        }
        if (!nonce || !pid) {
            logLine(@"[凤凰] 识别挑战字段无效: %@", cmd);
            return YES;
        }
        g_localPid = (long long)pid;
        [NSUserDefaults.standardUserDefaults setObject:@(pid) forKey:@"phx_pid"];
        uint64_t resp = phxAuthResponse(pid, nonce);
        NSString *out = [NSString stringWithFormat:@"JDARK_CLIENT|AUTH|%llu|%llu|%llu|%llu",
                         kAuthVersion, pid, nonce, resp];
        if (!phxSendProtocol(out)) ldExecCmd(out);
        logLine(@"[凤凰] 已提交客户端识别响应 pid=%llu nonce=%llu", pid, nonce);
        return YES;
    }

    // 管理员状态
    if ([cmd hasPrefix:@"JDARK_ADMIN_STATE|"]) {
        NSString *v = [cmd substringFromIndex:19];
        g_adminOK = ([v isEqualToString:@"1"]);
        logLine(@"[凤凰] 服务端管理员状态: %@", g_adminOK ? @"是" : @"否");
        return YES;
    }

    // 玩家列表 pid,online,banned,admin,account,survivor
    if ([cmd hasPrefix:@"JDARK_ADMIN_PLAYERS|"]) {
        NSString *body = [cmd substringFromIndex:20];
        NSMutableArray *arr = [NSMutableArray array];
        for (NSString *rec in phxSplit(body, @"|")) {
            if (!rec.length) continue;
            NSArray *f = phxSplit(rec, @",");
            if (f.count < 6) continue;
            long long pid = [f[0] longLongValue];
            if (pid <= 0) continue;
            BOOL online  = [f[1] boolValue];
            BOOL banned  = [f[2] boolValue];
            BOOL admin   = [f[3] boolValue];
            NSString *acct = f[4];
            NSString *surv = f[5];
            NSString *label = [NSString stringWithFormat:@"%@ / %@%@%@%@", acct, surv,
                               online ? @" | 在线" : @" | 离线",
                               admin ? @" | 管理员" : @"",
                               banned ? @" | 已封禁" : @""];
            [arr addObject:@{@"id": @(pid), @"name": surv, @"account": acct,
                             @"label": label,
                             @"online": @(online), @"banned": @(banned), @"admin": @(admin)}];
        }
        g_playersJson = phxJ(arr);
        logLine(@"[凤凰] 玩家列表已更新：%lu 人", (unsigned long)arr.count);
        return YES;
    }

    // 商店通道回包：JDARK_SHOP|<动作>|...
    if ([cmd hasPrefix:@"JDARK_SHOP|"]) {
        NSArray *f = phxSplit(cmd, @"|");
        if (f.count < 3) return YES;
        NSString *act = f[1];

        if ([act isEqualToString:@"BALANCE"]) {
            g_balanceCache = [f[2] longLongValue];
            if (f.count >= 6) {
                g_vipActive = [f[3] boolValue];
                g_vipExpire = [f[4] longLongValue];
            }
            if (f.count >= 7) g_shopMsg = [NSString stringWithFormat:@"余额 %lld", g_balanceCache];
        } else if ([act isEqualToString:@"BUY_OK"]) {
            g_shopMsg = f.count > 3 ? [NSString stringWithFormat:@"购买成功 ×%@", f[3]] : @"购买成功";
        } else if ([act isEqualToString:@"VIP_DAILY_OK"]) {
            long long r = f.count > 2 ? [f[2] longLongValue] : 0;
            g_shopMsg = [NSString stringWithFormat:@"VIP每日礼包: +%lld 涅槃币", r];
            g_balanceCache += r;
        } else if ([act isEqualToString:@"VIP_DAILY_FAIL"]) {
            g_shopMsg = f.count > 2 ? f[2] : @"领取失败";
        }
        g_shopSeq++;
        return YES;
    }
    return NO;
}

// ---------- 本地保留通道（网页 sendCommand 进来的） ----------
static BOOL phxLocalChannel(NSString *cmd) {
    if (!cmd.length) return NO;

    if ([cmd hasPrefix:@"PHXOPTS"]) {
        phxLoadSpawnData();
        return YES;
    }
    if ([cmd hasPrefix:@"PHXSELECT|"]) {
        NSString *p = [cmd substringFromIndex:10];
        while (p.length && ([p hasPrefix:@" "] || [p hasPrefix:@"\""])) p = [p substringFromIndex:1];
        while (p.length && ([p hasSuffix:@" "] || [p hasSuffix:@"\""])) p = [p substringToIndex:p.length-1];
        g_selGivePid = p.longLongValue;
        g_selPid = g_selGivePid;        // 发放/生成/传送共用同一个目标
        logLine(@"[凤凰] 已选中目标玩家 %@", p);
        return YES;
    }
    if ([cmd hasPrefix:@"PHXGIVE|"]) {
        NSArray *f = phxSplit(cmd, @"|");
        int idx = f.count > 1 ? [f[1] intValue] : -1;
        int qty = f.count > 2 ? [f[2] intValue] : 1;
        float q = f.count > 3 ? [f[3] floatValue] : 0.f;
        if (idx < 0) { g_shopMsg = @"发放参数不完整"; return YES; }
        ldAdminGiveItem(idx, qty, q, NO);
        g_shopMsg = [NSString stringWithFormat:@"已发放物品 #%d ×%d", idx, qty];
        return YES;
    }
    if ([cmd hasPrefix:@"PHXSPAWN|"]) {
        NSArray *f = phxSplit(cmd, @"|");
        int idx  = f.count > 1 ? [f[1] intValue] : -1;
        if (idx < 0) { g_shopMsg = @"生成参数不完整"; return YES; }
        // 安卓侧第三段是中文模式文本（野生/驯服/首领），不是数字
        NSString *modeText = f.count > 2 ? [NSString stringWithFormat:@"%@", f[2]] : @"";
        int mode;
        if ([modeText containsString:@"驯服"])      mode = 2;   // SummonTamed
        else if ([modeText containsString:@"首领"]) mode = 0;   // GMSummon
        else if ([modeText containsString:@"野生"]) mode = 1;   // Summon
        else                                        mode = modeText.intValue;
        int lv   = f.count > 3 ? [f[3] intValue] : 1;
        if (lv <= 0) lv = 1;
        ldAdminSpawnDino(mode, idx, lv);
        g_shopMsg = [NSString stringWithFormat:@"已生成生物 #%d 等级 %d", idx, lv];
        return YES;
    }
    if ([cmd hasPrefix:@"PHXTELEPORT|"]) {
        NSArray *f = phxSplit(cmd, @"|");
        NSString *dir = f.count > 1 ? f[1] : @"GOTO";
        NSString *pid = f.count > 2 ? f[2] : @"";
        phxSendProtocol([NSString stringWithFormat:@"JDARK_ADMIN|TELEPORT|%@|%@", dir, pid]);
        return YES;
    }
    if ([cmd hasPrefix:@"PHXBAN|"]) {
        NSString *pid = [cmd substringFromIndex:7];
        phxSendProtocol([NSString stringWithFormat:@"JDARK_ADMIN|BAN|%@", pid]);
        logLine(@"[凤凰] 已提交封禁 %@", pid);
        return YES;
    }
    if ([cmd hasPrefix:@"PHXCROSS|"]) {
        BOOL on = [[cmd substringFromIndex:8] isEqualToString:@"1"];
        g_cross = on;
        ldAdminCross(on);
        return YES;
    }
    if ([cmd hasPrefix:@"PHXDRAW|"]) {
        NSArray *f = phxSplit(cmd, @"|");
        NSString *kind = f.count > 1 ? f[1] : @"";
        BOOL on = f.count > 2 ? [f[2] boolValue] : NO;
        if ([kind isEqualToString:@"dinos"]) g_drawDinos = on;
        else if ([kind isEqualToString:@"players"]) g_drawPlayers = on;
        else if ([kind isEqualToString:@"resources"]) g_drawRes = on;
        ldAdminDraw(kind, on);
        return YES;
    }
    if ([cmd hasPrefix:@"PHXGIFT|"]) {
        NSString *type = [cmd substringFromIndex:8];
        ldClaimGift(type);
        return YES;
    }
    if ([cmd hasPrefix:@"PHXGP_"]) {
        NSString *rest = [cmd substringFromIndex:7];
        NSArray *f = phxSplit(rest, @"|");
        NSString *action = f.count ? f[0] : @"";
        NSString *extra = f.count > 1 ? f[1] : @"{}";
        ldGameplayAction(action, extra, ^(BOOL ok, NSString *body) {
            g_gpMsg = ok ? @"操作已提交" : @"操作失败";
            g_gpSeq++;
            NSLog(@"PHX gameplay %@ -> %d", action, ok);
        });
        return YES;
    }
    return NO;
}

// ---------- 状态快照（网页 serverStatus 全字段） ----------
static NSString *phxStatusJSON(void) {
    phxLoadSpawnData();
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    // 快捷开关
    d[@"god"] = @([g_q[@"god"] boolValue]);
    d[@"fly"] = @([g_q[@"fly"] boolValue]);
    d[@"ghost"] = @([g_q[@"ghost"] boolValue]);
    d[@"ammo"] = @([g_q[@"ammo"] boolValue]);
    d[@"weight"] = @([g_q[@"weight"] boolValue]);
    d[@"invisible"] = @([g_q[@"invisible"] boolValue]);
    d[@"speed"] = @([g_q[@"speedbuild"] boolValue]);

    // 连接 / 身份
    d[@"connected"] = @(g_conn);
    d[@"admin"] = @(g_adminOK);
    d[@"server"] = g_srvAddr ?: @"";
    d[@"online"] = @(g_playersJson.length && ![g_playersJson isEqualToString:@"[]"]);

    // 商店 / VIP
    d[@"shopMsg"] = g_shopMsg ?: @"";
    d[@"shopSeq"] = @(g_shopSeq);
    d[@"shopNeedIdentity"] = @(g_shopNeedIdentity);
    d[@"shopVipActive"] = @(g_vipActive);
    d[@"shopVipExpire"] = @(g_vipExpire);
    d[@"shopVipLevel"] = @(g_vipLevel);
    d[@"shopVipGrowth"] = @(g_vipGrowth);
    d[@"coins"] = @(g_balanceCache);
    d[@"vip"] = @(g_vipActive);

    // 玩法
    d[@"gameplay"] = g_gpJson ?: @"";
    d[@"gpMsg"] = g_gpMsg ?: @"";
    d[@"gpSeq"] = @(g_gpSeq);
    d[@"gpDrawIds"] = g_gpDrawIds ?: @"";

    // 管理
    d[@"crosshair"] = @(g_cross);
    d[@"drawDinos"] = @(g_drawDinos);
    d[@"drawPlayers"] = @(g_drawPlayers);
    d[@"drawResources"] = @(g_drawRes);
    d[@"players"] = g_playersJson ?: @"[]";

    // 生成面板名单
    d[@"itemOptions"] = g_itemOptsJson ?: @"[]";
    d[@"dinoOptions"] = g_dinoOptsJson ?: @"[]";

    // ArkRH 已有的运行时状态（通知 + KVC 回读）
    NSDictionary *ark = phxArkSnapshot();
    if (ark) [d addEntriesFromDictionary:ark];

    return phxJ(d);
}

// ---------- 对外：网页桥调用 ----------
static NSString *phxQuickStatesJSON(void) {
    phxLoadSpawnData();
    NSDictionary *s = @{
        @"god": @([g_q[@"god"] boolValue]), @"fly": @([g_q[@"fly"] boolValue]),
        @"ghost": @([g_q[@"ghost"] boolValue]), @"ammo": @([g_q[@"ammo"] boolValue]),
        @"weight": @([g_q[@"weight"] boolValue]), @"invisible": @([g_q[@"invisible"] boolValue]),
        @"speed": @([g_q[@"speedbuild"] boolValue]),
        @"crosshair": @(g_cross), @"drawDinos": @(g_drawDinos),
        @"drawPlayers": @(g_drawPlayers), @"drawResources": @(g_drawRes),
        @"admin": @(g_adminOK), @"connected": @(g_conn), @"players": g_playersJson ?: @"[]"
    };
    return phxJ(s);
}

static void phxPushPlayers(void) {
    ldAdminListPlayers();
}
