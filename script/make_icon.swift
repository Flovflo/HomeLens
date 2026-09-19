// Renders the HomeLens app icon and the DMG background with native SwiftUI
// (continuous-corner squircle, system gradients), so the assets are reproducible
// and look at home on macOS. No image editor involved.
//
//   swift script/make_icon.swift            # writes Assets/Generated/*.png
//   ./script/make_icon.sh                   # ... then iconset -> Assets/HomeLens.icns
import AppKit
import SwiftUI

// Apple's macOS icon grid: 1024 canvas, 824 pt squircle centered, shadow included.
struct AppIcon: View {
    let canvas: CGFloat = 1024
    var body: some View {
        let side: CGFloat = 824
        ZStack {
            Color.clear
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 1.0),
                                                  Color(red: 0.07, green: 0.20, blue: 0.56)],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.0)],
                                                 startPoint: .top, endPoint: .center), lineWidth: 6)
                HouseLens(size: side)
            }
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.32), radius: 22, x: 0, y: 14)
        }
        .frame(width: canvas, height: canvas)
    }
}

// A house drawn as one bold stroke, with a lens set into its facade.
struct HouseLens: View {
    let size: CGFloat
    var body: some View {
        let stroke = size * 0.072
        let lens = size * 0.30
        ZStack {
            HouseShape()
                .stroke(Color.white, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.62, height: size * 0.56)
                .offset(y: size * 0.03)
                .shadow(color: .black.opacity(0.18), radius: size * 0.012, y: size * 0.008)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.55, green: 0.78, blue: 1.0),
                                              Color(red: 0.05, green: 0.12, blue: 0.36)],
                                     center: UnitPoint(x: 0.38, y: 0.34), startRadius: 0, endRadius: lens * 0.62))
                .frame(width: lens, height: lens)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: stroke * 0.55))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: stroke * 0.18)
                    .padding(stroke * 0.95))
                .overlay(Circle().fill(Color.white.opacity(0.85))
                    .frame(width: lens * 0.13, height: lens * 0.13)
                    .offset(x: -lens * 0.17, y: -lens * 0.19))
                .offset(y: size * 0.10)
                .shadow(color: .black.opacity(0.25), radius: size * 0.012, y: size * 0.006)
        }
    }
}

struct HouseShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let apex = CGPoint(x: r.midX, y: r.minY)
        let eaveY = r.minY + r.height * 0.42
        p.move(to: CGPoint(x: r.minX, y: eaveY))
        p.addLine(to: apex)
        p.addLine(to: CGPoint(x: r.maxX, y: eaveY))
        // Walls hang from just inside the eaves.
        let inset = r.width * 0.12
        p.move(to: CGPoint(x: r.minX + inset, y: eaveY - r.height * 0.11))
        p.addLine(to: CGPoint(x: r.minX + inset, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - inset, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - inset, y: eaveY - r.height * 0.11))
        return p
    }
}

// DMG window background (660 x 400 pt): app on the left, arrow, Applications on the right.
struct DMGBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.97, green: 0.97, blue: 0.985), Color(red: 0.90, green: 0.92, blue: 0.97)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Text("HomeLens")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.10, green: 0.16, blue: 0.32))
                    .padding(.top, 34)
                Text("Glissez HomeLens dans Applications")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color(red: 0.10, green: 0.16, blue: 0.32).opacity(0.65))
                    .padding(.top, 6)
                Spacer()
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color(red: 0.10, green: 0.16, blue: 0.32).opacity(0.35))
                .offset(y: 16)
        }
        .frame(width: 660, height: 400)
    }
}

// GitHub social preview (1280 x 640): icon + one-line pitch. Upload manually in
// repository Settings → Social preview (GitHub has no API for it).
struct SocialPreview: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.10, blue: 0.24), Color(red: 0.03, green: 0.05, blue: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 56) {
                AppIcon().frame(width: 1024, height: 1024).scaleEffect(0.36).frame(width: 370, height: 370)
                VStack(alignment: .leading, spacing: 18) {
                    Text("HomeLens")
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Your Reolink camera in Apple Home.\nLive video + audio, HomeKit Secure Video,\noriginal 4K quality. Native macOS.")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(6)
                }
            }
            .padding(.horizontal, 80)
        }
        .frame(width: 1280, height: 640)
    }
}

@MainActor
func write<V: View>(_ view: V, scale: CGFloat, to path: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.cgImage else { fatalError("render failed: \(path)") }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png failed") }
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) \(cg.width)x\(cg.height)")
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let out = root.appendingPathComponent("Assets/Generated").path
try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    write(AppIcon(), scale: 1, to: "\(out)/HomeLensIcon.png")
    write(DMGBackground(), scale: 1, to: "\(out)/dmg-background.png")
    write(DMGBackground(), scale: 2, to: "\(out)/dmg-background@2x.png")
    write(SocialPreview(), scale: 1, to: "\(out)/social-preview.png")
}
