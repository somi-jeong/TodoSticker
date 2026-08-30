#!/bin/bash
# Todo Sticker 빌드 스크립트
# 참고: CLT의 중복 modulemap 버그(SwiftBridging redefinition)를 vfsoverlay로 우회함
set -e
cd "$(dirname "$0")"
sed "s|empty.modulemap|$PWD/empty.modulemap|" overlay.yaml > /tmp/todosticker-overlay.yaml
swiftc -O -swift-version 5 \
  -vfsoverlay /tmp/todosticker-overlay.yaml \
  -Xcc -ivfsoverlay -Xcc /tmp/todosticker-overlay.yaml \
  main.swift -o TodoSticker
mkdir -p "Todo Sticker.app/Contents/MacOS"
cp TodoSticker "Todo Sticker.app/Contents/MacOS/TodoSticker"
codesign --force -s - "Todo Sticker.app"
echo "빌드 완료. 실행: open 'Todo Sticker.app'"
