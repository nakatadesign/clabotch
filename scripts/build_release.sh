#!/usr/bin/env bash
# scripts/build_release.sh — Release ビルド + DMG 作成 + Notarization
#
# 使い方:
#   ./scripts/build_release.sh                    # ビルド + DMG（署名付き）
#   ./scripts/build_release.sh --unsigned         # ビルド + DMG（署名なし、テスト用）
#   ./scripts/build_release.sh --notarize         # ビルド + DMG + Notarization（環境変数方式）
#   ./scripts/build_release.sh --notarize --keychain-profile PROFILE
#                                                 # ビルド + DMG + Notarization（keychain profile 方式）
#   ./scripts/build_release.sh --skip-build       # DMG のみ（ビルド済み前提）
#   ./scripts/build_release.sh --verify-only      # 既存 DMG の署名 / Gatekeeper 検証のみ
#
# 前提条件:
#   - xcodegen がインストール済み
#   - Developer ID Application 証明書がキーチェーンにインストール済み
#   - DEVELOPMENT_TEAM 環境変数（Apple Developer Team ID）
#   - Notarization 時（環境変数方式）:
#       NOTARIZE_APPLE_ID, NOTARIZE_TEAM_ID, NOTARIZE_PASSWORD
#   - Notarization 時（keychain profile 方式）:
#       事前に xcrun notarytool store-credentials <PROFILE> で登録済み
#
# 出力:
#   dist/Clabotch-<version>.dmg
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${REPO_ROOT}/src"
DIST_DIR="${REPO_ROOT}/dist"
BUILD_DIR="${REPO_ROOT}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"

# オプション解析
NOTARIZE=false
SKIP_BUILD=false
UNSIGNED=false
VERIFY_ONLY=false
KEYCHAIN_PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize) NOTARIZE=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --unsigned) UNSIGNED=true; shift ;;
    --verify-only) VERIFY_ONLY=true; shift ;;
    --keychain-profile)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --keychain-profile にはプロファイル名が必要です" >&2
        exit 1
      fi
      KEYCHAIN_PROFILE="$2"; shift 2 ;;
    --help|-h)
      echo "使い方: ./scripts/build_release.sh [OPTIONS]"
      echo ""
      echo "  (なし)                 署名付きビルド + DMG"
      echo "  --unsigned             署名なしビルド + DMG（テスト用）"
      echo "  --notarize             ビルド + DMG + Notarization"
      echo "  --keychain-profile P   Notarization に keychain profile を使用"
      echo "  --skip-build           DMG のみ作成（ビルド済み前提）"
      echo "  --verify-only          既存成果物の署名 / Gatekeeper 検証"
      echo ""
      echo "前提: DEVELOPMENT_TEAM 環境変数（署名ビルド時）"
      echo "詳細: docs/DISTRIBUTION.md"
      exit 0
      ;;
    *) echo "ERROR: 不明なオプション: $1" >&2; exit 1 ;;
  esac
done

if [[ "${UNSIGNED}" == "true" && "${NOTARIZE}" == "true" ]]; then
  echo "ERROR: --unsigned と --notarize は同時に指定できません" >&2
  exit 1
fi

# バージョン取得
VERSION="$(grep 'MARKETING_VERSION:' "${SRC_DIR}/project.yml" | head -1 | awk -F'"' '{print $2}')"
if [[ -z "${VERSION}" ]]; then
  echo "ERROR: MARKETING_VERSION を project.yml から取得できません" >&2
  exit 1
fi
echo "==> Clabotch v${VERSION}"

# --verify-only モード
# 終了コード: 成果物欠損または codesign 検証 NG があれば 1。
# Gatekeeper / Staple は情報表示のみ（ad-hoc 配布では NG が正常のため）。
if [[ "${VERIFY_ONLY}" == "true" ]]; then
  DMG_PATH="${DIST_DIR}/Clabotch-${VERSION}.dmg"
  APP_PATH="${BUILD_DIR}/app/Clabotch.app"
  VERIFY_FAILED=0

  echo "==> 検証モード"
  if [[ -d "${APP_PATH}" ]]; then
    echo "==> .app コード署名検証"
    if codesign --verify --deep --strict "${APP_PATH}" 2>/dev/null; then
      echo "    署名: OK"
      codesign -dvv "${APP_PATH}" 2>&1 | grep -E "^(Authority|TeamIdentifier)" || true
    else
      echo "    署名: NG"
      VERIFY_FAILED=1
    fi
    echo "==> .app Gatekeeper 検証（情報表示のみ）"
    if spctl --assess --type execute "${APP_PATH}" 2>&1; then
      echo "    Gatekeeper (.app): OK"
    else
      echo "    Gatekeeper (.app): NG（ad-hoc 署名では正常。公証済みなら要調査）"
    fi
  else
    echo "    .app が見つかりません: ${APP_PATH}"
    VERIFY_FAILED=1
  fi
  if [[ -f "${DMG_PATH}" ]]; then
    echo "==> DMG Gatekeeper 検証（情報表示のみ）"
    if spctl --assess --type open --context context:primary-signature "${DMG_PATH}" 2>&1; then
      echo "    Gatekeeper: OK"
    else
      echo "    Gatekeeper: NG（notarization 未適用、または署名不備）"
    fi
    echo "==> Staple 確認"
    xcrun stapler validate "${DMG_PATH}" 2>&1 || echo "    Staple: 未適用"
  else
    echo "    DMG が見つかりません: ${DMG_PATH}"
    VERIFY_FAILED=1
  fi

  if [[ "${VERIFY_FAILED}" -ne 0 ]]; then
    echo "ERROR: 検証 NG（成果物欠損または署名不正）" >&2
  fi
  exit "${VERIFY_FAILED}"
fi

# DEVELOPMENT_TEAM チェック（署名ビルドを実際に行うときのみ）
# --skip-build は既存の署名済み .app から DMG を作るだけなので Team ID 不要
if [[ "${UNSIGNED}" == "false" && "${SKIP_BUILD}" == "false" ]]; then
  if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "ERROR: DEVELOPMENT_TEAM 環境変数が設定されていません" >&2
    echo "  export DEVELOPMENT_TEAM=\"YOUR_TEAM_ID\"" >&2
    echo "  Apple Developer の Membership ページで確認できます" >&2
    exit 1
  fi
fi

# Notarization の認証情報チェック
if [[ "${NOTARIZE}" == "true" ]]; then
  if [[ -n "${KEYCHAIN_PROFILE}" ]]; then
    echo "    認証方式: keychain profile (${KEYCHAIN_PROFILE})"
  else
    for var in NOTARIZE_APPLE_ID NOTARIZE_TEAM_ID NOTARIZE_PASSWORD; do
      if [[ -z "${!var:-}" ]]; then
        echo "ERROR: ${var} が設定されていません" >&2
        echo "  --keychain-profile を使うか、環境変数を設定してください" >&2
        echo "  詳細: docs/DISTRIBUTION.md" >&2
        exit 1
      fi
    done
    echo "    認証方式: 環境変数"
  fi
fi

# ビルド
if [[ "${SKIP_BUILD}" == "false" ]]; then
  echo "==> xcodegen generate"
  (cd "${SRC_DIR}" && xcodegen generate)

  # 署名オプション
  SIGN_ARGS=()
  if [[ "${UNSIGNED}" == "true" ]]; then
    SIGN_ARGS+=(CODE_SIGNING_ALLOWED=NO)
    echo "==> Release ビルド（署名なし）"
  else
    SIGN_ARGS+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}")
    echo "==> Release ビルド（署名付き, Team=${DEVELOPMENT_TEAM}）"
  fi

  xcodebuild archive \
    -project "${SRC_DIR}/Clabotch.xcodeproj" \
    -scheme Clabotch \
    -configuration Release \
    -archivePath "${BUILD_DIR}/Clabotch.xcarchive" \
    -derivedDataPath "${DERIVED_DATA}" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    "${SIGN_ARGS[@]}" \
    | tail -5

  echo "==> .app をエクスポート"
  mkdir -p "${BUILD_DIR}/app"
  rm -rf "${BUILD_DIR}/app/Clabotch.app"
  cp -R "${BUILD_DIR}/Clabotch.xcarchive/Products/Applications/Clabotch.app" \
        "${BUILD_DIR}/app/Clabotch.app"
else
  echo "==> ビルドスキップ（既存の .app を使用）"
  if [[ ! -d "${BUILD_DIR}/app/Clabotch.app" ]]; then
    echo "ERROR: ${BUILD_DIR}/app/Clabotch.app が見つかりません" >&2
    exit 1
  fi
fi

APP_PATH="${BUILD_DIR}/app/Clabotch.app"

# unsigned モード: ad-hoc 再署名でバンドルを封印する。
# CODE_SIGNING_ALLOWED=NO の出力は linker 署名のみで Sealed Resources がなく、
# Apple Silicon では「壊れている」扱いされ得る（旧手順では手動で再署名していた）。
if [[ "${UNSIGNED}" == "true" ]]; then
  echo "==> ad-hoc 再署名（unsigned モード）"
  codesign --force --deep -s - "${APP_PATH}"
fi

# コード署名の検証（NG は配布物を作らず即失敗）
echo "==> コード署名を検証"
if ! codesign --verify --deep --strict "${APP_PATH}" 2>/dev/null; then
  echo "ERROR: コード署名の検証に失敗しました。DMG 作成を中止します" >&2
  if [[ "${UNSIGNED}" == "false" ]]; then
    echo "  Developer ID 証明書と DEVELOPMENT_TEAM を確認してください" >&2
  fi
  exit 1
fi
echo "    署名: OK"
codesign -dvv "${APP_PATH}" 2>&1 | grep -E "^(Authority|TeamIdentifier|Signature)" || true

# Gatekeeper 事前検証（署名済みの場合）
if [[ "${UNSIGNED}" == "false" ]]; then
  echo "==> Gatekeeper 事前検証（.app）"
  if spctl --assess --type execute "${APP_PATH}" 2>&1; then
    echo "    Gatekeeper (.app): OK"
  else
    echo "    Gatekeeper (.app): NG（notarization 前は正常）"
  fi
fi

# DMG 作成
mkdir -p "${DIST_DIR}"
DMG_NAME="Clabotch-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
DMG_STAGING="${BUILD_DIR}/dmg-staging"

echo "==> DMG 作成: ${DMG_NAME}"
rm -rf "${DMG_STAGING}" "${DMG_PATH}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_PATH}" "${DMG_STAGING}/"

# hooks + インストーラーを同梱（DMG 利用者が hooks を導入できるように）
mkdir -p "${DMG_STAGING}/hooks"
cp "${REPO_ROOT}/hooks/clabotch_lib.sh" \
   "${REPO_ROOT}/hooks/clabotch_pre_tool.sh" \
   "${REPO_ROOT}/hooks/clabotch_post_tool.sh" \
   "${REPO_ROOT}/hooks/clabotch_post_tool_failure.sh" \
   "${REPO_ROOT}/hooks/clabotch_stop.sh" \
   "${DMG_STAGING}/hooks/"
cp "${REPO_ROOT}/hooks/install.sh" "${DMG_STAGING}/install.sh"

# Applications シンボリックリンク（ドラッグ&ドロップインストール用）
ln -s /Applications "${DMG_STAGING}/Applications"

# volname はバージョンを含めない: README の install 手順パス（/Volumes/Clabotch/…）を
# リリースを跨いで安定させるため
hdiutil create \
  -volname "Clabotch" \
  -srcfolder "${DMG_STAGING}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${DMG_STAGING}"
echo "    DMG: ${DMG_PATH}"
echo "    サイズ: $(du -h "${DMG_PATH}" | awk '{print $1}')"

# Notarization
if [[ "${NOTARIZE}" == "true" ]]; then
  echo "==> Notarization 投入"

  NOTARY_ARGS=("${DMG_PATH}" --wait)
  if [[ -n "${KEYCHAIN_PROFILE}" ]]; then
    NOTARY_ARGS+=(--keychain-profile "${KEYCHAIN_PROFILE}")
  else
    NOTARY_ARGS+=(
      --apple-id "${NOTARIZE_APPLE_ID}"
      --team-id "${NOTARIZE_TEAM_ID}"
      --password "${NOTARIZE_PASSWORD}"
    )
  fi

  xcrun notarytool submit "${NOTARY_ARGS[@]}"

  echo "==> Staple"
  xcrun stapler staple "${DMG_PATH}"

  echo "==> Notarization 後の検証"
  xcrun stapler validate "${DMG_PATH}"
  spctl --assess --type open --context context:primary-signature "${DMG_PATH}" 2>&1 || true

  echo "==> Notarization 完了"
fi

echo ""
echo "=== 完了 ==="
echo "DMG: ${DMG_PATH}"
if [[ "${NOTARIZE}" == "true" ]]; then
  echo "Notarization: stapled"
fi
echo ""
echo "次のステップ:"
echo "  検証: ./scripts/build_release.sh --verify-only"
echo "  配布: ${DMG_PATH} をユーザーに配布"
