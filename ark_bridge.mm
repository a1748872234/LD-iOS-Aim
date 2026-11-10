// ============================================================
//  ArkRH 桥接层
//  功能实现全部复用 ArkRH（客户端识别 / 管理员通道 / 商店回执 /
//  玩家列表 / 称号 / VIP / 竞技场 / 工坊 / 传送 / 绘制 都在里面）
//  本层只做三件事：
//    1) 发送：queueServerProtocolCommand / queueAdminConsoleCommand
//    2) 接收：订阅 ArkRH 的 27 个状态通知，合并 userInfo
//    3) 读取：KVC 从 adapter / runtime 取当前状态
//  拼接顺序：entry.mm → ark_bridge.mm → phoenix_core.mm → webui_part.mm
// ============================================================
#import <Foundation/Foundation.h>

static void ldqLog(NSString *line);   // 定义在 phoenix_core.mm
static NSMutableDictionary *g_ark = nil;      // 合并后的 ArkRH 状态
static NSString *g_arkLastEvent = @"";
static NSMutableArray<NSString *> *g_arkEventLog = nil;

// ---------- 发送 ----------
static id phxAdapter(void) { return ldArkAdapter(); }

static BOOL phxSendSel(NSString *selName, NSString *cmd) {
    id a = phxAdapter();
    if (!a || !cmd.length) return NO;
    SEL s = NSSelectorFromString(selName);
    if (![a respondsToSelector:s]) return NO;
    @try {
        ldInvoke(a, s, @[cmd, [NSNull null]]);
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[PHX] %@ 调用异常: %@", selName, e);
        return NO;
    }
}

// 服务端协议命令（JDARK_*）优先走协议通道，其次管理通道，最后本地控制台
static BOOL phxSendProtocol(NSString *cmd) {
    if (phxSendSel(@"queueServerProtocolCommand:error:", cmd)) return YES;
    if (phxSendSel(@"queueAdminConsoleCommand:error:", cmd)) return YES;
    if (phxSendSel(@"queueLocalConsoleCommand:error:", cmd)) return YES;
    return NO;
}

// ---------- 读取 ----------
static id phxReadKey(NSString *key) {
    @try {
        id a = phxAdapter();
        if (a && [a respondsToSelector:@selector(valueForKey:)]) {
            id v = [a valueForKey:key];
            if (v) return v;
        }
    } @catch (NSException *e) { }
    @try {
        id a = phxAdapter();
        SEL rs = NSSelectorFromString(@"runtime");
        if (a && [a respondsToSelector:rs]) {
            id rt = [a performSelector:rs];
            if (rt && [rt respondsToSelector:@selector(valueForKey:)]) {
                id v = [rt valueForKey:key];
                if (v) return v;
            }
        }
    } @catch (NSException *e) { }
    return nil;
}

// ---------- 通知 ----------
static NSArray<NSString *> *phxArkNotifications(void) {
    static NSArray *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[
            @"AJClient110AdminAuthStateDidChange",
            @"AJClient110AdminPlayersDidChange",
            @"AJClient110AdminPermissionDidChange",
            @"AJClient110AdminMarketDidChange",
            @"AJClient110AdminKeyCountDidChange",
            @"AJClient110AdminLightCountDidChange",
            @"AJClient110StoreResultDidChange",
            @"AJClient110StoreLedgerDidChange",
            @"AJClient110ModerationDidChange",
            @"AJClient110GiftConfigDidChange",
            @"AJClient110ServerSettingsDidChange",
            @"AJClient110ServerRulesDidChange",
            @"AJClient110BioSpawnDidChange",
            @"AJClient110BroadcastStateDidChange",
            @"AJClient110EquipmentRecycleDidChange",
            @"AJClient110PlayerTradeDidChange",
            @"AJClient110SunshineWishDidChange",
            @"AJClient110ProgressionUnlockDidChange",
            @"AJClient110AttributeDinoResultDidChange",
            @"AJClient110OSDPointsDidChange",
            @"AJClient110EnhancementSettingsDidChange",
            @"AJTitleBadgeDidChange",
            @"AJVipBubbleDidChange",
            @"AJVipDanmakuDidChange",
            @"AJAwesomeTeleportDidChange",
            @"ClientServerNotification",
            @"AJMenuLanguageDidChangeNotification"
        ];
    });
    return names;
}

static void phxArkMerge(NSDictionary *ui) {
    if (![ui isKindOfClass:[NSDictionary class]]) return;
    for (id k in ui) {
        if (![k isKindOfClass:[NSString class]]) continue;
        id v = ui[k];
        // 只收可直接序列化的值
        if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) {
            g_ark[k] = v;
        } else if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSDictionary class]]) {
            if ([NSJSONSerialization isValidJSONObject:v]) g_ark[k] = v;
        }
    }
}

static void phxArkInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_ark = [NSMutableDictionary dictionary];
        g_arkEventLog = [NSMutableArray array];
        for (NSString *n in phxArkNotifications()) {
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    @try {
                        g_arkLastEvent = note.name;
                        phxArkMerge(note.userInfo);
                        if (g_arkEventLog.count > 100) [g_arkEventLog removeObjectAtIndex:0];
                        [g_arkEventLog addObject:note.name];

                        // 关键通知到达后立刻回读一次运行时状态
                        if ([note.name containsString:@"AdminAuth"]) {
                            id v = phxReadKey(@"admin");
                            if (v) g_ark[@"admin"] = v;
                        }
                        if ([note.name containsString:@"AdminPlayers"]) {
                            id v = phxReadKey(@"players");
                            if (v) g_ark[@"players"] = v;
                        }
                        NSString *line = [NSString stringWithFormat:@"[Ark] %@", note.name];
                        ldqLog(line);
                    } @catch (NSException *e) {
                        NSLog(@"[PHX] 通知处理异常 %@: %@", note.name, e);
                    }
                }];
        }
        // 触发一次运行时刷新，让 ArkRH 把当前状态推过来
        id a = phxAdapter();
        if (a) {
            for (NSString *sel in @[@"refreshRuntimeStatus", @"refreshFromRuntime", @"reloadFromRuntime"]) {
                SEL s = NSSelectorFromString(sel);
                if ([a respondsToSelector:s]) { @try { ldInvoke(a, s, @[]); } @catch (NSException *e) { } }
            }
        }
        NSLog(@"[PHX] ArkRH 通知已订阅 %lu 个", (unsigned long)phxArkNotifications().count);
    });
}

// ---------- 对外 ----------
static NSDictionary *phxArkSnapshot(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (g_ark) [d addEntriesFromDictionary:g_ark];
    d[@"arkEvent"] = g_arkLastEvent ?: @"";
    d[@"arkEvents"] = g_arkEventLog ?: @[];
    id rs = phxReadKey(@"runtimeStatus");
    if (rs) d[@"runtimeStatus"] = rs;
    return d;
}

__attribute__((constructor))
static void phx_ark_boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @autoreleasepool { phxArkInstall(); }
    });
}
