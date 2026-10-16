import SwiftUI
import XCTest
@testable import Flotilla

/// Words in a tone stay readable: WCAG AA (4.5:1) on the backgrounds lists and
/// badges use, in light and dark mode.
final class ContrastTests: XCTestCase {
    private let light = UITraitCollection(userInterfaceStyle: .light)
    private let dark = UITraitCollection(userInterfaceStyle: .dark)

    private func rgb(_ color: UIColor, _ traits: UITraitCollection) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func luminance(_ c: (Double, Double, Double)) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
    }

    private func ratio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func over(_ tint: (Double, Double, Double), _ base: (Double, Double, Double), _ alpha: Double) -> (Double, Double, Double) {
        (tint.0 * alpha + base.0 * (1 - alpha), tint.1 * alpha + base.1 * (1 - alpha), tint.2 * alpha + base.2 * (1 - alpha))
    }

    private let tones: [Tone] = [.ready, .working, .needsYou, .failed, .quiet, .worker]

    func testToneWordsMeetAAOnListBackgrounds() {
        let backgrounds: [(UITraitCollection, [UIColor])] = [
            (light, [.systemBackground, .systemGroupedBackground, .secondarySystemGroupedBackground]),
            (dark, [.systemBackground, .systemGroupedBackground, .secondarySystemGroupedBackground]),
        ]
        for (traits, colors) in backgrounds {
            for tone in tones {
                let text = rgb(UIColor(tone.text), traits)
                for background in colors {
                    let value = ratio(text, rgb(background, traits))
                    XCTAssertGreaterThanOrEqual(value, 4.5, "\(tone) in \(traits.userInterfaceStyle == .dark ? "dark" : "light") mode: \(value)")
                }
            }
        }
    }

    func testPillWordsMeetAAOnTheirTint() {
        for traits in [light, dark] {
            let card = rgb(.secondarySystemGroupedBackground, traits)
            for tone in tones where tone != .quiet {
                let background = over(rgb(UIColor(tone.color), traits), card, 0.12)
                let value = ratio(rgb(UIColor(tone.text), traits), background)
                XCTAssertGreaterThanOrEqual(value, 4.5, "\(tone) pill in \(traits.userInterfaceStyle == .dark ? "dark" : "light") mode: \(value)")
            }
        }
    }

    /// The permission card's answers (Allow once, Allow for session, Deny) hold
    /// AA in a sheet too: their base is fixed, not the elevated card (QA-004).
    func testAnswerButtonsMeetAAInASheet() {
        let answers: [Tone] = [.ready, .working, .failed]
        for traits in [light, dark] {
            let base = rgb(UIColor(Color.answerBase), traits)
            for tone in answers {
                let background = over(rgb(UIColor(tone.color), traits), base, 0.12)
                let value = ratio(rgb(UIColor(tone.text), traits), background)
                XCTAssertGreaterThanOrEqual(value, 4.5, "\(tone) answer in \(traits.userInterfaceStyle == .dark ? "dark" : "light") mode: \(value)")
            }
        }
    }

    /// Captions, footers, headers and placeholders (Text.placeholder) use one
    /// secondary colour.
    /// It must hold on lists, cards, fills and the orange permission card.
    func testSecondaryTextAndPlaceholdersMeetAA() {
        for traits in [light, dark] {
            let text = rgb(UIColor(Color.secondaryText), traits)
            let card = rgb(.secondarySystemGroupedBackground, traits)
            let grouped = rgb(.systemGroupedBackground, traits)
            var backgrounds: [(String, (Double, Double, Double))] = [
                ("background", rgb(.systemBackground, traits)),
                ("grouped", grouped),
                ("card", card),
                ("secondary background", rgb(.secondarySystemBackground, traits)),
                ("tertiary background", rgb(.tertiarySystemBackground, traits)),
                ("permission card", over(rgb(.systemOrange, traits), grouped, 0.08)),
            ]
            var fill: CGFloat = 0
            UIColor.tertiarySystemFill.resolvedColor(with: traits).getWhite(nil, alpha: &fill)
            backgrounds.append(("tertiary fill", over(rgb(.tertiarySystemFill, traits), card, Double(fill))))
            let mode = traits.userInterfaceStyle == .dark ? "dark" : "light"
            for (name, background) in backgrounds {
                XCTAssertGreaterThanOrEqual(ratio(text, background), 4.5, "secondary text on \(name), \(mode)")
            }
        }
    }

    func testAccentHasALightAndADarkShade() {
        let accent = UIColor(named: "AccentColor")!
        XCTAssertNotEqual(luminance(rgb(accent, light)), luminance(rgb(accent, dark)))
        XCTAssertGreaterThanOrEqual(ratio(rgb(accent, light), (1, 1, 1)), 4.5)
    }
}
