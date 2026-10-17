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
flutter --version

echo "=== Membangun Flutter Web Release ==="
flutter build web --release

echo "=== Berhasil! Hasil build siap di folder build/web ==="
