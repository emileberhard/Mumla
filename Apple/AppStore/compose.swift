import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let canvas = CGSize(width: 1206, height: 2622)
let captures = URL(filePath: CommandLine.arguments[1])
let output = URL(filePath: CommandLine.arguments[2])
let locale = CommandLine.arguments[3]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func capture(_ name: String) -> NSImage {
    let url = captures.appending(path: "\(name).png")
    guard let image = NSImage(contentsOf: url) else { fail("missing \(url.path)") }
    return image
}

enum Brand {
    static let top = Color(.displayP3, red: 0.478, green: 0.333, blue: 0.941)
    static let bottom = Color(.displayP3, red: 0.180, green: 0.082, blue: 0.565)
    static let amber = Color(.displayP3, red: 1, green: 0.71, blue: 0.28)
    static let pink = Color(.displayP3, red: 1, green: 0.45, blue: 0.64)
}

struct Magnify: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}

extension View {
    func magnified(_ scale: CGFloat) -> some View {
        Magnify(scale: scale) { scaleEffect(scale, anchor: .topLeading) }
    }
}

enum Screen {
    static let size = CGSize(width: 402, height: 874)
    static let cornerRadius: CGFloat = 62
}

struct Phone: View {
    static let scale: CGFloat = 2.2
    static var size: CGSize { CGSize(width: Screen.size.width + 15, height: Screen.size.height + 15) }

    let screen: String

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: Screen.cornerRadius + 7.5, style: .continuous)
        ZStack {
            outer.fill(LinearGradient(colors: [Color(white: 0.44), Color(white: 0.17), Color(white: 0.1), Color(white: 0.32)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            outer.strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
            RoundedRectangle(cornerRadius: Screen.cornerRadius + 5, style: .continuous).fill(.black).padding(2.5)
            Image(nsImage: capture(screen))
                .resizable()
                .interpolation(.high)
                .frame(width: Screen.size.width, height: Screen.size.height)
                .clipShape(RoundedRectangle(cornerRadius: Screen.cornerRadius, style: .continuous))
                .overlay(alignment: .bottom) {
                    Capsule().fill(.black).frame(width: 140, height: 5).padding(.bottom, 8)
                }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .magnified(Self.scale)
        .shadow(color: Color(red: 0.08, green: 0.02, blue: 0.25).opacity(0.5), radius: 60, y: 30)
    }
}

typealias Phrase = (String, Color?)

struct Headline: View {
    let phrases: [Phrase]

    var body: some View {
        let text = phrases.reduce(AttributedString()) { result, phrase in
            var run = AttributedString(phrase.0)
            run.foregroundColor = phrase.1 ?? .white
            return result + run
        }
        Text(text)
            .font(.system(size: 104, weight: .bold).leading(.tight))
            .tracking(-2.4)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

struct Slide: View {
    static let phoneTop: CGFloat = 560

    let headline: [Phrase]
    let screen: String

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Brand.top, Brand.bottom], startPoint: .top, endPoint: .bottom)
            Headline(phrases: headline)
                .frame(height: Self.phoneTop)
            Phone(screen: screen)
                .offset(y: Self.phoneTop)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }
}

let headlines: [String: [[Phrase]]] = [
    "en-US": [
        [("Just ", nil), ("speak", Brand.amber), (".\nIn ", nil), ("any app", Brand.pink), (".", nil)],
        [("Names", Brand.amber), (" spelled\n", nil), ("your way", Brand.pink), (".", nil)],
        [("Every word ", nil), ("kept", Brand.amber), ("\nand ", nil), ("synced", Brand.pink), (".", nil)],
    ],
    "sv": [
        [("Bara ", nil), ("prata", Brand.amber), (".\nI ", nil), ("alla appar", Brand.pink), (".", nil)],
        [("Namn", Brand.amber), (" stavade\n", nil), ("som du vill", Brand.pink), (".", nil)],
        [("Varje ord ", nil), ("sparat", Brand.amber), ("\noch ", nil), ("synkat", Brand.pink), (".", nil)],
    ],
]

guard let localized = headlines[locale] else { fail("compose.swift has no headlines for \(locale)") }
let screens = [("1-keyboard", "keyboard"), ("2-dictionary", "dictionary"), ("3-home", "transcripts")]
let slides = zip(screens, localized).map { screen, headline in (screen.0, Slide(headline: headline, screen: screen.1)) }

MainActor.assumeIsolated {
    var drawn = Set<Data>()
    for (name, slide) in slides {
        let renderer = ImageRenderer(content: slide)
        guard let rendered = renderer.cgImage,
              rendered.width == Int(canvas.width), rendered.height == Int(canvas.height),
              let rgba = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: rendered.width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let context = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { fail("could not render \(name) at \(Int(canvas.width)) × \(Int(canvas.height))") }
        let bounds = CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height)
        rgba.clear(bounds)
        rgba.draw(rendered, in: bounds)
        let pixels = UnsafeBufferPointer(start: rgba.data!.assumingMemoryBound(to: UInt8.self), count: rendered.width * rendered.height * 4)
        guard !stride(from: 3, to: pixels.count, by: 4).contains(where: { pixels[$0] != 255 }) else {
            fail("\(name) rendered with transparent pixels instead of covering its canvas")
        }
        guard drawn.insert(Data(pixels)).inserted else { fail("\(name) rendered the same pixels as an earlier slide") }
        context.draw(rendered, in: bounds)
        let url = output.appending(path: "\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fail("could not create \(url.path)")
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
    }
}
