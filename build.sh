#!/bin/bash
# LiveCaption · © 2026 IEF Software · iefsoftware.tr
# MIT Lisansı — bkz. LICENSE.
#
# SPM ile derler, sonucu çalıştırılabilir bir .app paketine sarar.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="LiveCaption"
BUNDLE="build/${APP_NAME}.app"
CONFIG="${1:-release}"

echo "▸ Derleniyor (${CONFIG})…"
swift build -c "${CONFIG}"

BIN="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [ ! -f "${BIN}" ]; then
  echo "✖ Çalıştırılabilir bulunamadı: ${BIN}" >&2
  exit 1
fi

echo "▸ .app paketi hazırlanıyor…"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

echo "▸ İmzalanıyor (ad-hoc)…"
codesign --force --sign - --identifier tr.iefsoftware.livecaption "${BUNDLE}" 2>/dev/null \
  || echo "  (imzalama atlandı)"

# Kullanıcı .app'i Masaüstü'ne taşıdıysa oradaki kopyayı da güncelle —
# Ekran Kaydı izni o yola verilmiş olur.
INSTALLED="$HOME/Desktop/${APP_NAME}.app"
if [ -d "${INSTALLED}" ]; then
  echo "▸ Masaüstündeki kopya güncelleniyor: ${INSTALLED}"
  rm -rf "${INSTALLED}"
  cp -R "${BUNDLE}" "${INSTALLED}"
  codesign --force --sign - --identifier tr.iefsoftware.livecaption "${INSTALLED}" 2>/dev/null || true
fi

echo "✔ Hazır: ${BUNDLE}"
echo
echo "Çalıştır:  open ${BUNDLE}"
echo "Logla:     ${BUNDLE}/Contents/MacOS/${APP_NAME}"
