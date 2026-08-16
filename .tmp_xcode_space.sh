#!/bin/bash
# 检查 Xcode 安装前可释放空间：只列可安全清理的缓存/临时/派生类
echo "=== 当前可用空间 ==="
df -h / | tail -1

echo ""
echo "=== Xcode 相关可选清理 ==="
echo "· ~/Library/Developer/Xcode（含旧 DerivedData/模拟器，可删）:"
du -sh ~/Library/Developer/Xcode 2>/dev/null || echo "  （无）"
echo "· ~/.swiftpm / 全局缓存:"
du -sh ~/.swiftpm 2>/dev/null || echo "  （无）"

echo ""
echo "=== 常见可清理的大缓存目录 ==="
for d in \
  ~/Library/Application\ Support/Positron \
  ~/Library/Application\ Support/Code \
  ~/Library/Application\ Support/Steam \
  ~/Library/Application\ Support/audacity \
  ~/Library/Application\ Support/Google/Chrome \
  ; do
  if [ -d "$d" ]; then
    size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
    echo "  $size  $d"
  fi
done

echo ""
echo "=== Downloads 里的大文件（可手动删，前 8） ==="
du -sh ~/Downloads/* 2>/dev/null | sort -rh | head -8

echo ""
echo "=== 系统其他大块 ==="
echo "· /Library/Developer（若含旧 CommandLineTools 之外的缓存）:"
du -sh /Library/Developer 2>/dev/null || echo "  （无）"

echo ""
echo "=== 结论提示 ==="
echo "Xcode 需要约 25-30GB 可用空间才稳妥；当前 $(( $(stat -f%z / 2>/dev/null) )) "