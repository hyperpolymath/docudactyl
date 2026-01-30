;; SPDX-License-Identifier: MPL-2.0-or-later
;; ECOSYSTEM.scm - Project ecosystem positioning

(ecosystem
  ((version . "1.0.0")
   (name . "Docudactyl")
   (type . "component")
   (purpose . "Part of hyperpolymath ecosystem")
   (position-in-ecosystem . "supporting")
   (related-projects
     ((rhodium-standard . "sibling-standard")
      (git-hud . "infrastructure")))
   (what-this-is . ("A hyperpolymath project"))
   (what-this-is-not . ("A standalone solution"))))
