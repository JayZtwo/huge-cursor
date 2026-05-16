#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Shake Cursor.xcodeproj"
SCHEME="Shake Cursor"
APP_NAME="Shake Cursor"
ENTITLEMENTS_PATH="$ROOT_DIR/Shake Cursor/ShakeCursor.entitlements"

DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$DIST_DIR/build"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
STAGE_DIR="$BUILD_DIR/dmg-stage"
APP_ICONSET_DIR="$ROOT_DIR/Shake Cursor/Assets.xcassets/AppIcon.appiconset"
VOLUME_ICON_PATH="$BUILD_DIR/VolumeIcon.icns"

NOTARY_PROFILE="${NOTARY_PROFILE:-shake-cursor-notary}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
DEVELOPER_ID_INSTALLER="${DEVELOPER_ID_INSTALLER:-Developer ID Installer}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
DMG_VOLUME_NAME="Shake Cursor"
DMG_WINDOW_WIDTH=720
DMG_WINDOW_HEIGHT=420

fail() {
    echo "error: $*" >&2
    exit 1
}

set_file_attr() {
    if command -v SetFile >/dev/null; then
        SetFile "$@"
    fi
}

find_developer_id_application() {
    security find-identity -v -p codesigning \
        | sed -nE 's/^.*"([^"]*Developer ID Application[^"]*)".*$/\1/p' \
        | head -n 1
}

require_tools() {
    command -v xcodebuild >/dev/null || fail "xcodebuild not found"
    command -v hdiutil >/dev/null || fail "hdiutil not found"
    command -v productbuild >/dev/null || fail "productbuild not found"
    command -v codesign >/dev/null || fail "codesign not found"
    command -v xcrun >/dev/null || fail "xcrun not found"
    command -v iconutil >/dev/null || fail "iconutil not found"
}

require_signing_identities() {
    [[ -n "$APPLE_TEAM_ID" ]] || fail "APPLE_TEAM_ID is required for Developer ID signing. Example: APPLE_TEAM_ID=TEAMID ./scripts/package_release.sh"

    if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
        DEVELOPER_ID_APPLICATION="$(find_developer_id_application)"
    fi

    [[ -n "$DEVELOPER_ID_APPLICATION" ]] || fail "Developer ID Application certificate not found. Install it in Xcode Settings > Accounts > Manage Certificates."

    security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null \
        || fail "Developer ID Application identity not available in keychain: $DEVELOPER_ID_APPLICATION"

    security find-certificate -a -c "$DEVELOPER_ID_INSTALLER" >/dev/null 2>&1 \
        || fail "Developer ID Installer certificate not found. Install it in Xcode Settings > Accounts > Manage Certificates."

    if [[ "$SKIP_NOTARIZE" != "1" ]]; then
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
            || fail "Notary keychain profile '$NOTARY_PROFILE' is unavailable. Run scripts/store_notary_credentials.sh first."
    fi
}

build_release_app() {
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR" "$DIST_DIR"

    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -destination "generic/platform=macOS" \
        clean build \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
        CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
        OTHER_CODE_SIGN_FLAGS="--timestamp"

    APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"
    [[ -d "$APP_PATH" ]] || fail "Release app not found at $APP_PATH"

    codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS_PATH" --sign "$DEVELOPER_ID_APPLICATION" "$APP_PATH"
    codesign --verify --strict --verbose=2 "$APP_PATH"
}

read_app_version() {
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")"
    RELEASE_BASENAME="Shake-Cursor-${VERSION}-${BUILD_NUMBER}"
    DMG_PATH="$DIST_DIR/${RELEASE_BASENAME}.dmg"
    PKG_PATH="$DIST_DIR/${RELEASE_BASENAME}.pkg"
}

create_dmg() {
    local tmp_dmg="$BUILD_DIR/${RELEASE_BASENAME}-rw.dmg"
    local mounted_path=""

    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR/.background"
    cp -R "$APP_PATH" "$STAGE_DIR/"
    ln -s /Applications "$STAGE_DIR/Applications"
    create_dmg_background "$STAGE_DIR/.background/background.png"
    create_volume_icon
    cp "$VOLUME_ICON_PATH" "$STAGE_DIR/.VolumeIcon.icns"
    chflags hidden "$STAGE_DIR/.background" "$STAGE_DIR/.VolumeIcon.icns"

    if [[ -d "/Volumes/$DMG_VOLUME_NAME" ]]; then
        hdiutil detach "/Volumes/$DMG_VOLUME_NAME" -quiet || true
    fi

    rm -f "$tmp_dmg" "$DMG_PATH"
    hdiutil create \
        -volname "$DMG_VOLUME_NAME" \
        -srcfolder "$STAGE_DIR" \
        -fs HFS+ \
        -ov \
        -format UDRW \
        "$tmp_dmg"

    mounted_path="$(hdiutil attach "$tmp_dmg" -readwrite -noautoopen -noverify \
        | sed -n 's|^/dev/[^[:space:]]*[[:space:]].*[[:space:]]\(/Volumes/.*\)$|\1|p' \
        | tail -n 1)"
    [[ -n "$mounted_path" && -d "$mounted_path" ]] || fail "Unable to mount temporary DMG."

    cp "$VOLUME_ICON_PATH" "$mounted_path/.VolumeIcon.icns"
    set_file_attr -c icnC "$mounted_path/.VolumeIcon.icns" 2>/dev/null || true
    set_file_attr -a C "$mounted_path" 2>/dev/null || true
    set_file_attr -a V "$mounted_path/.VolumeIcon.icns" 2>/dev/null || true
    configure_dmg_window "$mounted_path"
    cp "$VOLUME_ICON_PATH" "$mounted_path/.VolumeIcon.icns"
    set_file_attr -c icnC "$mounted_path/.VolumeIcon.icns" 2>/dev/null || true
    set_file_attr -a C "$mounted_path" 2>/dev/null || true
    set_file_attr -a V "$mounted_path/.VolumeIcon.icns" 2>/dev/null || true
    sync
    hdiutil detach "$mounted_path" -quiet || hdiutil detach "$mounted_path" -force -quiet

    hdiutil convert "$tmp_dmg" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$DMG_PATH"

    apply_dmg_file_icon "$VOLUME_ICON_PATH"
    codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
}

create_volume_icon() {
    local iconset_dir="$BUILD_DIR/VolumeIcon.iconset"

    [[ -d "$APP_ICONSET_DIR" ]] || fail "App icon set not found at $APP_ICONSET_DIR"
    rm -rf "$iconset_dir"
    mkdir -p "$iconset_dir"

    cp "$APP_ICONSET_DIR/AppIcon-16x16@1x.png" "$iconset_dir/icon_16x16.png"
    cp "$APP_ICONSET_DIR/AppIcon-16x16@2x.png" "$iconset_dir/icon_16x16@2x.png"
    cp "$APP_ICONSET_DIR/AppIcon-32x32@1x.png" "$iconset_dir/icon_32x32.png"
    cp "$APP_ICONSET_DIR/AppIcon-32x32@2x.png" "$iconset_dir/icon_32x32@2x.png"
    cp "$APP_ICONSET_DIR/AppIcon-128x128@1x.png" "$iconset_dir/icon_128x128.png"
    cp "$APP_ICONSET_DIR/AppIcon-128x128@2x.png" "$iconset_dir/icon_128x128@2x.png"
    cp "$APP_ICONSET_DIR/AppIcon-256x256@1x.png" "$iconset_dir/icon_256x256.png"
    cp "$APP_ICONSET_DIR/AppIcon-256x256@2x.png" "$iconset_dir/icon_256x256@2x.png"
    cp "$APP_ICONSET_DIR/AppIcon-512x512@1x.png" "$iconset_dir/icon_512x512.png"
    cp "$APP_ICONSET_DIR/AppIcon-512x512@2x.png" "$iconset_dir/icon_512x512@2x.png"

    iconutil -c icns "$iconset_dir" -o "$VOLUME_ICON_PATH"
    [[ -f "$VOLUME_ICON_PATH" ]] || fail "Unable to create volume icon."
}

mask_iconset_background() {
    local iconset_dir="$1"
    local script_path="$BUILD_DIR/mask_iconset_background.swift"

    cat > "$script_path" <<'SWIFT'
import AppKit
import CoreGraphics

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
let pngURLs = (try fileManager.contentsOfDirectory(at: iconsetURL, includingPropertiesForKeys: nil))
    .filter { $0.pathExtension.lowercased() == "png" }

func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

for url in pngURLs {
    guard let source = NSImage(contentsOf: url),
          let tiff = source.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let cgImage = bitmap.cgImage else {
        fatalError("Unable to read \(url.path)")
    }

    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Unable to create bitmap context")
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    let size = CGFloat(min(width, height))
    let inset = size * 0.092
    let radius = size * 0.190
    let feather = max(1.5, size * 0.012)
    let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
    let half = CGSize(width: CGFloat(width) / 2 - inset, height: CGFloat(height) / 2 - inset)
    let inner = CGSize(width: half.width - radius, height: half.height - radius)

    for y in 0..<height {
        for x in 0..<width {
            let px = abs(CGFloat(x) + 0.5 - center.x) - inner.width
            let py = abs(CGFloat(y) + 0.5 - center.y) - inner.height
            let outsideX = max(px, 0)
            let outsideY = max(py, 0)
            let signedDistance = hypot(outsideX, outsideY) + min(max(px, py), 0) - radius
            let keep = 1 - smoothstep(-feather, feather, signedDistance)
            let offset = y * bytesPerRow + x * bytesPerPixel
            pixels[offset + 0] = UInt8(CGFloat(pixels[offset + 0]) * keep)
            pixels[offset + 1] = UInt8(CGFloat(pixels[offset + 1]) * keep)
            pixels[offset + 2] = UInt8(CGFloat(pixels[offset + 2]) * keep)
            pixels[offset + 3] = UInt8(CGFloat(pixels[offset + 3]) * keep)
        }
    }

    guard let outputContext = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let outputImage = outputContext.makeImage() else {
        fatalError("Unable to create output image")
    }

    let outputRep = NSBitmapImageRep(cgImage: outputImage)
    guard let png = outputRep.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode png")
    }
    try png.write(to: url)
}
SWIFT

    xcrun swift "$script_path" "$iconset_dir"
}

apply_dmg_file_icon() {
    local icon_path="$1"
    local script_path="$BUILD_DIR/apply_dmg_file_icon.swift"

    cat > "$script_path" <<'SWIFT'
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: apply_dmg_file_icon.swift <icon.icns> <target.dmg>\n", stderr)
    exit(64)
}

let iconPath = args[1]
let targetPath = args[2]

guard FileManager.default.fileExists(atPath: targetPath) else {
    fputs("target file does not exist: \(targetPath)\n", stderr)
    exit(66)
}

guard let image = NSImage(contentsOfFile: iconPath) else {
    fputs("unable to read icon: \(iconPath)\n", stderr)
    exit(65)
}

if !NSWorkspace.shared.setIcon(image, forFile: targetPath, options: []) {
    fputs("NSWorkspace failed to set custom icon for: \(targetPath)\n", stderr)
    exit(1)
}
SWIFT

    if xcrun swift "$script_path" "$icon_path" "$DMG_PATH"; then
        set_file_attr -a C "$DMG_PATH" 2>/dev/null || true
        /usr/bin/qlmanage -r >/dev/null 2>&1 || true
    else
        echo "warning: unable to apply a custom Finder icon to the .dmg file itself; mounted volume icon is still set."
    fi
}

create_dmg_background() {
    local output_path="$1"
    local script_path="$BUILD_DIR/make_dmg_background.swift"

    cat > "$script_path" <<'SWIFT'
import AppKit

let outputPath = CommandLine.arguments[1]
let size = NSSize(width: 720, height: 420)
let image = NSImage(size: size)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func drawRoundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func drawText(_ text: String, rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .center) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = .byWordWrapping
    (text as NSString).draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
    )
}

image.lockFocus()
let bounds = NSRect(origin: .zero, size: size)
NSGradient(colors: [
    color(248, 247, 252),
    color(239, 236, 250),
    color(255, 255, 255)
])?.draw(in: bounds, angle: -18)

drawRoundedRect(
    NSRect(x: 28, y: 28, width: 664, height: 364),
    radius: 30,
    fill: color(255, 255, 255, 0.62),
    stroke: color(154, 134, 255, 0.16),
    lineWidth: 1
)

let glow = NSBezierPath(ovalIn: NSRect(x: 244, y: 82, width: 232, height: 232))
color(124, 92, 255, 0.10).setFill()
glow.fill()

for index in 0..<34 {
    let x = CGFloat((index * 83) % 620 + 50)
    let y = CGFloat((index * 47) % 290 + 64)
    let radius = CGFloat(1 + (index % 4))
    let path = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: radius, height: radius))
    color(132, 104, 255, CGFloat(index % 3 == 0 ? 0.25 : 0.13)).setFill()
    path.fill()
}

drawText(
    "Shake Cursor",
    rect: NSRect(x: 0, y: 326, width: 720, height: 36),
    font: .systemFont(ofSize: 26, weight: .semibold),
    color: color(42, 38, 56)
)
drawText(
    "Drag to Applications, then open from Launchpad or Finder.",
    rect: NSRect(x: 0, y: 298, width: 720, height: 24),
    font: .systemFont(ofSize: 13, weight: .medium),
    color: color(100, 94, 116)
)

drawRoundedRect(
    NSRect(x: 90, y: 126, width: 160, height: 150),
    radius: 26,
    fill: color(255, 255, 255, 0.62),
    stroke: color(135, 116, 245, 0.16)
)
drawRoundedRect(
    NSRect(x: 470, y: 126, width: 160, height: 150),
    radius: 26,
    fill: color(255, 255, 255, 0.62),
    stroke: color(135, 116, 245, 0.16)
)

drawText(
    "Shake Cursor",
    rect: NSRect(x: 90, y: 76, width: 160, height: 22),
    font: .systemFont(ofSize: 13, weight: .semibold),
    color: color(76, 63, 116)
)
drawText(
    "Applications",
    rect: NSRect(x: 470, y: 76, width: 160, height: 22),
    font: .systemFont(ofSize: 13, weight: .semibold),
    color: color(76, 63, 116)
)

let arrowStyle = NSMutableParagraphStyle()
arrowStyle.alignment = .center
("→" as NSString).draw(
    with: NSRect(x: 298, y: 172, width: 124, height: 72),
    options: [.usesLineFragmentOrigin],
    attributes: [
        .font: NSFont.systemFont(ofSize: 54, weight: .thin),
        .foregroundColor: color(112, 88, 245, 0.62),
        .paragraphStyle: arrowStyle
    ]
)

drawText(
    "Shake the cursor anywhere to summon your assistant.",
    rect: NSRect(x: 0, y: 36, width: 720, height: 22),
    font: .systemFont(ofSize: 12, weight: .regular),
    color: color(120, 114, 135)
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to render DMG background")
}
try png.write(to: URL(fileURLWithPath: outputPath))
SWIFT

    xcrun swift "$script_path" "$output_path"
}

configure_dmg_window() {
    local mounted_path="$1"

    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DMG_VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {160, 120, 880, 540}
        set theOptions to icon view options of container window
        set arrangement of theOptions to not arranged
        set icon size of theOptions to 96
        set background picture of theOptions to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {170, 215}
        set position of item "Applications" of container window to {550, 215}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

    set_file_attr -a V "$mounted_path/.background" 2>/dev/null || true
}

create_pkg() {
    productbuild \
        --component "$APP_PATH" /Applications \
        --sign "$DEVELOPER_ID_INSTALLER" \
        "$PKG_PATH"
}

notarize_and_staple() {
    if [[ "$SKIP_NOTARIZE" == "1" ]]; then
        echo "warning: SKIP_NOTARIZE=1, artifacts are not suitable for external distribution."
        return
    fi

    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"

    xcrun notarytool submit "$PKG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG_PATH"
    xcrun stapler validate "$PKG_PATH"
    spctl -a -vv -t install "$PKG_PATH"
}

main() {
    require_tools
    require_signing_identities
    echo "Packaging Shake Cursor for Developer ID distribution. This is not an App Store Connect upload."
    build_release_app
    read_app_version
    create_dmg
    create_pkg
    notarize_and_staple

    echo
    echo "Release artifacts:"
    echo "  $DMG_PATH"
    echo "  $PKG_PATH"
}

main "$@"
