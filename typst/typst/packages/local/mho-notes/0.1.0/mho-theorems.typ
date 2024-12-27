#import "@preview/ctheorems:1.1.3": *

#let thmbox = thmbox.with(
  titlefmt: title => text(10pt, weight: "bold", fill: black, title),
  padding: (top: 1.6em, bottom: 1em),
)

#let axiom = thmbox(
  "axiom",
  "Axiom",
  base_level: 1,
  fill: rgb("#19495E").lighten(90%),
    stroke: rgb("#19495E"),
)

#let proposition = thmbox(
  "proposition",
  "Proposition",
  base_level: 1,
  fill: rgb("#19495E").lighten(90%),
    stroke: rgb("#19495E"),
)
#let definition = thmbox(
  "definition",
  "Definition",
  base_level: 1,
  fill: rgb("#19495E").lighten(90%),
    stroke: rgb("#19495E"),
)
#let proof = thmproof("proof", "Proof")

#let example = thmbox(
  "example",
  "Example",
  base_level: 1,
  fill: rgb("#1F603F").lighten(90%),
    stroke: rgb("#1F603F"),
)

#let notation = thmbox(
  "notation",
  "Notation",
  base_level: 1,
  fill: rgb("#EBAB91").lighten(90%),
    stroke: rgb("#EBAB91"),
)
#let essentialQuestion = thmbox(
    "essentialQuestions",
    "Essential Question",
    base_level: 1,
    fill: rgb("#2E2256").lighten(90%),
    stroke: rgb("#2E2256"),
)

#let essentialQuestions = thmbox(
    "essentialQuestions",
    "Essential Questions",
    base_level: 1,
    fill: rgb("#2E2256").lighten(90%),
    stroke: rgb("#2E2256"),
)
