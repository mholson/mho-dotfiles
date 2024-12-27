#import "@preview/codly:1.0.0": *

#let icon(codepoint) = {
  box(
    height: 0.8em,
    baseline: 0.05em,
    image(codepoint)
  )
  h(0.1em)
}

#codly(
    languages: (
        swift: (
            name: "Swift",
            // Include Swift Icon
            icon: icon("AAVX-swift-bird.svg"),
            color: rgb("#FD8D0E")),
        shell: (
            name: "Shell",
            // Include Terminal Icon
            icon: "🐚",
            color: rgb("#434C5E")),
    ),
    display-name: true,
    number-format: none,
    zebra-fill: none
)
