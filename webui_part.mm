// ============================================================
//  凤凰 iOS 网页面板（WKWebView 宿主 + Phoenix 桥）
//  与安卓 phoenix_console.html 的 39 个 JavascriptInterface 一一对齐
//  编译时由 build.sh 拼接到 entry.mm 之后，共用其中的 static 函数
// ============================================================
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

#pragma mark - 页面需要的 39 个桥接方法

static NSString *const kPhoenixMethods[] = {
    @"toggleGod", @"toggleFly", @"toggleGhost", @"toggleAmmo", @"toggleWeight",
    @"toggleInvisible", @"toggleSpeedBuild", @"healAll", @"levelUpTarget",
    @"setDaytime", @"setNighttime", @"sendCommand", @"joinServer", @"exitServer",
    @"giveItem", @"spawnDino", @"getQuickStates", @"getClipboard", @"isAdmin",
    @"getPlayers", @"refreshPlayers", @"getLogs", @"getServerStatus",
    @"getSavedServers", @"addServer", @"removeServer", @"setActiveServer",
    @"getActiveServer", @"applyGraphics", @"openGodConsole", @"hideMenu",
    @"getShopItems", @"getShopBalance", @"buyShopItem", @"refreshShop",
    @"setWeather", @"modDownload", @"modReset", @"getModDownload",
    nil
};

// ---------- 运行态（开关/日志/g_q 由 phoenix_core.mm 提供） ----------
static NSString *g_shopItemsJson = @"[]";       // 商店商品
static long long g_shopBalanceLocal = 0;    // 余额


#pragma mark - 桥

@interface LDPhoenixWeb : NSObject <WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) UIWindow *win;
@property (nonatomic, strong) UIButton *ball;
@end

@implementation LDPhoenixWeb

+ (instancetype)shared {
    static LDPhoenixWeb *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[LDPhoenixWeb alloc] init]; });
    return s;
}

// ---------- 资源路径 ----------
- (NSURL *)htmlURL {
    NSString *p = [[NSBundle mainBundle] pathForResource:@"phoenix_console" ofType:@"html" inDirectory:@"phoenix"];
    if (!p) {
        NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        p = [doc stringByAppendingPathComponent:@"phoenix/phoenix_console.html"];
    }
    if (!p || ![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return [NSURL fileURLWithPath:p];
}

// ---------- 注入 JS：把 window.Phoenix 建起来，全部走 prompt 同步桥 ----------
- (NSString *)shimJS {
    NSMutableString *names = [NSMutableString string];
    for (int i = 0; kPhoenixMethods[i]; i++) {
        [names appendFormat:@"'%@'", kPhoenixMethods[i]];
        [names appendString:(kPhoenixMethods[i + 1] ? @"," : @"")];
    }
    return [NSString stringWithFormat:
        @"(function(){if(window.Phoenix&&window.Phoenix.__shim)return;"
         "function call(m,a){try{var r=prompt('PHX'+JSON.stringify({m:m,a:a||[]}));"
         "if(r===null||r==='')return {\"ok\":true};return JSON.parse(r);}catch(e){return {\"ok\":false,\"err\":''+e};}}"
         "var P={__shim:true};var N=[%@];"
         "for(var i=0;i<N.length;i++){(function(n){P[n]=function(){return call(n,Array.prototype.slice.call(arguments));};})(N[i]);}"
         "window.Phoenix=P;})();", names];
}

// ---------- 悬浮球 ----------
- (void)installBall {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *key = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) { if (w.isKeyWindow) { key = w; break; } }
                if (key) break;
            }
        }
        if (!key) key = UIApplication.sharedApplication.keyWindow;
        if (!key) return;

        CGFloat d = 52;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - d - 10, 120, d, d);
        b.backgroundColor = [UIColor colorWithRed:0.05 green:0.45 blue:0.6 alpha:0.92];
        b.layer.cornerRadius = d / 2;
        b.layer.borderWidth = 1.5;
        b.layer.borderColor = [UIColor colorWithRed:0.28 green:0.85 blue:1.0 alpha:1].CGColor;
        [b setTitle:@"凤" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:22];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [b addTarget:self action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
        b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBall:)];
        [b addGestureRecognizer:pan];
        [key addSubview:b];
        self.ball = b;
        ldqLog(@"[凤凰] 悬浮球已挂载");
    });
}

- (void)dragBall:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint p = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + p.x, v.center.y + p.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

// ---------- 显示 ----------
- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.win) { self.win.hidden = NO; return; }
        NSURL *u = [self htmlURL];
        if (!u) { ldqLog(@"[凤凰] 找不到 phoenix_console.html，面板无法打开"); return; }

        WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
        WKUserContentController *ucc = [[WKUserContentController alloc] init];
        [ucc addScriptMessageHandler:self name:@"phx"];
        WKUserScript *us = [[WKUserScript alloc] initWithSource:[self shimJS]
                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
        [ucc addUserScript:us];
        cfg.userContentController = ucc;
        cfg.allowsInlineMediaPlayback = YES;

        UIWindow *w = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                w = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)sc];
                if (w) break;
            }
        }
        if (!w) w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 1;

        UIViewController *vc = [[UIViewController alloc] init];
        CGRect f = w.bounds;
        WKWebView *web = [[WKWebView alloc] initWithFrame:f configuration:cfg];
        web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        web.UIDelegate = self;
        web.navigationDelegate = self;
        web.opaque = NO;
        web.backgroundColor = [UIColor blackColor];
        vc.view.backgroundColor = [UIColor blackColor];
        [vc.view addSubview:web];
        w.rootViewController = vc;
        [w makeKeyAndVisible];

        [web loadFileURL:u allowingReadAccessToURL:[u URLByDeletingLastPathComponent]];
        self.web = web;
        self.win = w;
        w.hidden = NO;
        ldqLog(@"[凤凰] 面板已打开");
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.win) self.win.hidden = YES;
    });
}

#pragma mark - WKUIDelegate：prompt 同步桥

- (void)webView:(WKWebView *)webView
runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
     defaultText:(NSString *)defaultText
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(NSString * _Nullable))completionHandler {
    if (![prompt hasPrefix:@"PHX"]) { completionHandler(@""); return; }
    NSString *json = [prompt substringFromIndex:3];
    NSString *ret = [self dispatchJSON:json];
    completionHandler(ret ?: @"");
}

#pragma mark - 分发

- (NSString *)okJSON:(BOOL)ok extra:(NSString *)extra {
    if (!extra) return ok ? @"{\"ok\":true}" : @"{\"ok\":false}";
    return [NSString stringWithFormat:@"{\"ok\":%@,\"data\":%@}", ok ? @"true" : @"false", extra];
}

- (NSString *)dispatchJSON:(NSString *)json {
    ldqInit();
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *req = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![req isKindOfClass:[NSDictionary class]]) return @"{\"ok\":false}";
    NSString *m = ldStr(req, @"m");
    NSArray *a = req[@"a"];
    if (![a isKindOfClass:[NSArray class]]) a = @[];

    @try {
        // ---- 开关类 ----
        if ([m isEqualToString:@"toggleGod"])      { if (!g_adminOK) { return @"{\"ok\":false,\"err\":\"需要服务器管理员权限\"}"; } BOOL v; ldqToggle(@"god", &v);  ldToggleCheat(LDCheatGod, v);  return [self okJSON:YES extra:[NSString stringWithFormat:@"%d", v]]; }
        if ([m isEqualToString:@"toggleFly"])      { BOOL v; ldqToggle(@"fly", &v);  ldToggleCheat(LDCheatFly, v);  return [self okJSON:YES extra:[NSString stringWithFormat:@"%d", v]]; }
        if ([m isEqualToString:@"toggleAmmo"])     { BOOL v; ldqToggle(@"ammo", &v); ldToggleCheat(LDCheatInfiniteAmmo, v); return [self okJSON:YES extra:[NSString stringWithFormat:@"%d", v]]; }
        if ([m isEqualToString:@"toggleWeight"])   { BOOL v; ldqToggle(@"weight",&v); if (v) { ldExecCmd(@"InfiniteWeight"); return [self okJSON:YES extra:@"1"]; }
            return @"{\"ok\":false,\"err\":\"无限负重需重新进服后恢复\"}"; }
        if ([m isEqualToString:@"toggleGhost"]) {
            // 安卓侧是本地 CheatManager::Ghost（vtable 槽 0x2e8），iOS 等价走本地控制台
            BOOL v; ldqToggle(@"ghost", &v);
            ldExecCmd(@"Ghost");
            return [self okJSON:YES extra:[NSString stringWithFormat:@"%d", v]];
        }
        if ([m isEqualToString:@"toggleInvisible"]) {
            // 安卓侧同样不支持自身隐身（无对应作弊函数/状态位），口径保持一致
            return @"{\"ok\":false,\"err\":\"当前客户端不支持隐身模式\"}";
        }
        if ([m isEqualToString:@"toggleSpeedBuild"]){
            BOOL v; ldqToggle(@"speedbuild",&v);
            id ad = ldArkAdapter();
            if (ad && [ad respondsToSelector:@selector(queueInstantCraftToggle:)]) {
                ldInvoke(ad, @selector(queueInstantCraftToggle:), @[@(v)]);
                return [self okJSON:YES extra:[NSString stringWithFormat:@"%d", v]];
            }
            ldCheatAction(LDCheatInstantCraft);
            return [self okJSON:YES extra:[NSString stringWithFormat:@"%d", v]];
        }
        if ([m isEqualToString:@"getQuickStates"]) {
            return [self okJSON:YES extra:phxQuickStatesJSON()];
        }

        // ---- 作弊动作 ----
        if ([m isEqualToString:@"healAll"])        { if (!g_adminOK) { return @"{\"ok\":false,\"err\":\"需要服务器管理员权限\"}"; } ldCheatAction(LDCheatHealAll); return @"{\"ok\":true}"; }
        if ([m isEqualToString:@"levelUpTarget"])  { if (!g_adminOK) { return @"{\"ok\":false,\"err\":\"需要服务器管理员权限\"}"; } ldCheatAction(LDCheatLevelUp); return @"{\"ok\":true}"; }
        if ([m isEqualToString:@"setDaytime"])     { if (!g_adminOK) { return @"{\"ok\":false,\"err\":\"需要服务器管理员权限\"}"; } ldCheatActionEx(LDCheatTime, 28800.0f); return @"{\"ok\":true}"; }
        if ([m isEqualToString:@"setNighttime"])   { if (!g_adminOK) { return @"{\"ok\":false,\"err\":\"需要服务器管理员权限\"}"; } ldCheatActionEx(LDCheatTime, 72000.0f); return @"{\"ok\":true}"; }
        if ([m isEqualToString:@"openGodConsole"]) { ldCheatAction(LDCheatOpenConsoleUI); return @"{\"ok\":true}"; }

        // ---- 命令 / 进服 ----
        if ([m isEqualToString:@"sendCommand"]) {
            NSString *c = a.count ? [NSString stringWithFormat:@"%@", a[0]] : nil;
            if (!c.length) return @"{\"ok\":false,\"err\":\"命令为空\"}";
            // 先走本地保留通道（PHXOPTS/PHXGIVE/PHXSPAWN/PHXCROSS/PHXDRAW/PHXGP_ 等）
            if (phxLocalChannel(c)) { ldqLog([NSString stringWithFormat:@"保留通道: %@", c]); return @"{\"ok\":true}"; }
            // 服务端协议命令与普通控制台命令
            if (!phxHandleServerCommand(c)) ldExecCmd(c);
            ldqLog([NSString stringWithFormat:@"命令: %@", c]);
            return @"{\"ok\":true}";
        }
        if ([m isEqualToString:@"joinServer"]) {
            NSString *link = a.count ? [NSString stringWithFormat:@"%@", a[0]] : nil;
            if (!link.length) return @"{\"ok\":false,\"err\":\"服务器地址为空\"}";
            doJoinLink(link);
            return @"{\"ok\":true}";
        }
        if ([m isEqualToString:@"exitServer"]) { ldExecCmd(@"disconnect"); return @"{\"ok\":true}"; }

        // ---- 管理面板 ----
        if ([m isEqualToString:@"giveItem"]) {
            int idx = a.count > 0 ? [a[0] intValue] : 0;
            int qty = a.count > 1 ? [a[1] intValue] : 1;
            float q = a.count > 2 ? [a[2] floatValue] : 0.f;
            BOOL bp = a.count > 3 ? [a[3] boolValue] : NO;
            ldAdminGiveItem(idx, qty, q, bp);
            return @"{\"ok\":true}";
        }
        if ([m isEqualToString:@"spawnDino"]) {
            int mode = a.count > 0 ? [a[0] intValue] : 0;
            int idx  = a.count > 1 ? [a[1] intValue] : 0;
            int lv   = a.count > 2 ? [a[2] intValue] : 1;
            ldAdminSpawnDino(mode, idx, lv);
            return @"{\"ok\":true}";
        }
        if ([m isEqualToString:@"refreshPlayers"]) { if (!g_adminOK) { return @"{\"ok\":false,\"err\":\"需要服务器管理员权限\"}"; } ldAdminListPlayers(); return [self okJSON:YES extra:g_playersJson]; }
        if ([m isEqualToString:@"getPlayers"])     { return [self okJSON:YES extra:g_playersJson]; }
        if ([m isEqualToString:@"isAdmin"])        { return [self okJSON:YES extra:[NSString stringWithFormat:@"%d", g_adminOK]]; }

        // ---- 日志 / 状态 ----
        if ([m isEqualToString:@"getLogs"]) {
            NSArray *arr = [g_logs copy];
            return [self okJSON:YES extra:(ldJsonString(@{@"lines": arr}) ?: @"{}")];
        }
        if ([m isEqualToString:@"getServerStatus"]) {
            // 先从云端回拉玩法数据（异步），本次先返回现有快照
            ldGameplayInfo(^(BOOL ok, NSString *body) {
                if (ok && body.length) g_gpJson = body;
            });
            return [self okJSON:YES extra:phxStatusJSON()];
        }

        // ---- 剪贴板 ----
        if ([m isEqualToString:@"getClipboard"]) {
            NSString *s = [UIPasteboard generalPasteboard].string ?: @"";
            return [self okJSON:YES extra:(ldJsonString(@{@"text": s}) ?: @"{}")];
        }

        // ---- 服务器列表（本地存档）----
        if ([m isEqualToString:@"getSavedServers"]) {
            NSArray *v = [[NSUserDefaults standardUserDefaults] arrayForKey:@"phx_servers"] ?: @[];
            return [self okJSON:YES extra:(ldJsonString(@{@"servers": v}) ?: @"{}")];
        }
        if ([m isEqualToString:@"addServer"] || [m isEqualToString:@"removeServer"]) {
            NSString *s = a.count ? [NSString stringWithFormat:@"%@", a[0]] : @"";
            NSMutableArray *v = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"phx_servers"] mutableCopy] ?: [NSMutableArray array];
            if ([m isEqualToString:@"addServer"]) { if (s.length && ![v containsObject:s]) [v addObject:s]; }
            else { [v removeObject:s]; }
            [[NSUserDefaults standardUserDefaults] setObject:v forKey:@"phx_servers"];
            return @"{\"ok\":true}";
        }
        if ([m isEqualToString:@"setActiveServer"]) {
            NSString *s = a.count ? [NSString stringWithFormat:@"%@", a[0]] : @"";
            [[NSUserDefaults standardUserDefaults] setObject:s forKey:@"phx_active_server"];
            return @"{\"ok\":true}";
        }
        if ([m isEqualToString:@"getActiveServer"]) {
            NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:@"phx_active_server"] ?: @"";
            return [self okJSON:YES extra:(ldJsonString(@{@"server": s}) ?: @"{}")];
        }

        // ---- 画质 / 天气 ----
        if ([m isEqualToString:@"applyGraphics"]) {
            NSString *cfg = a.count ? [NSString stringWithFormat:@"%@", a[0]] : @"{}";
            [NSUserDefaults.standardUserDefaults setObject:cfg forKey:@"phx_graphics"];
            id ad = ldArkAdapter();
            BOOL sent = NO;
            if (ad) {
                NSString *preset = @"balanced";
                if ([cfg containsString:@"low"]) preset = @"low";
                else if ([cfg containsString:@"high"] || [cfg containsString:@"ultra"]) preset = @"high";
                sent = phxSendSel(@"scheduleIOSGraphicsPreset:error:", preset);
            }
            return sent ? @"{\"ok\":true}" : @"{\"ok\":false,\"err\":\"画质预设未就绪\"}";
        }
        if ([m isEqualToString:@"setWeather"]) {
            return @"{\"ok\":false,\"err\":\"当前客户端不支持该操作：世界天气\"}";
        }

        // ---- 商店 ----
        if ([m isEqualToString:@"refreshShop"] || [m isEqualToString:@"getShopItems"]) {
            ldGetItems(^(BOOL ok, NSString *body) {
                if (ok && body.length) g_shopItemsJson = body;
            });
            return [self okJSON:YES extra:(g_shopItemsJson.length ? g_shopItemsJson : @"[]")];
        }
        if ([m isEqualToString:@"getShopBalance"]) {
            ldGetBalance(^(BOOL ok, NSString *body) {
                if (!ok) return;
                NSDictionary *r = ldParseJson(body);
                if ([r isKindOfClass:[NSDictionary class]]) g_shopBalanceLocal = (long long)ldInt(r, @"balance");
            });
            return [self okJSON:YES extra:[NSString stringWithFormat:@"{\"balance\":%lld}", g_shopBalanceLocal]];
        }
        if ([m isEqualToString:@"buyShopItem"]) {
            NSString *iid = a.count ? [NSString stringWithFormat:@"%@", a[0]] : @"";
            NSInteger q = a.count > 1 ? [a[1] integerValue] : 1;
            if (!iid.length) return @"{\"ok\":false,\"err\":\"商品 ID 为空\"}";
            ldBuyItem(iid, q, ^(BOOL ok, NSString *body) {
                ldqLog([NSString stringWithFormat:@"购买 %@ -> %@", iid, ok ? @"ok" : (body ?: @"fail")]);
            });
            return @"{\"ok\":true}";
        }

        // ---- 模组下载 ----
        if ([m isEqualToString:@"modDownload"]) {
            NSString *url = a.count ? [NSString stringWithFormat:@"%@", a[0]] : @"";
            NSString *nm  = a.count > 1 ? [NSString stringWithFormat:@"%@", a[1]] : @"mod";
            if (!url.length) { ldDownloadDefaultMod(); return @"{\"ok\":true}"; }
            ldDownloadMod(url, nm);
            return @"{\"ok\":true}";
        }
        if ([m isEqualToString:@"modReset"]) {
            BOOL ok = phxClearMods();
            return ok ? @"{\"ok\":true}" : @"{\"ok\":false}";
        }
        if ([m isEqualToString:@"getModDownload"]) {
            NSString *p = phxModCacheDir();
            NSArray *ls = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:nil] ?: @[];
            NSMutableArray *paks = [NSMutableArray array];
            for (NSString *n in ls)
                if ([n.pathExtension.lowercaseString isEqualToString:@"pak"]) [paks addObject:n];
            return [self okJSON:YES extra:(ldJsonString(@{@"dir": (p ?: @""),
                @"installed": @(paks.count > 0), @"paks": paks}) ?: @"{}")];
        }

        // ---- 面板自身 ----
        if ([m isEqualToString:@"hideMenu"]) { [self hide]; return @"{\"ok\":true}"; }

        return @"{\"ok\":false,\"err\":\"未实现的桥接方法\"}";
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"{\"ok\":false,\"err\":\"%@\"}", [e reason] ?: @"exception"];
    }
}

#pragma mark - WKScriptMessageHandler（异步补充通道）

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)msg {
    if (![msg.name isEqualToString:@"phx"]) return;
    id body = msg.body;
    if ([body isKindOfClass:[NSString class]]) { [self dispatchJSON:body]; }
}

@end

#pragma mark - 启动

__attribute__((constructor))
static void ld_phoenix_web_boot(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[LDPhoenixWeb shared] installBall];
        });
    }
}
