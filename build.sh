#!/bin/bash
set -e
# 凤凰 iOS 插件编译脚本（GitHub Actions macOS runner 上执行）
# entry.mm + webui_part.mm 拼成同一个编译单元，共用 static 函数

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "SDK: $SDK"

# 拼接：网页桥要调用 entry.mm 里的 static 函数，必须同一 TU
cat entry.mm ark_bridge.mm phoenix_core.mm pak_mount.mm webui_part.mm > LD_iOS_Aim_all.mm
wc -l LD_iOS_Aim_all.mm

clang -target arm64-apple-ios12.0 \
  -isysroot "$SDK" \
  -fobjc-arc \
  -O2 \
  -Wno-deprecated-declarations \
  -dynamiclib \
  -o LD_iOS_Aim.dylib \
  LD_iOS_Aim_all.mm \
  -framework UIKit -framework Foundation -framework WebKit -framework CoreGraphics -lc++ -lz

codesign -s - --force LD_iOS_Aim.dylib
echo "BUILD OK:"
ls -la LD_iOS_Aim.dylib
file LD_iOS_Aim.dylib
