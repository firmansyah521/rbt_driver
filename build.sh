#!/bin/bash
set -e

echo "=== Mempersiapkan Flutter SDK di Vercel Build Server ==="
if [ ! -d "$HOME/flutter" ]; then
  echo "Mengunduh Flutter SDK (stable)..."
  git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"
else
  echo "Menggunakan cache Flutter SDK..."
fi

export PATH="$PATH:$HOME/flutter/bin"

echo "=== Memeriksa Flutter ==="
git config --global --add safe.directory "*"
flutter config --no-analytics
flutter --version

echo "=== Membangun Flutter Web Release ==="
flutter pub get
flutter build web --release --base-href /

echo "=== Berhasil! Hasil build siap di folder build/web ==="
