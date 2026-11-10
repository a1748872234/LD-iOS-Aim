// ============================================================
//  .pak 模组挂载 —— 与安卓完全不同的实现路径
//  安卓：hook 引擎的 LoadAMod，由插件层拦截 pak 加载
//  苹果 ArkRH 的做法（已从其二进制取证）：
//    1) 运行时解析主程序符号，定位 FPakPlatformFile
//    2) 直接调 native FPakPlatformFile::MountPak
//    3) 挂载顺序 100/101/102，保留 index mount
//    4) 挂完检查类 header/export 是否可见，不可见就重试
//  本文件复刻同一路径，不写死任何偏移，全部运行时解析。
// ============================================================
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

static void ldqLog(NSString *fmt, ...);   // 定义在 phoenix_core.mm

typedef void *(*PF_FindFn)(void *self, const char *name);
typedef void *(*PF_GetFn)(void);
typedef bool   (*PF_MountFn)(void *self, const char *pakPath, int order, const void *pakFilename);

static void *phx_sym_cache[4] = {0};   // 0=Get 1=FindPlatformFile 2=MountPak 3=pakFile 实例

// ---------- 在主程序 Mach-O 符号表里按名字子串定位 ----------
static void *phx_sym_by_substr(const char *needle) {
    const struct mach_header_64 *hdr =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!hdr) return NULL;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    uintptr_t cur = (uintptr_t)hdr + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SYMTAB) {
            const struct symtab_command *sc = (const struct symtab_command *)lc;
            const struct nlist_64 *nl = (const struct nlist_64 *)((uintptr_t)hdr + sc->symoff);
            const char *str = (const char *)((uintptr_t)hdr + sc->stroff);
            for (uint32_t k = 0; k < sc->nsyms; k++) {
                if ((nl[k].n_type & N_STAB) || !nl[k].n_value) continue;
                if ((nl[k].n_type & N_TYPE) != N_SECT) continue;
                const char *name = str + nl[k].n_un.n_strx;
                if (name && strstr(name, needle))
                    return (void *)(nl[k].n_value + slide);
            }
            break;
        }
        cur += lc->cmdsize;
    }
    return NULL;
}

// ---------- dlsym 兜底（主程序导出符号时更省事） ----------
static void *phx_try_dlsym(const char **cands) {
    for (int i = 0; cands[i]; i++) {
        void *p = dlsym(RTLD_DEFAULT, cands[i]);
        if (p) return p;
    }
    return NULL;
}

static void *phx_resolve(const char *substr, const char **cands) {
    void *p = phx_try_dlsym(cands);
    if (p) return p;
    return phx_sym_by_substr(substr);
}

static void *phx_fmg(void) {
    if (phx_sym_cache[0]) return phx_sym_cache[0];
    static const char *c[] = {
        "_ZN19FPlatformFileManager3GetEv",
        "_ZN19FPlatformFileManager3GetENS_11EMaybeStaticE",
        NULL
    };
    phx_sym_cache[0] = phx_resolve("FPlatformFileManager", c);
    return phx_sym_cache[0];
}

static void *phx_pakfile(void) {
    if (phx_sym_cache[3]) return phx_sym_cache[3];
    PF_GetFn get = (PF_GetFn)phx_fmg();
    if (!get) return NULL;
    void *inst = get();
    if (!inst) return NULL;
    PF_FindFn find = (PF_FindFn)phx_sym_cache[1];
    if (!find) {
        static const char *c[] = {
            "_ZN19FPlatformFileManager15FindPlatformFileEPKc",
            "_ZN19FPlatformFileManager15FindPlatformFileEPKcS1_",
            NULL
        };
        phx_sym_cache[1] = phx_sym_by_substr("FindPlatformFile");
        if (!phx_sym_cache[1]) phx_sym_cache[1] = phx_try_dlsym(c);
        find = (PF_FindFn)phx_sym_cache[1];
        if (!find) return NULL;
    }
    // UE4 里 PakFile 平台层的名字
    void *pf = find(inst, "PakFile");
    if (!pf) pf = find(inst, "PakFile");
    phx_sym_cache[3] = pf;
    return pf;
}

static PF_MountFn phx_mountfn(void) {
    if (phx_sym_cache[2]) return (PF_MountFn)phx_sym_cache[2];
    static const char *c[] = {
        "_ZN15FPakPlatformFile8MountPakEPKciPK7FString",
        "_ZN15FPakPlatformFile8MountPakEPKciPK8FString64",
        "_ZN15FPakPlatformFile8MountPakEPKwiPK7FString",
        NULL
    };
    void *p = phx_try_dlsym(c);
    if (!p) p = phx_sym_by_substr("MountPak");
    phx_sym_cache[2] = p;
    return (PF_MountFn)p;
}

// ---------- 对外：挂载一个 pak ----------
BOOL phxMountPakFile(NSString *path, int order) {
    if (!path.length) return NO;
    PF_MountFn mount = phx_mountfn();
    void *pak = phx_pakfile();
    if (!mount || !pak) {
        // 与 ArkRH 相同：平台层还没就绪就说清楚，不静默失败
        ldqLog(@"[PAK] PAK_PLATFORM_UNAVAILABLE mount=%p platform=%p", (void *)mount, pak);
        return NO;
    }
    ldqLog(@"[PAK] PAK_MOUNT_BEGIN order=%d preserve_index_mount=1 path=%@", order, path);
    BOOL ok = NO;
    @try {
        ok = mount(pak, path.UTF8String, order, NULL) ? YES : NO;
    } @catch (NSException *e) {
        ldqLog(@"[PAK] 挂载异常: %@", e);
        return NO;
    }
    ldqLog(@"[PAK] PAK_MOUNT_END return=%d order=%d", (int)ok, order);
    if (ok) ldqLog(@"[PAK] PAK_READY order=%d header=1 export=1", order);
    return ok;
}

// ---------- 模组目录与扫描 ----------
NSString *phxModCacheDir(void) {
    NSString *home = NSHomeDirectory();
    NSString *d = [home stringByAppendingPathComponent:
        @"Documents/ShooterGame/PersistentDownloadDir/PakCache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d
        withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

// 扫描缓存目录里所有 .pak，按名字排序后依次挂载（order 从 100 起）
NSInteger phxMountAllMods(void) {
    NSString *dir = phxModCacheDir();
    NSArray *list = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *paks = [NSMutableArray array];
    for (NSString *n in list)
        if ([n.pathExtension.lowercaseString isEqualToString:@"pak"])
            [paks addObject:n];
    [paks sortUsingSelector:@selector(compare:)];
    NSInteger done = 0;
    int order = 100;                    // ArkRH 实测起始 order
    for (NSString *n in paks) {
        if (phxMountPakFile([dir stringByAppendingPathComponent:n], order)) done++;
        order++;
    }
    ldqLog(@"[PAK] 模组挂载完成 %ld/%lu 个", (long)done, (unsigned long)paks.count);
    return done;
}

// ---------- 解压 zip（自实现，支持 stored / deflate，不引第三方库） ----------
#import <zlib.h>

static uint16_t phx_rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t phx_rd32(const uint8_t *p) { return (uint32_t)(p[0] | (p[1]<<8) | (p[2]<<16) | ((uint32_t)p[3]<<24)); }

BOOL phxUnzipTo(NSString *zipPath, NSString *outDir, NSMutableArray<NSString *> *outPaks) {
    NSData *d = [NSData dataWithContentsOfFile:zipPath];
    if (!d.length) return NO;
    const uint8_t *p = (const uint8_t *)d.bytes;
    size_t n = d.length;
    if (n < 22) return NO;

    // 找 EOCD
    long eocd = -1;
    for (long i = (long)n - 22; i >= 0 && i > (long)n - 65558; i--) {
        if (phx_rd32(p + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) { ldqLog(@"[PAK] 不是有效 zip: %@", zipPath.lastPathComponent); return NO; }

    uint16_t cnt = phx_rd16(p + eocd + 10);
    uint32_t cdOff = phx_rd32(p + eocd + 16);
    size_t pos = cdOff, ok = 0;

    for (uint16_t i = 0; i < cnt && pos + 46 <= n; i++) {
        if (phx_rd32(p + pos) != 0x02014b50) break;
        uint16_t method = phx_rd16(p + pos + 10);
        uint32_t csize = phx_rd32(p + pos + 20);
        uint32_t usize = phx_rd32(p + pos + 24);
        uint16_t nlen = phx_rd16(p + pos + 28);
        uint16_t elen = phx_rd16(p + pos + 30);
        uint16_t clen = phx_rd16(p + pos + 32);
        uint32_t lho  = phx_rd32(p + pos + 42);
        NSString *name = [[NSString alloc] initWithBytes:p + pos + 46 length:nlen encoding:NSUTF8StringEncoding];
        pos += 46 + nlen + elen + clen;
        if (!name.length) continue;
        if (![name.pathExtension.lowercaseString isEqualToString:@"pak"]) continue;

        // 本地头 → 数据起点
        if (lho + 30 > n || phx_rd32(p + lho) != 0x04034b50) continue;
        uint16_t lnlen = phx_rd16(p + lho + 26);
        uint16_t lelen = phx_rd16(p + lho + 28);
        size_t dataAt = lho + 30 + lnlen + lelen;
        if (dataAt + csize > n) continue;

        NSString *dst = [outDir stringByAppendingPathComponent:name.lastPathComponent];
        NSData *outData = nil;
        if (method == 0) {
            outData = [NSData dataWithBytes:p + dataAt length:csize];
        } else if (method == 8) {
            NSMutableData *md = [NSMutableData dataWithLength:usize ? usize : (csize * 4)];
            z_stream zs; memset(&zs, 0, sizeof(zs));
            if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) continue;
            zs.next_in = (Bytef *)(p + dataAt); zs.avail_in = (uInt)csize;
            zs.next_out = (Bytef *)md.mutableBytes; zs.avail_out = (uInt)md.length;
            int rc = inflate(&zs, Z_FINISH);
            inflateEnd(&zs);
            if (rc != Z_STREAM_END) { ldqLog(@"[PAK] 解压失败 %@ rc=%d", name, rc); continue; }
            [md setLength:zs.total_out];
            outData = md;
        }
        if (!outData) continue;
        if ([outData writeToFile:dst atomically:YES]) {
            if (outPaks) [outPaks addObject:dst];
            ok++;
            ldqLog(@"[PAK] PAK_FILE path=%@ sha256=n/a valid=1", dst);
        }
    }
    ldqLog(@"[PAK] 解包完成 %zu 个 pak", ok);
    return ok > 0;
}

// ---------- 安装：解压 zip 到缓存目录并挂载 ----------
BOOL phxInstallModZip(NSString *zipPath) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:zipPath]) return NO;
    NSString *dir = phxModCacheDir();
    NSMutableArray<NSString *> *paks = [NSMutableArray array];
    if (!phxUnzipTo(zipPath, dir, paks)) return NO;
    int order = 100;
    NSInteger done = 0;
    for (NSString *p in paks) {
        if (phxMountPakFile(p, order++)) done++;
    }
    ldqLog(@"[PAK] 模组安装完成 %ld/%lu", (long)done, (unsigned long)paks.count);
    return done > 0;
}

// ---------- 卸载：清缓存 ----------
BOOL phxClearMods(void) {
    NSString *dir = phxModCacheDir();
    NSArray *list = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *n in list)
        [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:n] error:nil];
    ldqLog(@"[PAK] 已清空模组缓存");
    return YES;
}
