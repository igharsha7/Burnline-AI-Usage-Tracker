//
//  ProjectNameTests.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import Testing

struct ProjectNameTests {
    @Test(arguments: [
        ("Burnline-AI-Usage-Tracker", "Burnline AI Usage Tracker"),
        ("SketchVLM---Capstone-Project", "SketchVLM Capstone Project"),
        ("crop-recommendation-system", "Crop Recommendation System"),
        ("Nokia_Case_Study", "Nokia Case Study"),
        ("vidh-landing-v2", "Vidh Landing v2"),
        ("scratch-2026-10-18-f01303", "Scratch 2026-10-18 f01303"),
        ("GRDB.swift", "GRDB.swift"),
        ("Exp 2 - simple frontend with api key", "Exp 2 - simple frontend with api key"),
        ("-", "-"),
    ])
    func `a slug reads as words, and prose is kept as written`(stored: String, shown: String) {
        #expect(ProjectName.readable(stored, path: nil) == shown)
    }

    @Test func `a name stored lowercased takes its case from the folder it was seen in`() {
        #expect(ProjectName.readable("courseatlas", path: "/Volumes/Code/CourseAtlas") == "CourseAtlas")
        #expect(ProjectName.readable("github-community-club-website", path: "/x/Github-Community-Club-Website")
            == "Github Community Club Website")
        // A folder named differently lends nothing.
        #expect(ProjectName.readable("agenticai-capstone", path: "/x/Project") == "Agenticai Capstone")
    }

    @Test func `the user's alias is shown as typed`() {
        let project = Project(id: 1, identity: .gitRemote("github.com/me/my-app"), displayName: "my-app",
                              userAlias: "my-app (old)", lastKnownPath: nil, mergedIntoID: nil,
                              firstSeenAt: Timestamp(epochSeconds: 0), lastSeenAt: Timestamp(epochSeconds: 0))
        #expect(project.name == "my-app (old)")
        #expect(project.derivedName == "My App")
    }
}
